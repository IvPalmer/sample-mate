import SwiftUI
import UniformTypeIdentifiers

struct LibraryTaggerView: View {
    @State private var engine = TaggerEngine()
    @State private var scopedRoot: URL?
    private let applier = TagApplier()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Button { pickFolder() } label: { Label("Choose folder…", systemImage: "folder") }
                if engine.isScanning {
                    ProgressView(value: Double(engine.done), total: Double(max(engine.total, 1))).frame(width: 160)
                }
                Spacer()
                Picker("Spelling", selection: $engine.options.accidental) {
                    Text("♯").tag(NameFormatter.Accidental.sharp)
                    Text("♭").tag(NameFormatter.Accidental.flat)
                }.pickerStyle(.segmented).fixedSize()
                Toggle("Octave", isOn: $engine.options.includeOctave).toggleStyle(.checkbox)
            }

            Table(engine.proposals) {
                TableColumn("") { p in
                    Toggle("", isOn: binding(for: p).apply).labelsHidden().disabled(p.status != .proposed)
                }.width(28)
                TableColumn("File") { p in Text(p.url.lastPathComponent) }
                TableColumn("Detected") { p in Text(detectedText(p.detection)) }
                TableColumn("Conf") { p in Text(String(format: "%.2f", p.detection.confidence)).monospacedDigit() }.width(48)
                TableColumn("→ New name") { p in
                    Text(p.proposedName ?? "—").foregroundStyle(p.proposedName == nil ? .secondary : .primary)
                }
            }
            .frame(minHeight: 280)

            HStack {
                Text("\(engine.proposals.filter { $0.apply }.count) of \(engine.proposals.count) selected")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Apply") {
                    try? applier.apply(engine.proposals)
                    Task { if let r = scopedRoot { await engine.scan(r) } }
                }
                .buttonStyle(.borderedProminent)
                .disabled(engine.proposals.allSatisfy { !$0.apply })
            }
        }
        .padding(18)
    }

    private func detectedText(_ d: Detection) -> String {
        switch d.kind {
        case let .note(n, o, _): return "\(n)\(o)"
        case let .key(t, m): return "\(PitchKeyDetector.noteNames[t])\(m ? "m" : "")"
        case .none: return "—"
        }
    }

    private func binding(for p: TagProposal) -> Binding<TagProposal> {
        let i = engine.proposals.firstIndex { $0.id == p.id }!
        return $engine.proposals[i]
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        scopedRoot = url
        Task { await engine.scan(url) }
    }
}
