import XCTest
import Accelerate
@testable import SampleMate

final class PitchKeyDetectorTests: XCTestCase {
    private func tone(midi: Int, sr: Double = 44100, seconds: Double = 1.0) -> [Float] {
        let f = 440.0 * pow(2.0, Double(midi - 69) / 12.0)
        let n = Int(sr * seconds)
        return (0..<n).map { i in
            let t = Double(i) / sr
            return Float(0.6*sin(2 * .pi*f*t) + 0.25*sin(2 * .pi*2*f*t) + 0.12*sin(2 * .pi*3*f*t))
        }
    }
    func testDetectsNoteOfPureTone() {
        let d = PitchKeyDetector.analyze(tone(midi: 60), sampleRate: 44100)
        guard case let .note(name, octave, midi) = d.kind else { return XCTFail("expected note, got \(d.kind)") }
        XCTAssertEqual(name, "C"); XCTAssertEqual(octave, 4); XCTAssertEqual(midi, 60)
    }
    func testSilenceIsNone() {
        let d = PitchKeyDetector.analyze([Float](repeating: 0, count: 44100), sampleRate: 44100)
        if case .none = d.kind {} else { XCTFail("silence should be .none") }
    }
}
