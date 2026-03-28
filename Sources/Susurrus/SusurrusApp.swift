import SwiftUI
import SusurrusKit

@main
struct SusurrusApp: App {
    @State private var appState = AppState()
    @State private var pulseOn = false
    @State private var pulseTimer: Timer?
    @State private var modelLoading = false

    // Services
    private let transcriptionService = WhisperKitTranscriptionService()
    private let audioCapture = AudioCaptureService()
    private let clipboard = PasteboardClipboardService()
    private let notificationService = UserNotificationService()
    private let preferences = UserDefaultsPreferencesManager()
    private let vocabularyManager = VocabularyManager()

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
            MenuBarView(appState: appState) {
                startModelLoadingIfNeeded()
            }
        }
        .onChange(of: appState.recordingState) { _, newState in
            handleStateChange(newState)
        }
    }

    private func startModelLoadingIfNeeded() {
        guard !modelLoading else { return }
        modelLoading = true
        Task {
            await preloadModel()
        }
    }

    private func preloadModel() async {
        do {
            try await transcriptionService.setupModel(
                modelName: "base",
                onDownloadProgress: { progress in
                    Task { @MainActor in
                        appState.modelLoadProgress = progress
                    }
                }
            )
            appState.modelReady = true
        } catch {
            modelLoading = false
        }
    }

    private func handleStateChange(_ newState: RecordingState) {
        updatePulseAnimation(newState)

        switch newState {
        case .recording:
            Task {
                do {
                    try await audioCapture.startCapture()
                } catch {
                    appState.cancel()
                }
            }
        case .processing:
            let appendMode = preferences.appendToClipboard()
            Task {
                do {
                    let audioBuffer = try await audioCapture.stopCapture()
                    let text = try await transcriptionService.transcribe(audio: audioBuffer)

                    if !text.isEmpty {
                        if appendMode {
                            clipboard.appendText(text)
                        } else {
                            clipboard.writeText(text)
                        }
                        notificationService.showNotification(
                            title: "Susurrus",
                            body: "Copied to clipboard"
                        )
                    } else {
                        notificationService.showNotification(
                            title: "Susurrus",
                            body: "No speech detected"
                        )
                    }
                } catch TranscriptionError.noSpeechDetected {
                    notificationService.showNotification(
                        title: "Susurrus",
                        body: "No speech detected"
                    )
                } catch {
                    // Transcription failed — clipboard is untouched (R17)
                }
                appState.finishProcessing()
            }
        case .idle:
            break
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
