// What the audio IO block writes into: the raw ring buffer plus the downsampled peak
// envelope, updated in a single pass.
//
// A noise gate sits in front: audio is only stored when there's signal (with a short
// hold/release so musical gaps survive), so silence doesn't fill the buffer or advance
// the display. `currentWriteFrame` therefore only moves while real audio is captured.

import Foundation
import AudioToolbox

final class CaptureSink: @unchecked Sendable {

    let ring: AudioRingBuffer
    let peaks: PeakRing
    let channelCount: Int
    private let binSize: Int

    // Noise gate. `gateEnabled` is toggled live from the UI ("Skip silence").
    var gateEnabled = true
    private let gateThreshold: Float = 0.0025   // ~ -52 dBFS peak
    private let releaseFrames: Int              // stay open this long after last signal
    private var gateOpenFrames = 0
    private(set) var gateIsOpen = false         // UI hint (read cross-thread; advisory only)

    // Partial-bin peak accumulation. Touched only by the audio thread.
    private var accLow: Float = .greatestFiniteMagnitude
    private var accHigh: Float = -.greatestFiniteMagnitude
    private var accCount = 0

    // Scratch for the (rare) non-interleaved tap path. Sized once, reused.
    private var deinterleaveScratch: [Float] = []

    init(capacityFrames: Int, channelCount: Int, sampleRate: Double, binSize: Int = 256) {
        self.channelCount = channelCount
        self.binSize = binSize
        self.ring = AudioRingBuffer(capacityFrames: capacityFrames, channelCount: channelCount)
        let retainedBins = Swift.max(1, capacityFrames / binSize)
        self.peaks = PeakRing(retainedBins: retainedBins, binSize: binSize)
        self.releaseFrames = Swift.max(1, Int(0.5 * sampleRate))
    }

    var currentWriteFrame: Int { ring.currentWriteFrame }

    /// Audio-thread entry point. Reads Float32 PCM out of the Core Audio buffer list and,
    /// if the gate is open, writes it to the ring and folds it into the peak envelope.
    func append(from abl: UnsafePointer<AudioBufferList>, isInterleaved: Bool) {
        let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: abl))
        guard list.count > 0, channelCount > 0 else { return }

        if isInterleaved {
            let b = list[0]
            guard let data = b.mData else { return }
            let frames = Int(b.mDataByteSize) / (channelCount * MemoryLayout<Float>.size)
            guard frames > 0 else { return }
            process(data.assumingMemoryBound(to: Float.self), frameCount: frames)
        } else {
            guard list.count >= channelCount else { return }
            var frames = Int.max
            for ch in 0..<channelCount {
                frames = Swift.min(frames, Int(list[ch].mDataByteSize) / MemoryLayout<Float>.size)
            }
            guard frames > 0, frames != Int.max else { return }
            if deinterleaveScratch.count < frames * channelCount {
                deinterleaveScratch = [Float](repeating: 0, count: frames * channelCount)
            }
            deinterleaveScratch.withUnsafeMutableBufferPointer { dst in
                for ch in 0..<channelCount {
                    guard let d = list[ch].mData?.assumingMemoryBound(to: Float.self) else { return }
                    var f = 0
                    while f < frames { dst[f * channelCount + ch] = d[f]; f += 1 }
                }
                process(dst.baseAddress!, frameCount: frames)
            }
        }
    }

    private func process(_ data: UnsafePointer<Float>, frameCount: Int) {
        // Gate decision: peak of this block.
        var peak: Float = 0
        let n = frameCount * channelCount
        var i = 0
        while i < n { let a = abs(data[i]); if a > peak { peak = a }; i += 1 }

        if peak >= gateThreshold { gateOpenFrames = releaseFrames }
        guard !gateEnabled || gateOpenFrames > 0 else { gateIsOpen = false; return }
        gateIsOpen = true

        ring.write(data, frameCount: frameCount)
        accumulatePeaks(interleaved: data, frameCount: frameCount)
        if gateEnabled { gateOpenFrames = Swift.max(0, gateOpenFrames - frameCount) }
    }

    private func accumulatePeaks(interleaved data: UnsafePointer<Float>, frameCount: Int) {
        var lo = accLow
        var hi = accHigh
        var count = accCount
        var f = 0
        while f < frameCount {
            let base = f * channelCount
            var c = 0
            while c < channelCount {
                let s = data[base + c]
                if s < lo { lo = s }
                if s > hi { hi = s }
                c += 1
            }
            count += 1
            if count >= binSize {
                peaks.append(low: lo, high: hi)
                lo = .greatestFiniteMagnitude
                hi = -.greatestFiniteMagnitude
                count = 0
            }
            f += 1
        }
        accLow = lo
        accHigh = hi
        accCount = count
    }
}
