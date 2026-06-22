import SwiftUI

@main
struct SampleMateApp: App {
    var body: some Scene {
        WindowGroup("Sample Mate") {
            RootView()
        }
        .windowResizability(.contentMinSize)
    }
}
