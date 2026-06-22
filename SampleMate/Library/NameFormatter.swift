import Foundation

enum NameFormatter {
    enum Accidental { case sharp, flat }
    struct Options {
        var separator: String = " - "
        var accidental: Accidental = .sharp
        var includeOctave: Bool = true
    }
    private static let sharp = ["C","C#","D","D#","E","F","F#","G","G#","A","A#","B"]
    private static let flat  = ["C","Db","D","Eb","E","F","Gb","G","Ab","A","Bb","B"]

    static func tagToken(for detection: Detection, options: Options) -> String? {
        let names = options.accidental == .sharp ? sharp : flat
        switch detection.kind {
        case .none: return nil
        case let .note(_, octave, midi):
            let pc = ((midi % 12) + 12) % 12
            return options.includeOctave ? "\(names[pc])\(octave)" : names[pc]
        case let .key(tonic, minor):
            return "\(names[((tonic % 12) + 12) % 12])\(minor ? "m" : "")"
        }
    }
    private static func tagRegex(separator: String) -> NSRegularExpression {
        let sep = NSRegularExpression.escapedPattern(for: separator)
        return try! NSRegularExpression(pattern: "\(sep)([A-G][#b]?-?\\d*m?)$")
    }
    static func newName(original: String, detection: Detection, options: Options) -> String? {
        guard let token = tagToken(for: detection, options: options) else { return nil }
        let ext = (original as NSString).pathExtension
        var stem = (original as NSString).deletingPathExtension
        let re = tagRegex(separator: options.separator)
        if let m = re.firstMatch(in: stem, range: NSRange(stem.startIndex..., in: stem)),
           let r = Range(m.range, in: stem) {
            stem = String(stem[..<r.lowerBound])
        }
        let newStem = stem + options.separator + token
        let newName = ext.isEmpty ? newStem : "\(newStem).\(ext)"
        return newName == original ? nil : newName
    }
    static func deduplicated(_ name: String, existing: Set<String>) -> String {
        guard existing.contains(name) else { return name }
        let ext = (name as NSString).pathExtension
        let stem = (name as NSString).deletingPathExtension
        var i = 2
        while true {
            let cand = ext.isEmpty ? "\(stem) (\(i))" : "\(stem) (\(i)).\(ext)"
            if !existing.contains(cand) { return cand }
            i += 1
        }
    }
}
