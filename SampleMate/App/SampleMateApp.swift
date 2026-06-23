import SwiftUI

@main
struct SampleMateApp: App {
    @State private var engine = CaptureEngine()

    var body: some Scene {
        WindowGroup("Sample Mate") {
            RootView(engine: engine)
        }
        .windowResizability(.contentMinSize)

        Settings {
            SettingsView(engine: engine)
        }
    }
}
