import XCTest
@testable import SampleMate

final class TagApplierTests: XCTestCase {

    // MARK: - Helper

    private func makeDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Test 1: rename wav + .asd, then undo restores

    func testApplyRenamesWavAndAsdThenUndoRestores() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let wav = dir.appendingPathComponent("Piano 13.wav")
        let asd = dir.appendingPathComponent("Piano 13.wav.asd")
        try Data("x".utf8).write(to: wav)
        try Data("y".utf8).write(to: asd)

        let p = TagProposal(url: wav,
                            detection: Detection(kind: .note(name: "C#", octave: 3, midi: 61), confidence: 1),
                            proposedName: "Piano 13 - C#3.wav", apply: true, status: .proposed)
        let applier = TagApplier()
        let result = applier.apply([p])

        XCTAssertTrue(result.failures.isEmpty, "Expected no failures, got: \(result.failures)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("Piano 13 - C#3.wav").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("Piano 13 - C#3.wav.asd").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: wav.path))

        let undoFailures = applier.undo(result.log)
        XCTAssertTrue(undoFailures.isEmpty, "Undo failures: \(undoFailures)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: wav.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: asd.path))
    }

    // MARK: - Test 2: collision produces deduplicated name

    func testApplyDeduplicatesCollidingName() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Pre-existing file that would collide with the proposed name.
        let existing = dir.appendingPathComponent("Bass - C3.wav")
        try Data("pre".utf8).write(to: existing)

        // The source file to be renamed.
        let wav = dir.appendingPathComponent("Bass.wav")
        try Data("src".utf8).write(to: wav)

        let p = TagProposal(url: wav,
                            detection: Detection(kind: .note(name: "C", octave: 3, midi: 60), confidence: 1),
                            proposedName: "Bass - C3.wav", apply: true, status: .proposed)
        let applier = TagApplier()
        let result = applier.apply([p])

        XCTAssertTrue(result.failures.isEmpty, "Expected no failures, got: \(result.failures)")
        // Source should be gone.
        XCTAssertFalse(FileManager.default.fileExists(atPath: wav.path))
        // Deduplicated name should exist.
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("Bass - C3 (2).wav").path))
        // Pre-existing file untouched.
        XCTAssertTrue(FileManager.default.fileExists(atPath: existing.path))
    }

    // MARK: - Test 3: one failing file does not abort batch; log records successes

    func testApplyPartialFailureRecordsSuccesses() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Valid file.
        let goodWav = dir.appendingPathComponent("Kick.wav")
        try Data("g".utf8).write(to: goodWav)

        let goodProposal = TagProposal(url: goodWav,
                                       detection: Detection(kind: .note(name: "C", octave: 3, midi: 60), confidence: 1),
                                       proposedName: "Kick - C3.wav", apply: true, status: .proposed)

        // Non-existent source — move will fail.
        let missingURL = dir.appendingPathComponent("DoesNotExist.wav")
        let badProposal = TagProposal(url: missingURL,
                                      detection: Detection(kind: .note(name: "D", octave: 3, midi: 62), confidence: 1),
                                      proposedName: "DoesNotExist - D3.wav", apply: true, status: .proposed)

        let applier = TagApplier()
        let result = applier.apply([goodProposal, badProposal])

        // Exactly one failure for the missing file.
        XCTAssertEqual(result.failures.count, 1, "Expected 1 failure, got: \(result.failures)")
        // The good rename went through.
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("Kick - C3.wav").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: goodWav.path))
        // The undo log captured the successful rename.
        XCTAssertFalse(result.log.entries.isEmpty, "Undo log should have at least one entry for the successful rename")
    }
}
