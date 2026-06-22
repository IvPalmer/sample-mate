// Downsampled min/max envelope of the captured audio, for fast waveform drawing.
// One (low, high) bin per `binSize` frames. Lock-free SPSC: the capture thread appends
// finished bins (via CaptureSink); the main thread reads envelopes for rendering.
//
// Bins are indexed on the same global timeline as the audio ring: bin `b` covers frames
// `[b*binSize, (b+1)*binSize)`. The most recent `binCapacity` bins are retained.

import Foundation
import Synchronization

final class PeakRing: @unchecked Sendable {

    /// Bins the consumer is allowed to read. Physical storage is larger by `slack` so the
    /// producer's head slot is never inside the readable window (avoids a wrap-tear where
    /// `low` comes from the new bin and `high` from the old one).
    let retainedBins: Int
    let binCapacity: Int
    let binSize: Int

    private let lows: UnsafeMutableBufferPointer<Float>
    private let highs: UnsafeMutableBufferPointer<Float>
    private let totalBins = Atomic<Int>(0)

    init(retainedBins: Int, binSize: Int, slack: Int = 16) {
        precondition(retainedBins > 0 && binSize > 0 && slack > 0)
        self.retainedBins = retainedBins
        self.binCapacity = retainedBins + slack
        self.binSize = binSize
        let l = UnsafeMutableBufferPointer<Float>.allocate(capacity: binCapacity)
        let h = UnsafeMutableBufferPointer<Float>.allocate(capacity: binCapacity)
        l.initialize(repeating: 0)
        h.initialize(repeating: 0)
        lows = l
        highs = h
    }

    deinit {
        lows.deallocate()
        highs.deallocate()
    }

    /// Total bins ever produced (monotonic). `totalBins * binSize` ≈ frames captured.
    var totalBinsWritten: Int { totalBins.load(ordering: .acquiring) }

    /// Producer side (capture thread). Appends one finished bin.
    func append(low: Float, high: Float) {
        let t = totalBins.load(ordering: .relaxed)
        let slot = t % binCapacity
        lows[slot] = low
        highs[slot] = high
        totalBins.store(t + 1, ordering: .releasing)
    }

    /// Consumer side. Aggregated min/max over the absolute bin range `[fromBin, toBin)`,
    /// clamped to what's still retained. Returns nil if none of that range is available.
    func envelope(fromBin: Int, toBin: Int) -> (low: Float, high: Float)? {
        let total = totalBins.load(ordering: .acquiring)
        let firstValid = Swift.max(0, total - retainedBins)
        let start = Swift.max(fromBin, firstValid)
        let end = Swift.min(toBin, total)
        guard start < end else { return nil }

        var lo: Float = .greatestFiniteMagnitude
        var hi: Float = -.greatestFiniteMagnitude
        var b = start
        while b < end {
            let slot = b % binCapacity
            let l = lows[slot]
            let h = highs[slot]
            if l < lo { lo = l }
            if h > hi { hi = h }
            b += 1
        }
        return (lo, hi)
    }

    /// Peak absolute amplitude over the most recent `bins` (for a level meter). 0 if none.
    func recentPeak(bins: Int) -> Float {
        let total = totalBins.load(ordering: .acquiring)
        guard let env = envelope(fromBin: total - bins, toBin: total) else { return 0 }
        return Swift.max(abs(env.low), abs(env.high))
    }
}
