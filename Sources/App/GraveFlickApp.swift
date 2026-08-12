import SwiftUI

@main
struct GraveFlickApp: App {
    init() {
        _ = DiagnosticsManager.shared
    }

    var body: some Scene {
        WindowGroup {
            GameRootView()
        }
    }
}
