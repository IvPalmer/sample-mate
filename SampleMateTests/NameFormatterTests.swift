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
