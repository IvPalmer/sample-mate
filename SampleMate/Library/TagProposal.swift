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
