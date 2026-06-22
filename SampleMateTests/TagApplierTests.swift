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

        let p = TagProposal(url: wav,
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
