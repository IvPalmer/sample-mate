import Foundation

struct UndoEntry: Codable { let old: String; let new: String }   // file paths
struct UndoLog: Codable { let appliedAt: Date; let entries: [UndoEntry] }

final class TagApplier {
    private let fm = FileManager.default

    @discardableResult
    func apply(_ proposals: [TagProposal]) throws -> UndoLog {
        var entries: [UndoEntry] = []
        for p in proposals where p.apply {
            guard let newName = p.proposedName else { continue }
            let dir = p.url.deletingLastPathComponent()
            let dst = dir.appendingPathComponent(newName)
            try fm.moveItem(at: p.url, to: dst)
            entries.append(UndoEntry(old: p.url.path, new: dst.path))
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
