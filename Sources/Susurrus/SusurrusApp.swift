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
    private let hotkeyService = GlobalHotkeyService()
    private let hotkeyStorage = HotkeyStorage()
    private let micPermissionManager = MicPermissionManager()

    // Recording duration timer
    @State private var durationTimer: Timer?

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
                setupHotkeyIfNeeded()
                checkMicPermission()
            }
        }
        .onChange(of: appState.recordingState) { _, newState in
            handleStateChange(newState)
        }
    }

    // MARK: - Setup

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

    private func checkMicPermission() {
        Task {
            let permission = await micPermissionManager.checkPermission()
            appState.micPermission = permission
        }
    }

    private func setupHotkeyIfNeeded() {
        guard hotkeyStorage.isConfigured, !appState.hotkeyConfigured else { return }
        guard let combo = hotkeyStorage.loadCombo() else { return }

        Task {
            do {
                try await hotkeyService.register(
                    combo: combo,
                    onKeyDown: { [self] in
                        Task { @MainActor in
                            let started = appState.handleHotkeyDown()
                            if started {
                                // Request permission if needed
                                if appState.micPermission == .undetermined {
                                    let perm = await micPermissionManager.requestPermission()
                                    appState.micPermission = perm
                                }
                                guard appState.micPermission == .granted else {
                                    appState.cancel()
                                    notificationService.showNotification(
                                        title: "Susurrus",
                                        body: "Microphone access required. Enable in System Settings > Privacy > Microphone."
                                    )
                                    return
                                }
                            }
                        }
                    },
                    onKeyUp: { [self] in
                        Task { @MainActor in
                            appState.handleHotkeyUp()
                        }
                    }
                )
                appState.hotkeyConfigured = true
            } catch {
                // Hotkey registration failed
            }
        }
    }

    // MARK: - State handling

    private func handleStateChange(_ newState: RecordingState) {
        updatePulseAnimation(newState)

        switch newState {
        case .recording:
            startDurationTimer()
            Task {
                do {
                    try await audioCapture.startCapture()
                } catch {
                    appState.cancel()
                }
            }
        case .processing:
            stopDurationTimer()
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
            stopDurationTimer()
        }
    }

    // MARK: - Duration cap (R9)

    private func startDurationTimer() {
        durationTimer?.invalidate()
        durationTimer = Timer.scheduledTimer(
            withTimeInterval: AppState.maxRecordingDuration,
            repeats: false
        ) { _ in
            Task { @MainActor in
                if appState.enforceDurationCap() {
                    notificationService.showNotification(
                        title: "Susurrus",
                        body: "Recording capped at 60 seconds"
                    )
                }
            }
        }
    }

    private func stopDurationTimer() {
        durationTimer?.invalidate()
        durationTimer = nil
    }

    // MARK: - Animation

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
