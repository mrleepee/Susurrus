import SwiftUI
import SusurrusKit

@main
struct SusurrusApp: App {
    @State private var appState = AppState()

    init() {
        // R1: Hide Dock icon — app lives in menu bar only
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        MenuBarExtra(
            "Susurrus",
            systemImage: MenuBarIcon.symbolName(for: appState.recordingState)
        ) {
            MenuBarView(appState: appState)
        }
    }
}
