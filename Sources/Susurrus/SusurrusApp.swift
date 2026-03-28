import SwiftUI
import SusurrusKit

@main
struct SusurrusApp: App {
    @State private var appState = AppState()
    @State private var pulseOn = false
    @State private var pulseTimer: Timer?

    private let transcriptionService = WhisperKitTranscriptionService()
    private let modelManager = WhisperKitModelManager()

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
                .onAppear {
                    Task {
                        await preloadModel()
                    }
                }
        }
        .onChange(of: appState.recordingState) { _, newState in
            updatePulseAnimation(newState)
        }
    }

    /// R15: Pre-load WhisperKit model at app launch.
    private func preloadModel() async {
        do {
            try await transcriptionService.setupModel(
                modelManager: modelManager,
                onDownloadProgress: { progress in
                    Task { @MainActor in
                        appState.modelLoadProgress = progress
                    }
                }
            )
            appState.modelReady = true
        } catch {
            // Model load failed — user can retry from menu
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
