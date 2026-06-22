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
