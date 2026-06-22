# Library Tagger Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a "Tag Library" module to Sample Mate that scans a folder, detects each sample's musical note/key, and renames files (note/key in filename) behind a preview → apply → undo flow.

**Architecture:** A shared, pure `PitchKeyDetector` (ported from `prototype/detect.swift`, vDSP) feeds a new Library Tagger module: `FolderScanner` (enumerate) → `TaggerEngine` (concurrent analysis → proposals) → SwiftUI preview table → `TagApplier` (rename + `.asd` companion + JSON undo log). The detector is reused by `CaptureEngine.exportSelection` in a later phase. UI integrates as a second tab in `RootView`.

**Tech Stack:** Swift 5 / SwiftUI / AppKit, Accelerate (vDSP), AVFoundation, XCTest, XcodeGen.

**Reference:** Spec at `docs/superpowers/specs/2026-06-22-library-tagger-design.md`. Validated detector prototype + accuracy harness in `prototype/` (`detect.swift`, `compare.py`, `grade.py`).

---

## File Structure

- Create `SampleMate/Audio/PitchKeyDetector.swift` — pure DSP detector + `Detection` type (note/key/none + confidence).
- Create `SampleMate/Library/AudioLoader.swift` — `AVAudioFile` → mono `[Float]` + sample rate.
- Create `SampleMate/Library/FolderScanner.swift` — recursive audio-file enumeration.
- Create `SampleMate/Library/NameFormatter.swift` — pure rename logic (idempotent, collision-safe).
- Create `SampleMate/Library/TagProposal.swift` — proposal model.
- Create `SampleMate/Library/TaggerEngine.swift` — `@Observable`, concurrent analysis, holds proposals.
- Create `SampleMate/Library/TagApplier.swift` — rename + `.asd` companion + undo log.
- Create `SampleMate/App/LibraryTaggerView.swift` — the Tag Library tab UI.
- Modify `SampleMate/App/RootView.swift` — host a `Capture | Tag Library` tab switch.
- Modify `project.yml` — add `SampleMateTests` unit-test target.
- Create `SampleMateTests/NameFormatterTests.swift`, `PitchKeyDetectorTests.swift`, `TagApplierTests.swift`, `FolderScannerTests.swift`.

Build/test commands used throughout:
```sh
xcodegen generate
xcodebuild -project SampleMate.xcodeproj -scheme SampleMate -configuration Debug build
xcodebuild test -project SampleMate.xcodeproj -scheme SampleMate -destination 'platform=macOS'
```

---

## Task 1: Unit-test target

**Files:**
- Modify: `project.yml`
- Create: `SampleMateTests/SmokeTests.swift`

- [ ] **Step 1: Add a test target to `project.yml`** (append under `targets:`, sibling to `SampleMate:`)

```yaml
  SampleMateTests:
    type: bundle.unit-test
    platform: macOS
    sources:
      - path: SampleMateTests
    dependencies:
      - target: SampleMate
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.palmer.SampleMateTests
        GENERATE_INFOPLIST_FILE: "YES"
```

Add a scheme so `xcodebuild test` finds the tests (append at top level of `project.yml`):

```yaml
schemes:
  SampleMate:
    build:
      targets:
        SampleMate: all
        SampleMateTests: [test]
    test:
      targets:
        - SampleMateTests
```

- [ ] **Step 2: Write a smoke test** in `SampleMateTests/SmokeTests.swift`

```swift
import XCTest
@testable import SampleMate

final class SmokeTests: XCTestCase {
    func testHarnessRuns() { XCTAssertTrue(true) }
}
```

- [ ] **Step 3: Regenerate + run, verify it builds and passes**

Run: `xcodegen generate && xcodebuild test -project SampleMate.xcodeproj -scheme SampleMate -destination 'platform=macOS'`
Expected: build succeeds, `testHarnessRuns` PASSES.

- [ ] **Step 4: Commit**

```bash
git add project.yml SampleMateTests/SmokeTests.swift
git commit -m "test: add SampleMateTests unit-test target"
```

---

## Task 2: PitchKeyDetector core (port + Detection type)

Port the validated DSP from `prototype/detect.swift` into the app as a pure detector. The
prototype's `yin`, `loudestStart`, `fftMagnitudes`, `pearson`, `detectNote`, `detectKey`,
`KS_MAJOR`, `KS_MINOR`, `NOTE_NAMES`, and the tuning/triangular/bass-prior chroma logic move
in verbatim; file I/O stays out (callers pass `[Float]`).

**Files:**
- Create: `SampleMate/Audio/PitchKeyDetector.swift`
- Test: `SampleMateTests/PitchKeyDetectorTests.swift`

- [ ] **Step 1: Write failing tests** in `SampleMateTests/PitchKeyDetectorTests.swift`

```swift
import XCTest
import Accelerate
@testable import SampleMate

final class PitchKeyDetectorTests: XCTestCase {
    // Generate a 1s tone with 2nd+3rd harmonics at a given MIDI note.
    private func tone(midi: Int, sr: Double = 44100, seconds: Double = 1.0) -> [Float] {
        let f = 440.0 * pow(2.0, Double(midi - 69) / 12.0)
        let n = Int(sr * seconds)
        return (0..<n).map { i in
            let t = Double(i) / sr
            return Float(0.6*sin(2*.pi*f*t) + 0.25*sin(2*.pi*2*f*t) + 0.12*sin(2*.pi*3*f*t))
        }
    }

    func testDetectsNoteOfPureTone() {
        let d = PitchKeyDetector.analyze(tone(midi: 60), sampleRate: 44100) // C4
        guard case let .note(name, octave, midi) = d.kind else { return XCTFail("expected note, got \(d.kind)") }
        XCTAssertEqual(name, "C"); XCTAssertEqual(octave, 4); XCTAssertEqual(midi, 60)
    }

    func testSilenceIsNone() {
        let d = PitchKeyDetector.analyze([Float](repeating: 0, count: 44100), sampleRate: 44100)
        if case .none = d.kind {} else { XCTFail("silence should be .none") }
    }
}
```

- [ ] **Step 2: Run, verify failure**

Run: `xcodebuild test -project SampleMate.xcodeproj -scheme SampleMate -destination 'platform=macOS' -only-testing:SampleMateTests/PitchKeyDetectorTests`
Expected: FAIL — `PitchKeyDetector` undefined.

- [ ] **Step 3: Create `PitchKeyDetector.swift`**

Port the prototype DSP unchanged and wrap it. Copy these symbols from `prototype/detect.swift`
verbatim into the file as `private` free functions / constants: `loudestStart`, `yin`,
`fftMagnitudes`, `pearson`, `KS_MAJOR`, `KS_MINOR`, the note-detection body of `detectNote`,
and the key-detection body of `detectKey` (keep the tuning correction + triangular spread +
bass prior; drop the `SM_*` env reads — hardcode `doTune = true`, `bassWeight = 0.0`). Then add:

```swift
import Foundation
import Accelerate

enum DetectionKind: Equatable {
    case note(name: String, octave: Int, midi: Int)
    case key(tonic: Int, minor: Bool)   // tonic: 0=C..11=B
    case none
}

struct Detection: Equatable {
    let kind: DetectionKind
    let confidence: Double
}

enum PitchKeyDetector {
    static let noteNames = ["C","C#","D","D#","E","F","F#","G","G#","A","A#","B"]

    /// Pure entry point. Routes note vs key by signal, returns .none below the gate.
    static func analyze(_ mono: [Float], sampleRate sr: Double) -> Detection {
        guard !mono.isEmpty else { return Detection(kind: .none, confidence: 0) }
        let seconds = Double(mono.count) / sr

        // NOTE candidate (YIN clarity) — see ported detectNote returning (label,midi,clarity)
        let note = detectNoteCore(mono, sr: sr)        // (label:String?, midi:Int?, clarity:Double)
        // KEY candidate — see ported detectKey returning (tonic,minor,corr,margin)
        let key  = detectKeyCore(mono, sr: sr)         // (tonic:Int?, minor:Bool, corr:Double, margin:Double)

        // Routing: short + clearly monophonic → note; else confident key; else none.
        if seconds < 2.0, let m = note.midi, note.clarity >= 0.6 {
            let pc = ((m % 12) + 12) % 12
            return Detection(kind: .note(name: noteNames[pc], octave: m/12 - 1, midi: m),
                             confidence: note.clarity)
        }
        if let t = key.tonic, key.corr >= 0.6, key.margin >= 0.02 {
            return Detection(kind: .key(tonic: t, minor: key.minor),
                             confidence: key.corr * min(1, key.margin / 0.08))
        }
        // Fall back to a high-clarity note even on longer material (sustained one-shot/pad).
        if let m = note.midi, note.clarity >= 0.7 {
            let pc = ((m % 12) + 12) % 12
            return Detection(kind: .note(name: noteNames[pc], octave: m/12 - 1, midi: m),
                             confidence: note.clarity)
        }
        return Detection(kind: .none, confidence: max(note.clarity, key.corr))
    }
}
```

Implement `detectNoteCore` and `detectKeyCore` as the ported bodies returning the tuples
above (they already compute these values internally in the prototype — expose them instead
of formatting a string). Keep the window-bounds fix from the prototype
(`start = min(loudestStart(...), x.count - W - tauMax)`).

- [ ] **Step 4: Run tests, verify pass**

Run: `xcodebuild test ... -only-testing:SampleMateTests/PitchKeyDetectorTests`
Expected: both tests PASS.

- [ ] **Step 5: Commit**

```bash
git add SampleMate/Audio/PitchKeyDetector.swift SampleMateTests/PitchKeyDetectorTests.swift
git commit -m "feat: PitchKeyDetector core ported from prototype"
```

---

## Task 3: NameFormatter (pure, full TDD)

**Files:**
- Create: `SampleMate/Library/NameFormatter.swift`
- Test: `SampleMateTests/NameFormatterTests.swift`

- [ ] **Step 1: Write failing tests**

```swift
import XCTest
@testable import SampleMate

final class NameFormatterTests: XCTestCase {
    let opts = NameFormatter.Options(separator: " - ", accidental: .sharp, includeOctave: true)

    func testAppendsNoteSuffixBeforeExtension() {
        let out = NameFormatter.newName(original: "Piano 13.wav",
                                        detection: Detection(kind: .note(name: "C#", octave: 3, midi: 61), confidence: 1),
                                        options: opts)
        XCTAssertEqual(out, "Piano 13 - C#3.wav")
    }

    func testAppendsKeySuffix() {
        let out = NameFormatter.newName(original: "Royalty_80_BPM.wav",
                                        detection: Detection(kind: .key(tonic: 2, minor: true), confidence: 1),
                                        options: opts)
        XCTAssertEqual(out, "Royalty_80_BPM - Dm.wav")
    }

    func testIdempotentReplacesExistingTag() {
        // Re-tagging a file that already has a tag must not append a second one.
        let out = NameFormatter.newName(original: "Piano 13 - C#3.wav",
                                        detection: Detection(kind: .note(name: "D", octave: 3, midi: 62), confidence: 1),
                                        options: opts)
        XCTAssertEqual(out, "Piano 13 - D3.wav")
    }

    func testAlreadyCorrectReturnsNil() {
        let out = NameFormatter.newName(original: "Piano 13 - C#3.wav",
                                        detection: Detection(kind: .note(name: "C#", octave: 3, midi: 61), confidence: 1),
                                        options: opts)
        XCTAssertNil(out)
    }

    func testNoneDetectionReturnsNil() {
        let out = NameFormatter.newName(original: "kick 3.wav",
                                        detection: Detection(kind: .none, confidence: 0),
                                        options: opts)
        XCTAssertNil(out)
    }

    func testFlatSpellingAndNoOctave() {
        let o = NameFormatter.Options(separator: "_", accidental: .flat, includeOctave: false)
        let out = NameFormatter.newName(original: "Bass 2.wav",
                                        detection: Detection(kind: .note(name: "A#", octave: 2, midi: 46), confidence: 1),
                                        options: o)
        XCTAssertEqual(out, "Bass 2_Bb.wav")
    }
}
```

- [ ] **Step 2: Run, verify failure**

Run: `xcodebuild test ... -only-testing:SampleMateTests/NameFormatterTests`
Expected: FAIL — `NameFormatter` undefined.

- [ ] **Step 3: Implement `NameFormatter.swift`**

```swift
import Foundation

enum NameFormatter {
    enum Accidental { case sharp, flat }
    struct Options {
        var separator: String = " - "
        var accidental: Accidental = .sharp
        var includeOctave: Bool = true
    }

    private static let sharp = ["C","C#","D","D#","E","F","F#","G","G#","A","A#","B"]
    private static let flat  = ["C","Db","D","Eb","E","F","Gb","G","Ab","A","Bb","B"]

    /// The tag token text for a detection, or nil if untaggable.
    static func tagToken(for detection: Detection, options: Options) -> String? {
        let names = options.accidental == .sharp ? sharp : flat
        switch detection.kind {
        case .none: return nil
        case let .note(_, octave, midi):
            let pc = ((midi % 12) + 12) % 12
            return options.includeOctave ? "\(names[pc])\(octave)" : names[pc]
        case let .key(tonic, minor):
            return "\(names[((tonic % 12) + 12) % 12])\(minor ? "m" : "")"
        }
    }

    // Matches a trailing " - <TAG>" or "_<TAG>" we previously wrote, before the extension.
    // TAG = note like C#3 / Db / A, or key like Dm / F#m.
    private static func tagRegex(separator: String) -> NSRegularExpression {
        let sep = NSRegularExpression.escapedPattern(for: separator)
        return try! NSRegularExpression(pattern: "\(sep)([A-G][#b]?-?\\d*m?)$")
    }

    /// New filename, or nil when untaggable or already correct.
    static func newName(original: String, detection: Detection, options: Options) -> String? {
        guard let token = tagToken(for: detection, options: options) else { return nil }
        let ext = (original as NSString).pathExtension
        var stem = (original as NSString).deletingPathExtension

        // strip an existing tag we wrote (idempotency)
        let re = tagRegex(separator: options.separator)
        if let m = re.firstMatch(in: stem, range: NSRange(stem.startIndex..., in: stem)),
           let r = Range(m.range, in: stem) {
            stem = String(stem[..<r.lowerBound])
        }
        let newStem = stem + options.separator + token
        let newName = ext.isEmpty ? newStem : "\(newStem).\(ext)"
        return newName == original ? nil : newName
    }

    /// Resolve a collision against existing names by appending " (2)", " (3)", …
    static func deduplicated(_ name: String, existing: Set<String>) -> String {
        guard existing.contains(name) else { return name }
        let ext = (name as NSString).pathExtension
        let stem = (name as NSString).deletingPathExtension
        var i = 2
        while true {
            let cand = ext.isEmpty ? "\(stem) (\(i))" : "\(stem) (\(i)).\(ext)"
            if !existing.contains(cand) { return cand }
            i += 1
        }
    }
}
```

- [ ] **Step 4: Run tests, verify pass**

Run: `xcodebuild test ... -only-testing:SampleMateTests/NameFormatterTests`
Expected: all 6 PASS.

- [ ] **Step 5: Commit**

```bash
git add SampleMate/Library/NameFormatter.swift SampleMateTests/NameFormatterTests.swift
git commit -m "feat: NameFormatter with idempotent tagging + collision handling"
```

---

## Task 4: AudioLoader + FolderScanner

**Files:**
- Create: `SampleMate/Library/AudioLoader.swift`
- Create: `SampleMate/Library/FolderScanner.swift`
- Test: `SampleMateTests/FolderScannerTests.swift`

- [ ] **Step 1: Write failing test** (scanner returns only audio files, recursively, excludes `.asd`)

```swift
import XCTest
@testable import SampleMate

final class FolderScannerTests: XCTestCase {
    func testEnumeratesAudioRecursivelyExcludingCompanions() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let sub = dir.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        for n in ["a.wav", "a.wav.asd", "b.aiff", "notes.txt"] {
            try Data().write(to: dir.appendingPathComponent(n))
        }
        try Data().write(to: sub.appendingPathComponent("c.flac"))
        defer { try? FileManager.default.removeItem(at: dir) }

        let found = FolderScanner.audioFiles(in: dir).map { $0.lastPathComponent }.sorted()
        XCTAssertEqual(found, ["a.wav", "b.aiff", "c.flac"])
    }
}
```

- [ ] **Step 2: Run, verify failure**

Run: `xcodebuild test ... -only-testing:SampleMateTests/FolderScannerTests`
Expected: FAIL — `FolderScanner` undefined.

- [ ] **Step 3: Implement `FolderScanner.swift`**

```swift
import Foundation

enum FolderScanner {
    static let audioExtensions: Set<String> = ["wav", "aif", "aiff", "flac"]

    static func audioFiles(in root: URL) -> [URL] {
        guard let en = FileManager.default.enumerator(at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]) else { return [] }
        var out: [URL] = []
        for case let url as URL in en where audioExtensions.contains(url.pathExtension.lowercased()) {
            out.append(url)
        }
        return out
    }
}
```

- [ ] **Step 4: Implement `AudioLoader.swift`** (used by TaggerEngine, no separate test — exercised in Task 5)

```swift
import AVFoundation

enum AudioLoader {
    static func loadMono(_ url: URL) -> (samples: [Float], sampleRate: Double)? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let sr = file.fileFormat.sampleRate
        guard let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sr,
                                      channels: file.fileFormat.channelCount, interleaved: false),
              file.length > 0,
              let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: buf)) != nil,
              let data = buf.floatChannelData else { return nil }
        let n = Int(buf.frameLength), ch = Int(fmt.channelCount)
        var mono = [Float](repeating: 0, count: n)
        for c in 0..<ch { let p = data[c]; for i in 0..<n { mono[i] += p[i] } }
        if ch > 1 { var s = Float(ch); vDSP_vsdiv(mono, 1, &s, &mono, 1, vDSP_Length(n)) }
        return (mono, sr)
    }
}
```

- [ ] **Step 5: Run scanner test, verify pass**

Run: `xcodebuild test ... -only-testing:SampleMateTests/FolderScannerTests`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add SampleMate/Library/AudioLoader.swift SampleMate/Library/FolderScanner.swift SampleMateTests/FolderScannerTests.swift
git commit -m "feat: FolderScanner + AudioLoader"
```

---

## Task 5: TagProposal + TaggerEngine

**Files:**
- Create: `SampleMate/Library/TagProposal.swift`
- Create: `SampleMate/Library/TaggerEngine.swift`

- [ ] **Step 1: Implement `TagProposal.swift`**

```swift
import Foundation

struct TagProposal: Identifiable {
    let id = UUID()
    let url: URL
    let detection: Detection
    var proposedName: String?      // nil when untaggable / already correct
    var apply: Bool
    enum Status: Equatable { case proposed, alreadyTagged, untaggable, error(String) }
    var status: Status
}
```

- [ ] **Step 2: Implement `TaggerEngine.swift`** (concurrent analysis; UI-facing state)

```swift
import Foundation
import Observation

@Observable
final class TaggerEngine {
    var proposals: [TagProposal] = []
    var options = NameFormatter.Options()
    var confidenceGate: Double = 0.6
    var done = 0
    var total = 0
    var isScanning = false

    @MainActor
    func scan(_ root: URL) async {
        proposals = []; done = 0; isScanning = true
        let files = FolderScanner.audioFiles(in: root)
        total = files.count
        let opts = options, gate = confidenceGate
        // bounded concurrency
        await withTaskGroup(of: TagProposal.self) { group in
            var inFlight = 0
            var idx = 0
            func submit(_ url: URL) {
                group.addTask { Self.analyzeOne(url, options: opts, gate: gate) }
            }
            while idx < files.count && inFlight < 8 { submit(files[idx]); idx += 1; inFlight += 1 }
            for await p in group {
                proposals.append(p); done += 1
                if idx < files.count { submit(files[idx]); idx += 1 }
            }
        }
        proposals.sort { $0.url.lastPathComponent < $1.url.lastPathComponent }
        isScanning = false
    }

    private static func analyzeOne(_ url: URL, options: NameFormatter.Options, gate: Double) -> TagProposal {
        guard let (mono, sr) = AudioLoader.loadMono(url) else {
            return TagProposal(url: url, detection: Detection(kind: .none, confidence: 0),
                               proposedName: nil, apply: false, status: .error("unreadable"))
        }
        let det = PitchKeyDetector.analyze(mono, sampleRate: sr)
        let newName = NameFormatter.newName(original: url.lastPathComponent, detection: det, options: options)
        let status: TagProposal.Status
        if case .none = det.kind { status = .untaggable }
        else if newName == nil { status = .alreadyTagged }
        else { status = .proposed }
        let auto = (status == .proposed) && det.confidence >= gate
        return TagProposal(url: url, detection: det, proposedName: newName, apply: auto, status: status)
    }
}
```

- [ ] **Step 3: Build to verify it compiles**

Run: `xcodebuild -project SampleMate.xcodeproj -scheme SampleMate -configuration Debug build`
Expected: build succeeds.

- [ ] **Step 4: Commit**

```bash
git add SampleMate/Library/TagProposal.swift SampleMate/Library/TaggerEngine.swift
git commit -m "feat: TaggerEngine concurrent analysis + proposals"
```

---

## Task 6: TagApplier (rename + .asd companion + undo)

**Files:**
- Create: `SampleMate/Library/TagApplier.swift`
- Test: `SampleMateTests/TagApplierTests.swift`

- [ ] **Step 1: Write failing integration test** (temp dir; apply renames wav + its `.asd`, writes undo log, undo restores)

```swift
import XCTest
@testable import SampleMate

final class TagApplierTests: XCTestCase {
    func testApplyRenamesWavAndAsdThenUndoRestores() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let wav = dir.appendingPathComponent("Piano 13.wav")
        let asd = dir.appendingPathComponent("Piano 13.wav.asd")
        try Data("x".utf8).write(to: wav); try Data("y".utf8).write(to: asd)

        var p = TagProposal(url: wav,
                            detection: Detection(kind: .note(name: "C#", octave: 3, midi: 61), confidence: 1),
                            proposedName: "Piano 13 - C#3.wav", apply: true, status: .proposed)
        let applier = TagApplier()
        let log = try applier.apply([p])

        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("Piano 13 - C#3.wav").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("Piano 13 - C#3.wav.asd").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: wav.path))

        try applier.undo(log)
        XCTAssertTrue(FileManager.default.fileExists(atPath: wav.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: asd.path))
    }
}
```

- [ ] **Step 2: Run, verify failure**

Run: `xcodebuild test ... -only-testing:SampleMateTests/TagApplierTests`
Expected: FAIL — `TagApplier` undefined.

- [ ] **Step 3: Implement `TagApplier.swift`**

```swift
import Foundation

struct UndoEntry: Codable { let old: String; let new: String }   // file paths
struct UndoLog: Codable { let appliedAt: Date; let entries: [UndoEntry] }

final class TagApplier {
    private let fm = FileManager.default

    /// Renames each applied proposal (and its `<name>.asd` companion). Returns the undo log.
    @discardableResult
    func apply(_ proposals: [TagProposal]) throws -> UndoLog {
        var entries: [UndoEntry] = []
        for p in proposals where p.apply {
            guard let newName = p.proposedName else { continue }
            let dir = p.url.deletingLastPathComponent()
            let dst = dir.appendingPathComponent(newName)
            try fm.moveItem(at: p.url, to: dst)
            entries.append(UndoEntry(old: p.url.path, new: dst.path))
            // companion: "<oldname>.asd" -> "<newname>.asd"
            let oldAsd = URL(fileURLWithPath: p.url.path + ".asd")
            if fm.fileExists(atPath: oldAsd.path) {
                let newAsd = URL(fileURLWithPath: dst.path + ".asd")
                try? fm.moveItem(at: oldAsd, to: newAsd)
                entries.append(UndoEntry(old: oldAsd.path, new: newAsd.path))
            }
        }
        let log = UndoLog(appliedAt: Date(), entries: entries)
        try persist(log)
        return log
    }

    /// Reverses a log (new -> old), skipping entries whose target moved since.
    func undo(_ log: UndoLog) throws {
        for e in log.entries.reversed() {
            let new = URL(fileURLWithPath: e.new), old = URL(fileURLWithPath: e.old)
            if fm.fileExists(atPath: new.path), !fm.fileExists(atPath: old.path) {
                try? fm.moveItem(at: new, to: old)
            }
        }
    }

    private func persist(_ log: UndoLog) throws {
        let base = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                              appropriateFor: nil, create: true)
            .appendingPathComponent("SampleMate/undo", isDirectory: true)
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: log.appliedAt).replacingOccurrences(of: ":", with: "-")
        let data = try JSONEncoder().encode(log)
        try data.write(to: base.appendingPathComponent("\(stamp).json"))
    }
}
```

> Note: the test injects `appliedAt: Date()` indirectly via `apply`. If determinism is needed,
> add an `apply(_:now:)` overload; not required for this test.

- [ ] **Step 4: Run test, verify pass**

Run: `xcodebuild test ... -only-testing:SampleMateTests/TagApplierTests`
Expected: PASS (rename + companion + undo all verified).

- [ ] **Step 5: Commit**

```bash
git add SampleMate/Library/TagApplier.swift SampleMateTests/TagApplierTests.swift
git commit -m "feat: TagApplier rename + .asd companion + undo log"
```

---

## Task 7: LibraryTaggerView (Tag Library tab UI)

**Files:**
- Create: `SampleMate/App/LibraryTaggerView.swift`

UI is verified manually (run the app), not unit-tested.

- [ ] **Step 1: Implement `LibraryTaggerView.swift`**

```swift
import SwiftUI
import UniformTypeIdentifiers

struct LibraryTaggerView: View {
    @State private var engine = TaggerEngine()
    @State private var scopedRoot: URL?
    private let applier = TagApplier()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Button { pickFolder() } label: { Label("Choose folder…", systemImage: "folder") }
                if engine.isScanning { ProgressView(value: Double(engine.done), total: Double(max(engine.total,1))) .frame(width: 160) }
                Spacer()
                Picker("Spelling", selection: $engine.options.accidental) {
                    Text("♯").tag(NameFormatter.Accidental.sharp); Text("♭").tag(NameFormatter.Accidental.flat)
                }.pickerStyle(.segmented).fixedSize()
                Toggle("Octave", isOn: $engine.options.includeOctave).toggleStyle(.checkbox)
            }

            Table(engine.proposals) {
                TableColumn("") { p in Toggle("", isOn: binding(for: p).apply).labelsHidden()
                    .disabled(p.status != .proposed) }.width(28)
                TableColumn("File") { p in Text(p.url.lastPathComponent) }
                TableColumn("Detected") { p in Text(detectedText(p.detection)) }
                TableColumn("Conf") { p in Text(String(format: "%.2f", p.detection.confidence)).monospacedDigit() }.width(48)
                TableColumn("→ New name") { p in Text(p.proposedName ?? "—").foregroundStyle(p.proposedName == nil ? .secondary : .primary) }
            }
            .frame(minHeight: 280)

            HStack {
                Text("\(engine.proposals.filter { $0.apply }.count) of \(engine.proposals.count) selected")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Apply") { try? applier.apply(engine.proposals); Task { if let r = scopedRoot { await engine.scan(r) } } }
                    .buttonStyle(.borderedProminent)
                    .disabled(engine.proposals.allSatisfy { !$0.apply })
            }
        }
        .padding(18)
    }

    private func detectedText(_ d: Detection) -> String {
        switch d.kind {
        case let .note(n, o, _): return "\(n)\(o)"
        case let .key(t, m): return "\(PitchKeyDetector.noteNames[t])\(m ? "m" : "")"
        case .none: return "—"
        }
    }

    private func binding(for p: TagProposal) -> Binding<TagProposal> {
        let i = engine.proposals.firstIndex { $0.id == p.id }!
        return $engine.proposals[i]
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        scopedRoot = url
        Task { await engine.scan(url) }
    }
}
```

- [ ] **Step 2: Build, verify it compiles**

Run: `xcodebuild -project SampleMate.xcodeproj -scheme SampleMate -configuration Debug build`
Expected: build succeeds.

- [ ] **Step 3: Commit**

```bash
git add SampleMate/App/LibraryTaggerView.swift
git commit -m "feat: Library Tagger tab UI"
```

---

## Task 8: RootView tab host

**Files:**
- Modify: `SampleMate/App/RootView.swift`

- [ ] **Step 1: Wrap the existing capture UI in a tab and add the tagger tab**

In `RootView`, extract the current `body`'s `VStack(...)` capture content into a private
`captureTab` computed property (move lines 14-21 content there unchanged), then replace `body`'s
inner content with a `TabView`:

```swift
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(white: 0.09), Color(white: 0.05)],
                           startPoint: .top, endPoint: .bottom).ignoresSafeArea()
            TabView {
                captureTab.tabItem { Label("Capture", systemImage: "waveform") }
                LibraryTaggerView().tabItem { Label("Tag Library", systemImage: "tag") }
            }
            .padding(22)
        }
        .frame(minWidth: 680, minHeight: 560)
        .tint(accent)
        .preferredColorScheme(.dark)
        .onAppear { engine.bootstrap() }
    }

    private var captureTab: some View {
        VStack(alignment: .leading, spacing: 18) {
            header; listenToCard; waveformSection; transport; footer
        }
    }
```

- [ ] **Step 2: Build + run, verify both tabs work**

Run: `xcodebuild -project SampleMate.xcodeproj -scheme SampleMate -configuration Debug build`
Then launch the app (or use the project `run` skill). Verify: Capture tab unchanged; Tag Library
tab opens, "Choose folder…" scans a small test folder, proposals appear, Apply renames, files on
disk show the new names + companion `.asd` renamed.

- [ ] **Step 3: Commit**

```bash
git add SampleMate/App/RootView.swift
git commit -m "feat: host Capture | Tag Library tabs in RootView"
```

---

## Task 9: Sha'ath profile validation

Port the Sha'ath major/minor tone-profile constants (numeric data) and keep them only if the
harness shows they help. Source: Ibrahim Sha'ath, "Estimation of key in digital music
recordings" (the libKeyFinder lineage); the 12-value major/minor profiles.

**Files:**
- Modify: `SampleMate/Audio/PitchKeyDetector.swift` (swap `KS_MAJOR`/`KS_MINOR` constants)
- Use: `prototype/compare.py`, `prototype/grade.py`

- [ ] **Step 1: Add Sha'ath constants behind a switch** in `PitchKeyDetector.swift`

```swift
// Krumhansl-Schmuckler (current default) retained for comparison.
private let KS_MAJOR: [Double] = [6.35,2.23,3.48,2.33,4.38,4.09,2.52,5.19,2.39,3.66,2.29,2.88]
private let KS_MINOR: [Double] = [6.33,2.68,3.52,5.38,2.60,3.53,2.54,4.75,3.98,2.69,3.34,3.17]
// Sha'ath profiles — fill from the cited source, then validate (Step 2).
private let SHAATH_MAJOR: [Double] = [ /* 12 values */ ]
private let SHAATH_MINOR: [Double] = [ /* 12 values */ ]
private let ACTIVE_MAJOR = SHAATH_MAJOR, ACTIVE_MINOR = SHAATH_MINOR
```

- [ ] **Step 2: Mirror the same constants in `prototype/detect.swift` and re-run the harness**

```sh
cd prototype
swiftc -O detect.swift -o detect -framework Accelerate -framework AVFoundation
P=$(brew --prefix); g++ -std=c++11 -O2 kf.cpp -o kf -I"$P/include" -L"$P/lib" -lkeyfinder -lsndfile
DYLD_LIBRARY_PATH=$P/lib python3 compare.py
```
Expected: Cookbook-full-mix `exact` for NATIVE **improves** (target: match libKeyFinder's 80%)
without the ALL `exact` dropping below the current 18%.

- [ ] **Step 3: Decision gate**

If Sha'ath improves clean-mix accuracy without overall regression, keep `ACTIVE_* = SHAATH_*`.
Otherwise set `ACTIVE_* = KS_*` and record the result in `prototype/README.md`. Either way the
app ships a validated choice.

- [ ] **Step 4: Commit**

```bash
git add SampleMate/Audio/PitchKeyDetector.swift prototype/detect.swift prototype/README.md
git commit -m "feat: validate + select tone profiles (Sha'ath vs KS) against harness"
```

---

## Self-Review

- **Spec coverage:** shared core (T2) · filename rename (T3) · scan dir/files (T4) · concurrent
  detect + proposals (T5) · preview table (T7) · apply + `.asd` companion + undo (T6) · tab UI
  (T7-8) · Sha'ath + validation (T9) · note-vs-key routing (T2 `analyze`) · idempotency &
  collision (T3) · security-scoped folder access (T7 `NSOpenPanel`). All spec sections covered.
- **Sandbox note:** if `SampleMate.entitlements` enables `com.apple.security.app-sandbox`, wrap
  scan/apply/undo in `scopedRoot.startAccessingSecurityScopedResource()` / `stop…` and persist a
  bookmark; if the app is not sandboxed (verify the entitlements file in T7), plain `FileManager`
  suffices. Confirm during T7.
- **Deferred (not gaps):** embedded WAV metadata, Camelot notation, BPM token, export-path reuse
  — explicitly phase-2 per spec.
