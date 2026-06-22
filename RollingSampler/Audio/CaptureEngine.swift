// Orchestrates: listener mode -> CATapDescription -> AudioTap -> CaptureSink
// (ring buffer + peak envelope), and exports a selected frame range to a WAV for drag-out.

import Foundation
import AVFoundation
import AudioToolbox
import CoreAudio
import AppKit
import OSLog

@MainActor
@Observable
final class CaptureEngine {

    enum Mode: String, CaseIterable, Identifiable {
        case allAudio      // everything playing on the system
        case onlyApp       // just the selected app
        case excludeApp    // everything except the selected app
        var id: String { rawValue }
        var title: String {
            switch self {
            case .allAudio: "All audio"
            case .onlyApp: "Only app"
            case .excludeApp: "Everything except"
            }
        }
    }

    let permission = AudioRecordingPermission()
    let processController = AudioProcessController()

    enum DisplayMode: String, CaseIterable, Identifiable {
        case scroll   // moving timeline, scroll back through history
        case loop     // static fixed-size oscilloscope, overwrites in place (like the original)
        var id: String { rawValue }
        var title: String { self == .scroll ? "Scroll" : "Loop" }
    }

    // User settings
    var mode: Mode = .allAudio
    var selectedProcess: AudioProcess?
    var bufferSeconds: Double = 45
    var displayMode: DisplayMode = .scroll
    var skipSilence: Bool = true {
        didSet { sink?.gateEnabled = skipSilence }
    }

    // State surfaced to the UI
    private(set) var isCapturing = false
    private(set) var statusMessage = "Idle."
    private(set) var errorMessage: String?
    private(set) var lastExportURL: URL?

    // Live diagnostics (instrumentation for the "nothing captured" investigation).
    private(set) var captureDiagnostics = ""
    private(set) var deviceName = ""
    private var diagTimer: Timer?

    // Bumped each capture session; a selection from a previous epoch is no longer valid.
    private(set) var epochID = 0
    private(set) var sampleRate: Double = 48_000
    private(set) var channelCount: Int = 2

    private let logger = Logger(subsystem: kAppSubsystem, category: "CaptureEngine")
    private let ioQueue = DispatchQueue(label: "com.palmer.RollingSampler.io", qos: .userInitiated)

    private var tap: AudioTap?
    private var sink: CaptureSink?

    /// Read by the waveform view each draw (consumer side of the SPSC peak ring).
    var peaks: PeakRing? { sink?.peaks }
    var currentWriteFrame: Int { sink?.currentWriteFrame ?? 0 }

    func bootstrap() {
        processController.activate()
    }

    func requestPermission() {
        permission.request()
    }

    var canStart: Bool {
        permission.status == .authorized && !isCapturing
            && (mode == .allAudio || selectedProcess != nil)
    }

    func start() {
        errorMessage = nil
        guard permission.status == .authorized else {
            errorMessage = "Audio-capture permission not granted yet."
            return
        }

        do {
            let description = try makeDescription()
            let tap = AudioTap(description: description, label: mode.title)
            try tap.activate()

            guard var asbd = tap.tapStreamDescription,
                  let format = AVAudioFormat(streamDescription: &asbd) else {
                tap.invalidate()
                throw "Could not read the tap's audio format."
            }

            guard asbd.mFormatID == kAudioFormatLinearPCM,
                  (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0,
                  asbd.mBitsPerChannel == 32 else {
                tap.invalidate()
                throw "Unsupported tap format (expected 32-bit float PCM)."
            }

            let channels = Int(format.channelCount)
            let rate = format.sampleRate
            guard channels > 0, rate > 0 else {
                tap.invalidate()
                throw "Tap reported an invalid format (\(channels) ch, \(rate) Hz)."
            }

            let capacity = Swift.max(1, Int(bufferSeconds * rate))
            let sink = CaptureSink(capacityFrames: capacity, channelCount: channels, sampleRate: rate)
            sink.gateEnabled = skipSilence
            let isInterleaved = format.isInterleaved

            self.tap = tap
            self.sink = sink
            self.sampleRate = rate
            self.channelCount = channels
            self.epochID += 1

            try tap.run(on: ioQueue) { _, inInputData, _, _, _ in
                sink.append(from: inInputData, isInterleaved: isInterleaved)
            }

            self.deviceName = (try? AudioDeviceID.readDefaultSystemOutputDevice().readDeviceName()) ?? "?"
            startDiagnostics()

            isCapturing = true
            statusMessage = "Listening to \(mode.title)\(captureTargetSuffix) via \(deviceName) — \(Int(rate)) Hz, \(channels) ch, last \(Int(bufferSeconds))s."
        } catch {
            self.tap?.invalidate()
            self.tap = nil
            self.sink = nil
            errorMessage = (error as? String) ?? error.localizedDescription
            statusMessage = "Failed to start."
        }
    }

    func stop() {
        diagTimer?.invalidate()
        diagTimer = nil
        tap?.invalidate()
        tap = nil
        sink = nil
        isCapturing = false
        captureDiagnostics = ""
        statusMessage = "Stopped."
    }

    private func startDiagnostics() {
        diagTimer?.invalidate()
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.updateDiagnostics()
        }
        RunLoop.main.add(timer, forMode: .common)
        diagTimer = timer
    }

    private func updateDiagnostics() {
        guard isCapturing, let sink else { return }
        let frames = sink.currentWriteFrame
        let bins = sink.peaks.totalBinsWritten
        let peak = sink.peaks.recentPeak(bins: 16)
        let db = peak > 0 ? 20 * log10(Double(peak)) : -Double.infinity
        let dbStr = db.isFinite ? String(format: "%.1f dBFS", db) : "−∞ (silent)"
        captureDiagnostics = "IOProc frames: \(frames) · bins: \(bins) · level: \(dbStr)"
        logger.notice("diag frames=\(frames) bins=\(bins) level=\(dbStr, privacy: .public)")
    }

    /// Copies a global frame range out of the ring and writes it to a WAV in the export
    /// cache. Returns the URL, or nil if the selection has scrolled out of the buffer.
    /// Runs the copy on the IO queue so the producer can't overwrite slots mid-copy.
    func exportSelection(startFrame: Int, frameCount: Int) -> URL? {
        guard let sink, frameCount > 0 else { return nil }
        let channels = sink.ring.channelCount
        var out = [Float](repeating: 0, count: frameCount * channels)
        let ok = ioQueue.sync { sink.ring.copyFrames(start: startFrame, count: frameCount, into: &out) }
        guard ok else {
            errorMessage = "That selection has already scrolled out of the buffer."
            return nil
        }
        do {
            let url = try Self.writeWAV(interleaved: out, sampleRate: sampleRate, channels: channels)
            lastExportURL = url
            let seconds = Double(frameCount) / sampleRate
            statusMessage = String(format: "Exported %.2fs → %@", seconds, url.lastPathComponent)
            errorMessage = nil
            return url
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func revealExportFolder() {
        if let dir = try? Self.exportDirectory() {
            NSWorkspace.shared.activateFileViewerSelecting([dir])
        }
    }

    // MARK: - Helpers

    private var captureTargetSuffix: String {
        switch mode {
        case .allAudio: ""
        case .onlyApp: " (\(selectedProcess?.name ?? "?"))"
        case .excludeApp: " (excl. \(selectedProcess?.name ?? "?"))"
        }
    }

    private func makeDescription() throws -> CATapDescription {
        switch mode {
        case .allAudio:
            return CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        case .onlyApp:
            guard let p = selectedProcess else { throw "Pick an app to capture." }
            return CATapDescription(stereoMixdownOfProcesses: [p.objectID])
        case .excludeApp:
            guard let p = selectedProcess else { throw "Pick an app to exclude." }
            return CATapDescription(stereoGlobalTapButExcludeProcesses: [p.objectID])
        }
    }

    private static func exportDirectory() throws -> URL {
        let base = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("SampleMate", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func timestamp() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd'T'HHmmss"
        return f.string(from: Date())
    }

    private static func writeWAV(interleaved input: [Float], sampleRate: Double, channels: Int) throws -> URL {
        let dir = try exportDirectory()
        let url = dir.appendingPathComponent("SM_\(timestamp()).wav")

        // Short edge fades (~5 ms) so a clip grabbed mid-sound doesn't start/end on a click.
        var samples = input
        let frames = samples.count / channels
        let fade = Swift.min(Int(0.005 * sampleRate), frames / 2)
        if fade > 0 {
            samples.withUnsafeMutableBufferPointer { buf in
                for i in 0..<fade {
                    let g = Float(i) / Float(fade)
                    for c in 0..<channels {
                        buf[i * channels + c] *= g
                        buf[(frames - 1 - i) * channels + c] *= g
                    }
                }
            }
        }

        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: sampleRate,
                                         channels: AVAudioChannelCount(channels),
                                         interleaved: true) else {
            throw "Could not build output format."
        }

        let frameCount = AVAudioFrameCount(samples.count / channels)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw "Could not allocate output buffer."
        }
        buffer.frameLength = frameCount
        samples.withUnsafeBytes { src in
            if let dst = buffer.audioBufferList.pointee.mBuffers.mData, let base = src.baseAddress {
                memcpy(dst, base, src.count)
            }
        }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: true)
        try file.write(from: buffer)
        return url
    }
}
