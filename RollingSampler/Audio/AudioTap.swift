// A Core Audio process tap wired into a private aggregate device, exposing an IO block.
// Generalized from AudioCap's ProcessTap so it works with any CATapDescription
// (global / per-process / global-except), which is how the listener modes are built.

import Foundation
import AudioToolbox
import CoreAudio
import AVFoundation
import OSLog

final class AudioTap {

    let label: String
    private let description: CATapDescription
    private let logger: Logger

    private var processTapID: AudioObjectID = .unknown
    private var aggregateDeviceID: AudioObjectID = .unknown
    private var deviceProcID: AudioDeviceIOProcID?
    private var ioQueue: DispatchQueue?

    private(set) var tapStreamDescription: AudioStreamBasicDescription?
    private(set) var activated = false

    init(description: CATapDescription, label: String) {
        self.description = description
        self.label = label
        self.logger = Logger(subsystem: kAppSubsystem, category: "AudioTap(\(label))")
    }

    /// Creates the process tap + aggregate device. Throws on failure (most often a
    /// missing audio-capture permission, which surfaces as a tap-creation error).
    func activate() throws {
        guard !activated else { return }
        activated = true

        description.uuid = UUID()
        description.muteBehavior = .unmuted

        var tapID: AUAudioObjectID = .unknown
        var err = AudioHardwareCreateProcessTap(description, &tapID)
        guard err == noErr else {
            activated = false
            throw "Process tap creation failed (\(err)). Grant audio-capture permission and try again."
        }
        processTapID = tapID
        logger.debug("Created process tap #\(tapID, privacy: .public)")

        let aggregateUID = UUID().uuidString

        // System-output capture: the tap is the ONLY input — no audio sub-device.
        // Including the output device as a sub-device makes the aggregate clock to that
        // device's sample rate; on a 44.1 kHz interface (vs the tap's 48 kHz) that
        // mismatch yields an all-zeros (silent) tap. Matching AudioTee's setup fixes it.
        // (AudioCap's sub-device approach is for per-process taps where rates usually match.)
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "RollingSampler-\(label)",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: description.uuid.uuidString
                ]
            ]
        ]

        tapStreamDescription = try tapID.readAudioTapStreamBasicDescription()

        err = AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &aggregateDeviceID)
        guard err == noErr else {
            throw "Failed to create aggregate device (\(err))."
        }
        logger.debug("Created aggregate device #\(self.aggregateDeviceID, privacy: .public)")
    }

    /// Installs the IO block on the given queue and starts the device.
    func run(on queue: DispatchQueue, ioBlock: @escaping AudioDeviceIOBlock) throws {
        guard activated, aggregateDeviceID.isValid else { throw "Tap not activated." }

        ioQueue = queue
        var err = AudioDeviceCreateIOProcIDWithBlock(&deviceProcID, aggregateDeviceID, queue, ioBlock)
        guard err == noErr else { throw "Failed to create IO proc (\(err))." }

        err = AudioDeviceStart(aggregateDeviceID, deviceProcID)
        guard err == noErr else { throw "Failed to start aggregate device (\(err))." }
    }

    func invalidate() {
        guard activated else { return }
        defer { activated = false }

        if aggregateDeviceID.isValid {
            if let deviceProcID {
                AudioDeviceStop(aggregateDeviceID, deviceProcID)
                // Drain any in-flight IO block before destroying the proc, so the block
                // (which holds the ring strongly) can never run after teardown.
                ioQueue?.sync {}
                AudioDeviceDestroyIOProcID(aggregateDeviceID, deviceProcID)
                self.deviceProcID = nil
            }
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            aggregateDeviceID = .unknown
        }
        ioQueue = nil

        if processTapID.isValid {
            AudioHardwareDestroyProcessTap(processTapID)
            processTapID = .unknown
        }
    }

    deinit { invalidate() }
}
