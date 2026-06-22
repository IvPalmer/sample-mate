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
