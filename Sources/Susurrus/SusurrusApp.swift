import SwiftUI
import SusurrusKit

@main
struct SusurrusApp: App {
    @State private var appState = AppState()
    @State private var pulseOn = false
    @State private var pulseTimer: Timer?

    init() {
        // R1: Hide Dock icon — app lives in menu bar only
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    var menuBarIcon: String {
        switch appState.recordingState {
        case .idle:
            return MenuBarIcon.symbolName(for: .idle)
        case .recording:
            return pulseOn ? MenuBarIcon.recordingFrameA : MenuBarIcon.recordingFrameB
        case .processing:
            return pulseOn ? MenuBarIcon.processingFrameA : MenuBarIcon.processingFrameB
        }
    }

    var body: some Scene {
        MenuBarExtra(
            "Susurrus",
            systemImage: menuBarIcon
        ) {
            MenuBarView(appState: appState)
        }
        .onChange(of: appState.recordingState) { _, newState in
            updatePulseAnimation(newState)
        }
    }

    private func updatePulseAnimation(_ state: RecordingState) {
        pulseTimer?.invalidate()
        pulseTimer = nil

        guard state == .recording || state == .processing else {
            pulseOn = false
            return
        }

        pulseOn = true
        pulseTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { _ in
            Task { @MainActor in
                pulseOn.toggle()
            }
        }
    }
}
