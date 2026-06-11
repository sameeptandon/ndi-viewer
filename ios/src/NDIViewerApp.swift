import SwiftUI

@main
struct NDIViewerApp: App {
    var body: some Scene {
        WindowGroup("NDI Viewer") {
            MainDashboard()
        }
        #if os(macOS)
        .windowStyle(.hiddenTitleBar)
        #endif
    }
}
