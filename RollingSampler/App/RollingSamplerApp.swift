import SwiftUI

@main
struct RollingSamplerApp: App {
    var body: some Scene {
        WindowGroup("Sample Mate") {
            RootView()
        }
        .windowResizability(.contentMinSize)
    }
}
