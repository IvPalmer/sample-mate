import SwiftUI

struct SettingsView: View {
    @Bindable var engine: CaptureEngine

    private var bufferLabel: String {
        let s = Int(engine.bufferSeconds)
        return s % 60 == 0 ? "\(s / 60) min" : "\(s)s"
    }

    var body: some View {
        Form {
            Section("Rolling buffer") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Keep last")
                        Spacer()
                        Text(bufferLabel).foregroundStyle(.secondary).monospacedDigit()
                    }
                    Slider(value: $engine.bufferSeconds, in: 15...600, step: 15)
                        .disabled(engine.isCapturing)
                    Text("How far back you can grab audio off the waveform. Uses ~22 MB of RAM per minute. Can't be changed while listening.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
        }
        .formStyle(.grouped)
        .frame(width: 400)
    }
}
