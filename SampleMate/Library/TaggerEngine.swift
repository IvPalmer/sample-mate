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
        await withTaskGroup(of: TagProposal.self) { group in
            var idx = 0
            var inFlight = 0
            // Seed up to 8 concurrent tasks; capture the URL by value before advancing idx.
            while idx < files.count && inFlight < 8 {
                let u = files[idx]
                group.addTask { Self.analyzeOne(u, options: opts, gate: gate) }
                idx += 1; inFlight += 1
            }
            for await p in group {
                proposals.append(p); done += 1
                if idx < files.count {
                    let u = files[idx]
                    group.addTask { Self.analyzeOne(u, options: opts, gate: gate) }
                    idx += 1
                }
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
