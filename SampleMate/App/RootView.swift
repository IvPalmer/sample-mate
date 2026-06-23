import SwiftUI

struct RootView: View {
    @Bindable var engine: CaptureEngine

    private let accent = Color(red: 0.98, green: 0.45, blue: 0.55)

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(white: 0.09), Color(white: 0.05)],
                           startPoint: .top, endPoint: .bottom).ignoresSafeArea()
            TabView {
                captureTab.tabItem { Label("Capture", systemImage: "waveform") }
                LibraryTaggerView().tabItem { Label("Tag Library", systemImage: "tag") }
            }
            .padding(22)
        }
        .frame(minWidth: 680, minHeight: 560)
        .tint(accent)
        .preferredColorScheme(.dark)
        .onAppear { engine.bootstrap() }
    }

    private var captureTab: some View {
        VStack(alignment: .leading, spacing: 18) {
            header; listenToCard; waveformSection; transport; footer
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center) {
            HStack(spacing: 12) {
                Image(systemName: "waveform.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Sample Mate")
                        .font(.title2.bold())
                    Text("Grab anything you play off the live waveform.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            permissionChip
        }
    }

    @ViewBuilder
    private var permissionChip: some View {
        switch engine.permission.status {
        case .authorized:
            Label("Ready", systemImage: "checkmark.circle.fill")
                .font(.caption.weight(.medium))
                .foregroundStyle(.green)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(.green.opacity(0.12), in: Capsule())
        case .denied:
            Label("Denied", systemImage: "xmark.octagon.fill")
                .font(.caption.weight(.medium))
                .foregroundStyle(.red)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(.red.opacity(0.12), in: Capsule())
        case .unknown:
            Button { engine.requestPermission() } label: {
                Label("Grant audio access", systemImage: "lock.shield")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
    }

    // MARK: Listen-to card

    private var listenToCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("LISTEN TO").font(.caption.bold()).foregroundStyle(.secondary).tracking(1)

            Picker("", selection: $engine.mode) {
                ForEach(CaptureEngine.Mode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(engine.isCapturing)

            if engine.mode != .allAudio {
                Picker("App", selection: $engine.selectedProcess) {
                    Text("— Select an app —").tag(Optional<AudioProcess>.none)
                    ForEach(appProcesses) { proc in
                        Text(proc.audioActive ? "🔊 \(proc.name)" : proc.name).tag(Optional(proc))
                    }
                }
                .disabled(engine.isCapturing)
            }

            Text(modeHint).font(.caption).foregroundStyle(.tertiary)
        }
        .padding(16)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.06)))
    }

    private var appProcesses: [AudioProcess] {
        engine.processController.processes.filter { $0.kind == .app }
    }

    private var modeHint: String {
        switch engine.mode {
        case .allAudio: "Captures everything playing — including notification dings."
        case .onlyApp: "Captures only the chosen app. No notification bleed."
        case .excludeApp: "Captures everything except the chosen app (e.g. exclude Slack)."
        }
    }

    // MARK: Waveform

    private var waveformSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 12) {
                Picker("", selection: $engine.displayMode) {
                    ForEach(CaptureEngine.DisplayMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help("Scroll: moving timeline, scroll back. Loop: static fixed-size, overwrites in place.")

                Toggle("Skip silence", isOn: $engine.skipSilence)
                    .toggleStyle(.checkbox)
                    .help("Only advance the waveform while there's real audio.")

                Spacer()
            }

            WaveformStrip(engine: engine)
                .frame(maxWidth: .infinity)
                .frame(height: 170)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.08)))
                .shadow(color: .black.opacity(0.4), radius: 8, y: 3)

            HStack(spacing: 14) {
                Label("Drag to select → drag out", systemImage: "hand.draw")
                Label("Ctrl-click pause", systemImage: "pause.circle")
                Label("Scroll to look back", systemImage: "arrow.left.arrow.right")
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
    }

    // MARK: Transport

    private var transport: some View {
        HStack(spacing: 12) {
            if engine.isCapturing {
                Button(role: .destructive) { engine.stop() } label: {
                    Label("Stop", systemImage: "stop.fill").frame(maxWidth: .infinity)
                }
                .controlSize(.large)
            } else {
                Button { engine.start() } label: {
                    Label("Start Listening", systemImage: "waveform").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!engine.canStart)
            }

            Button { engine.revealExportFolder() } label: {
                Label("Exports", systemImage: "folder")
            }
            .controlSize(.large)
        }
    }

    // MARK: Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(engine.statusMessage).font(.caption).foregroundStyle(.secondary)
            if let error = engine.errorMessage {
                Text(error).font(.caption2).foregroundStyle(.red).textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#Preview {
    RootView(engine: CaptureEngine())
}
