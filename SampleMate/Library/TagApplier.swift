import Foundation

struct UndoEntry: Codable { let old: String; let new: String }   // file paths
struct UndoLog: Codable { let appliedAt: Date; let entries: [UndoEntry] }
struct ApplyResult { let log: UndoLog; let failures: [String] }  // failures: "filename: reason"

final class TagApplier {
    private let fm = FileManager.default

    func apply(_ proposals: [TagProposal]) -> ApplyResult {
        var entries: [UndoEntry] = []
        var failures: [String] = []

        for p in proposals where p.apply {
            guard let newName = p.proposedName else { continue }
            let src = p.url
            let dir = src.deletingLastPathComponent()

            // Build existing-names set: on-disk entries UNION names already committed in this batch.
            let onDisk: Set<String>
            if let contents = try? fm.contentsOfDirectory(atPath: dir.path) {
                onDisk = Set(contents)
            } else {
                onDisk = []
            }
            let inFlight = Set(entries.map { URL(fileURLWithPath: $0.new).lastPathComponent })
            let existing = onDisk.union(inFlight)

            // Resolve collisions.
            let finalName = NameFormatter.deduplicated(newName, existing: existing)
            let dst = dir.appendingPathComponent(finalName)

            // Move wav.
            do {
                try fm.moveItem(at: src, to: dst)
            } catch {
                failures.append("\(src.lastPathComponent): \(error.localizedDescription)")
                continue
            }
            entries.append(UndoEntry(old: src.path, new: dst.path))

            // Move .asd companion (best-effort; only record on success).
            let oldAsd = URL(fileURLWithPath: src.path + ".asd")
            if fm.fileExists(atPath: oldAsd.path) {
                let newAsd = URL(fileURLWithPath: dst.path + ".asd")
                if (try? fm.moveItem(at: oldAsd, to: newAsd)) != nil {
                    entries.append(UndoEntry(old: oldAsd.path, new: newAsd.path))
                }
            }
        }

        let log = UndoLog(appliedAt: Date(), entries: entries)
        if !entries.isEmpty {
            do { try persist(log) } catch {
                failures.append("undo-log: \(error.localizedDescription)")
            }
        }
        return ApplyResult(log: log, failures: failures)
    }

    func undo(_ log: UndoLog) -> [String] {
        var failures: [String] = []
        for e in log.entries.reversed() {
            let newURL = URL(fileURLWithPath: e.new)
            let oldURL = URL(fileURLWithPath: e.old)
            guard fm.fileExists(atPath: newURL.path), !fm.fileExists(atPath: oldURL.path) else { continue }
            do {
                try fm.moveItem(at: newURL, to: oldURL)
            } catch {
                failures.append("\(newURL.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return failures
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
