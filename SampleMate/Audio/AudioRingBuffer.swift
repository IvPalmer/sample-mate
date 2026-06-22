// Fixed-size, lock-free single-producer/single-consumer ring buffer of interleaved
// Float32 audio. The audio IO thread is the sole producer (`write`); the main/export
// thread is the sole consumer (`copyFrames`). A monotonic frame counter is published
// with release/acquire ordering so the consumer never reads a torn write.

import Foundation
import Synchronization

final class AudioRingBuffer: @unchecked Sendable {

    let capacityFrames: Int
    let channelCount: Int

    private let storage: UnsafeMutableBufferPointer<Float>
    /// Total frames ever written (monotonic). Modulo capacity gives the slot.
    private let totalFramesWritten = Atomic<Int>(0)

    init(capacityFrames: Int, channelCount: Int) {
        precondition(capacityFrames > 0 && channelCount > 0)
        self.capacityFrames = capacityFrames
        self.channelCount = channelCount
        let count = capacityFrames * channelCount
        let p = UnsafeMutableBufferPointer<Float>.allocate(capacity: count)
        p.initialize(repeating: 0)
        self.storage = p
    }

    deinit { storage.deallocate() }

    /// Newest frame index (exclusive end of the valid timeline).
    var currentWriteFrame: Int { totalFramesWritten.load(ordering: .acquiring) }

    /// The frame range currently retrievable on the global timeline.
    var availableFrameRange: Range<Int> {
        let total = totalFramesWritten.load(ordering: .acquiring)
        return Swift.max(0, total - capacityFrames)..<total
    }

    /// Producer side (audio thread). `src` is interleaved with `channelCount` channels.
    func write(_ src: UnsafePointer<Float>, frameCount originalFrameCount: Int) {
        guard originalFrameCount > 0 else { return }
        let total = totalFramesWritten.load(ordering: .relaxed)

        // Defensive: a single callback should never exceed the whole buffer, but if it
        // ever does, keep only the most recent `capacityFrames` so we don't overrun.
        let writeCount = Swift.min(originalFrameCount, capacityFrames)
        let dropped = originalFrameCount - writeCount
        let source = src.advanced(by: dropped * channelCount)

        let startSlot = (total + dropped) % capacityFrames
        let base = storage.baseAddress!

        let firstChunk = Swift.min(writeCount, capacityFrames - startSlot)
        base.advanced(by: startSlot * channelCount)
            .update(from: source, count: firstChunk * channelCount)

        if firstChunk < writeCount {
            let remaining = writeCount - firstChunk
            base.update(from: source.advanced(by: firstChunk * channelCount),
                        count: remaining * channelCount)
        }

        totalFramesWritten.store(total + originalFrameCount, ordering: .releasing)
    }

    /// Consumer side. Copies the global frame range `[start, start+count)` into `out`
    /// (interleaved). Returns false if any of that range has already wrapped out of the
    /// buffer (selection expired). Must be serialized with `write` (caller runs it on
    /// the IO queue) so a wrap can't overwrite slots mid-copy.
    func copyFrames(start: Int, count: Int, into out: inout [Float]) -> Bool {
        let total = totalFramesWritten.load(ordering: .acquiring)
        let firstValid = Swift.max(0, total - capacityFrames)
        guard count > 0, start >= firstValid, start + count <= total,
              out.count >= count * channelCount else { return false }

        let base = storage.baseAddress!
        out.withUnsafeMutableBufferPointer { dst in
            var copied = 0
            while copied < count {
                let slot = (start + copied) % capacityFrames
                let chunk = Swift.min(count - copied, capacityFrames - slot)
                dst.baseAddress!.advanced(by: copied * channelCount)
                    .update(from: base.advanced(by: slot * channelCount),
                            count: chunk * channelCount)
                copied += chunk
            }
        }
        return true
    }
}
