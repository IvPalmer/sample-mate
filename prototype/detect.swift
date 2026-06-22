// SampleMate — pitch/key detector prototype (portable to the app's export path).
// Build: swiftc -O detect.swift -o detect -framework Accelerate -framework AVFoundation
// Use:   ./detect [--note|--key|--auto] file.wav [more.wav ...]
// Prints: RESULT<TAB>CONFIDENCE<TAB>FILE   (RESULT "-" when below confidence gate)
//
// Two regimes, mirroring Sononym:
//   - NOTE: YIN fundamental-frequency estimator on the loudest window -> nearest MIDI note.
//   - KEY : magnitude-spectrum chroma (octave-folded) correlated with Sha'ath major/minor key
//           profiles (empirically tuned KS variant from the libKeyFinder / KeyFinder lineage).
// Both gated on a confidence score so percussive/atonal material yields "-" instead of a wrong tag.

import Foundation
import Accelerate
import AVFoundation

let NOTE_NAMES = ["C","C#","D","D#","E","F","F#","G","G#","A","A#","B"]

// MARK: - Audio loading (mono Float at file's native sample rate)

func loadMono(_ path: String) -> (samples: [Float], sr: Double)? {
    let url = URL(fileURLWithPath: path)
    guard let file = try? AVAudioFile(forReading: url) else { return nil }
    let sr = file.fileFormat.sampleRate
    guard let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sr,
                                  channels: file.fileFormat.channelCount, interleaved: false) else { return nil }
    let total = AVAudioFrameCount(file.length)
    guard total > 0, let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: total) else { return nil }
    do { try file.read(into: buf) } catch { return nil }
    let n = Int(buf.frameLength)
    let ch = Int(fmt.channelCount)
    guard n > 0, let data = buf.floatChannelData else { return nil }
    var mono = [Float](repeating: 0, count: n)
    for c in 0..<ch {
        let p = data[c]
        for i in 0..<n { mono[i] += p[i] }
    }
    if ch > 1 {
        var s = Float(ch)
        vDSP_vsdiv(mono, 1, &s, &mono, 1, vDSP_Length(n))
    }
    return (mono, sr)
}

// MARK: - Loudest window (by RMS) for note analysis

func loudestStart(_ x: [Float], window: Int, hop: Int) -> Int {
    if x.count <= window { return 0 }
    var bestStart = 0
    var bestRMS: Float = -1
    var i = 0
    while i + window <= x.count {
        var ms: Float = 0
        vDSP_measqv(Array(x[i..<i+window]), 1, &ms, vDSP_Length(window)) // mean square
        if ms > bestRMS { bestRMS = ms; bestStart = i }
        i += hop
    }
    return bestStart
}

// MARK: - YIN note detector

func yin(_ x: [Float], start: Int, sr: Double) -> (f0: Double, clarity: Double)? {
    let W = 4096
    let tauMin = max(2, Int(sr / 1500.0))
    let tauMax = min(Int(sr / 40.0), W)              // down to ~40 Hz (E1≈41 covered)
    guard tauMin < tauMax, start >= 0, start + W + tauMax <= x.count else { return nil }

    var d = [Double](repeating: 0, count: tauMax + 1)
    for tau in 1...tauMax {
        var sum = 0.0
        for j in 0..<W {
            let diff = Double(x[start + j]) - Double(x[start + j + tau])
            sum += diff * diff
        }
        d[tau] = sum
    }
    // cumulative mean normalized difference
    var dp = [Double](repeating: 1, count: tauMax + 1)
    var running = 0.0
    for tau in 1...tauMax {
        running += d[tau]
        dp[tau] = running > 0 ? d[tau] * Double(tau) / running : 1
    }
    // absolute threshold -> first dip below 0.1, descend to its local min
    let thr = 0.1
    var tauEst = -1
    var tau = tauMin
    while tau <= tauMax {
        if dp[tau] < thr {
            while tau + 1 <= tauMax && dp[tau + 1] < dp[tau] { tau += 1 }
            tauEst = tau; break
        }
        tau += 1
    }
    if tauEst == -1 {
        var best = tauMin
        for t in tauMin...tauMax where dp[t] < dp[best] { best = t }
        tauEst = best
    }
    // parabolic interpolation
    var betterTau = Double(tauEst)
    if tauEst > tauMin && tauEst < tauMax {
        let s0 = dp[tauEst - 1], s1 = dp[tauEst], s2 = dp[tauEst + 1]
        let denom = 2 * (2 * s1 - s2 - s0)
        if denom != 0 { betterTau = Double(tauEst) + (s2 - s0) / denom }
    }
    guard betterTau > 0 else { return nil }
    return (sr / betterTau, 1.0 - dp[tauEst])
}

func detectNote(_ x: [Float], sr: Double) -> (label: String, conf: Double) {
    let W = 4096
    let tauMax = min(Int(sr / 40.0), W)
    let need = W + tauMax                    // yin's required lookahead past `start`
    guard x.count >= need else { return ("-", 0) }
    var start = loudestStart(x, window: W, hop: W / 2)
    start = min(start, x.count - need)       // keep yin's full window in-bounds (bug fix)
    guard let (f0, clarity) = yin(x, start: start, sr: sr), f0 > 20, f0 < 5000 else {
        return ("-", 0)
    }
    let midi = Int((69.0 + 12.0 * log2(f0 / 440.0)).rounded())
    let pc = ((midi % 12) + 12) % 12
    let octave = midi / 12 - 1
    let label = "\(NOTE_NAMES[pc])\(octave)"
    return (clarity >= 0.55 ? label : "-", clarity)
}

// MARK: - FFT magnitude spectrum

func fftMagnitudes(_ windowed: [Float], setup: FFTSetup, log2n: vDSP_Length) -> [Float] {
    let n = 1 << log2n
    let half = n / 2
    var realp = [Float](repeating: 0, count: half)
    var imagp = [Float](repeating: 0, count: half)
    var mags  = [Float](repeating: 0, count: half)
    realp.withUnsafeMutableBufferPointer { rp in
        imagp.withUnsafeMutableBufferPointer { ip in
            var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
            windowed.withUnsafeBufferPointer { wp in
                wp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { cp in
                    vDSP_ctoz(cp, 2, &split, 1, vDSP_Length(half))
                }
            }
            vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
            vDSP_zvabs(&split, 1, &mags, 1, vDSP_Length(half))
        }
    }
    return mags
}

// MARK: - Chroma + key profiles (Sha'ath, validated by prototype harness)

// Krumhansl-Schmuckler profiles (kept for reference/regression testing).
// Source: Krumhansl, C.L. (1990) "Cognitive Foundations of Musical Pitch", Oxford University Press.
let KS_MAJOR = [6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88]
let KS_MINOR = [6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17]

// Sha'ath profiles — empirically derived by Ibrahim Sha'ath for the KeyFinder / libKeyFinder lineage.
// Source: mixxxdj/libkeyfinder v2.2.8 src/constants.cpp (MAJOR_PROFILE / MINOR_PROFILE arrays),
//         https://github.com/mixxxdj/libkeyfinder — the maintained fork of ibsh/libKeyFinder.
//         Theoretical background: Sha'ath, I. (2011) "Estimation of key in digital music recordings",
//         MSc thesis, Birkbeck College, University of London, fig. 2.8 (values tuned empirically).
let SHAATH_MAJOR = [7.23900502618145, 3.50351166725159, 3.58445177536649, 2.84511816478676,
                    5.81898892118550, 4.55865057415321, 2.44778850545507, 6.99473192146830,
                    3.39106613673505, 4.55614256655143, 4.07392666663524, 4.45932757378887]
let SHAATH_MINOR = [7.00255045060284, 3.14360279015997, 4.35904319714963, 5.40418120718934,
                    3.67234420879306, 4.08971184917798, 3.90791435991554, 6.19960288562316,
                    3.63424625625277, 2.87241191079876, 5.35467999794543, 3.83242038595048]

func pearson(_ a: [Double], _ b: [Double]) -> Double {
    let n = Double(a.count)
    let ma = a.reduce(0, +) / n, mb = b.reduce(0, +) / n
    var num = 0.0, da = 0.0, db = 0.0
    for i in 0..<a.count {
        let xa = a[i] - ma, xb = b[i] - mb
        num += xa * xb; da += xa * xa; db += xb * xb
    }
    let den = (da * db).squareRoot()
    return den == 0 ? 0 : num / den
}

func detectKey(_ x: [Float], sr: Double) -> (label: String, conf: Double) {
    let log2n: vDSP_Length = 14            // 16384-pt FFT (~2.7 Hz/bin @ 44.1k)
    let n = 1 << log2n
    let hop = n / 4
    guard x.count >= n else { return ("-", 0) }

    let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
    defer { vDSP_destroy_fftsetup(setup) }
    var window = [Float](repeating: 0, count: n)
    vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))

    let env = ProcessInfo.processInfo.environment
    let bassWeight = Double(env["SM_BASS"] ?? "0") ?? 0          // bass-tonic prior (0 = off)
    let doTune = (env["SM_TUNE"] ?? "1") != "0"                  // global tuning correction (on)

    // Pass 1: collect per-frame magnitude spectra.
    let limit = min(x.count, Int(30.0 * sr))
    var spectra: [[Float]] = []
    var start = 0
    while start + n <= limit {
        var win = [Float](repeating: 0, count: n)
        vDSP_vmul(Array(x[start..<start+n]), 1, window, 1, &win, 1, vDSP_Length(n))
        spectra.append(fftMagnitudes(win, setup: setup, log2n: log2n))
        start += hop
    }
    guard !spectra.isEmpty else { return ("-", 0) }

    // Global tuning offset (fraction of a semitone): circular mean of how far strong bins
    // sit from the equal-tempered grid. Corrects off-A440 lo-fi/vinyl packs.
    var tune = 0.0
    if doTune {
        var re = 0.0, im = 0.0
        for mags in spectra {
            for k in 1..<(n / 2) {
                let f = Double(k) * sr / Double(n)
                if f < 80 || f > 2000 { continue }
                let dev = (12.0 * log2(f / 440.0)).truncatingRemainder(dividingBy: 1)
                let d = dev > 0.5 ? dev - 1 : (dev < -0.5 ? dev + 1 : dev)
                let w = Double(mags[k])
                re += w * cos(2 * .pi * d); im += w * sin(2 * .pi * d)
            }
        }
        if re != 0 || im != 0 { tune = atan2(im, re) / (2 * .pi) }
    }

    // Pass 2: offset-corrected, triangular-spread, per-frame-normalized chroma + bass band.
    var chroma = [Double](repeating: 0, count: 12)
    var bass   = [Double](repeating: 0, count: 12)
    for mags in spectra {
        var fc = [Double](repeating: 0, count: 12)
        var fb = [Double](repeating: 0, count: 12)
        for k in 1..<(n/2) {
            let f = Double(k) * sr / Double(n)
            if f < 32 || f > 5000 { continue }       // include bass fundamentals (C1≈32.7 Hz)
            let midi = 69.0 + 12.0 * log2(f / 440.0) - tune
            let pcF = midi.truncatingRemainder(dividingBy: 12)
            let lo = Int(floor(pcF)); let frac = pcF - Double(lo)
            let a = ((lo % 12) + 12) % 12
            let b = (((lo + 1) % 12) + 12) % 12
            let m = Double(mags[k])
            fc[a] += m * (1 - frac); fc[b] += m * frac
            if f <= 250 { fb[a] += m * (1 - frac); fb[b] += m * frac }
        }
        let s = fc.reduce(0, +); if s > 0 { for i in 0..<12 { chroma[i] += fc[i] / s } }
        let sb = fb.reduce(0, +); if sb > 0 { for i in 0..<12 { bass[i] += fb[i] / sb } }
    }
    let total = chroma.reduce(0, +); guard total > 0 else { return ("-", 0) }
    for i in 0..<12 { chroma[i] /= total }
    let tb = bass.reduce(0, +); if tb > 0 { for i in 0..<12 { bass[i] /= tb } }

    var ranked: [(score: Double, corr: Double, t: Int, minor: Bool)] = []
    for (isMinor, profile) in [(false, SHAATH_MAJOR), (true, SHAATH_MINOR)] {
        for t in 0..<12 {
            var prof = [Double](repeating: 0, count: 12)
            for c in 0..<12 { prof[c] = profile[((c - t) % 12 + 12) % 12] }
            let r = pearson(chroma, prof)
            let score = r + bassWeight * (tb > 0 ? bass[t] : 0)   // bass-tonic re-rank
            ranked.append((score, r, t, isMinor))
        }
    }
    ranked.sort { $0.score > $1.score }
    let best = ranked[0], second = ranked[1]
    let label = "\(NOTE_NAMES[best.t])\(best.minor ? "m" : "")"
    let margin = best.score - second.score
    let conf = best.corr * min(1.0, max(0.0, margin / 0.08))   // fold ambiguity into confidence
    let confident = best.corr >= 0.55 && margin >= 0.01
    let gateOff = env["SM_NOGATE"] == "1"          // commit always (match libKeyFinder policy)
    return ((confident || gateOff) ? label : "-", conf)
}

// MARK: - CLI

var mode = "auto"
var files: [String] = []
for arg in CommandLine.arguments.dropFirst() {
    switch arg {
    case "--note": mode = "note"
    case "--key":  mode = "key"
    case "--auto": mode = "auto"
    default: files.append(arg)
    }
}
for path in files {
    guard let (x, sr) = loadMono(path) else {
        print("ERR\t0\t\(path)"); continue
    }
    let dur = Double(x.count) / sr
    let result: (label: String, conf: Double)
    switch mode {
    case "note": result = detectNote(x, sr: sr)
    case "key":  result = detectKey(x, sr: sr)
    default:     result = dur < 1.5 ? detectNote(x, sr: sr) : detectKey(x, sr: sr)
    }
    print("\(result.label)\t\(String(format: "%.3f", result.conf))\t\(path)")
}
