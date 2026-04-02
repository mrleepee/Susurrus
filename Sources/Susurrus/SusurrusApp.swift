import SwiftUI
import SusurrusKit
import os.log

@main
struct SusurrusApp: App {
    @State private var appState = AppState()
    @State private var pulseOn = false
    @State private var pulseTimer: Timer?
    @State private var modelLoading = false
    /// Live observation of recordingMode preference (fixes #9).
    @AppStorage("recordingMode") private var recordingMode = "push-to-talk"

    // Services
    private let transcriptionService = WhisperKitTranscriptionService()
    private let streamingService = StreamingTranscriptionService()
    private let clipboard = PasteboardClipboardService()
    private let notificationService = UserNotificationService()
    private let preferences = UserDefaultsPreferencesManager()
    private let vocabularyManager = VocabularyManager()
    private let hotkeyService = GlobalHotkeyService()
    private let llmHotkeyService = GlobalHotkeyService()
    private let hotkeyStorage = HotkeyStorage()
    private let micPermissionManager = MicPermissionManager()
    private let llmService = LLMService()
    private let historyManager = TranscriptionHistoryManager()

    // Recording duration timer
    @State private var durationTimer: Timer?

    // Throttle: minimum interval between overlay updates (ms)
    private let overlayThrottleInterval: TimeInterval = 0.1
    private var lastOverlayUpdate: Date = .distantPast

    /// Set to true while a model reload is in flight; disables model picker in UI.
    @State private var modelReloading = false

    /// The currently in-flight model reload task. Stored so it can be cancelled
    /// when the user selects a different model before the current reload finishes.
    @State private var currentModelReloadTask: Task<Void, Never>?

    // Streaming overlay window
    private var overlayWindow: StreamingOverlayWindow?

    init() {
        NSApplication.shared.setActivationPolicy(.accessory)

        if !AXIsProcessTrusted() {
            PasteboardClipboardService.promptAccessibility()
        }

        // Register hotkeys immediately (don't wait for menu bar click)
        // Note: setupHotkeyIfNeeded and setupLLMHotkeyIfNeeded are called
        // from MenuBarView.onAppear to avoid actor isolation issues in init.
        // They are also called here for the case where Accessibility is already granted.
        Task { @MainActor in
            startModelLoadingIfNeeded()
            setupHotkeyIfNeeded()
            setupLLMHotkeyIfNeeded()
            appState.recordingMode = preferences.recordingMode()
        }
    }

    var menuBarIcon: String {
        if !appState.modelReady {
            return pulseOn ? MenuBarIcon.loadingFrameA : MenuBarIcon.loadingFrameB
        }
        switch appState.recordingState {
        case .idle:
            return MenuBarIcon.symbolName(for: .idle)
        case .recording:
            return pulseOn ? MenuBarIcon.recordingFrameA : MenuBarIcon.recordingFrameB
        case .processing:
            return pulseOn ? MenuBarIcon.processingFrameA : MenuBarIcon.processingFrameB
        case .streaming:
            return pulseOn ? MenuBarIcon.streamingFrameA : MenuBarIcon.streamingFrameB
        case .finalizing:
            return pulseOn ? MenuBarIcon.finalizingFrameA : MenuBarIcon.finalizingFrameB
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
                setupLLMHotkeyIfNeeded()
                checkMicPermission()
            }
        }
        .onChange(of: appState.recordingState) { _, newState in
            handleStateChange(newState)
        }
        .onChange(of: appState.interimText) { _, newInterim in
            handleInterimTextChange(newInterim)
        }
        .onChange(of: recordingMode) { _, newMode in
            // Sync live preference change to AppState (fixes #9)
            if let mode = RecordingMode(rawValue: newMode) {
                appState.recordingMode = mode
            }
        }

        Window("Susurrus Preferences", id: "preferences") {
            PreferencesView()
        }
        .onChange(of: preferences.selectedModel()) { _, newModel in
            // Cancel any in-flight reload before starting a new one
            currentModelReloadTask?.cancel()
            let task = Task { @MainActor in
                modelReloading = true
                UserDefaults.standard.set(true, forKey: "modelReloading")
                await reloadModel(newModel)
                modelReloading = false
                UserDefaults.standard.set(false, forKey: "modelReloading")
            }
            currentModelReloadTask = task
        }

    /// The currently in-flight model reload task. Stored so it can be cancelled
    /// when the user selects a different model before the current reload finishes.
    @State private var currentModelReloadTask: Task<Void, Never>?

    @State private var modelReloading = false

        Window("History", id: "history") {
            HistoryView()
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
        let model = preferences.selectedModel()
        UserDefaults.standard.set(model, forKey: "modelDownloadingName")
        do {
            try await transcriptionService.setupModel(
                modelName: model,
                onDownloadProgress: { progress in
                    Task { @MainActor in
                        appState.modelLoadProgress = progress
                        UserDefaults.standard.set(progress, forKey: "modelDownloadProgress")
                    }
                }
            )
            // Also preload the streaming service with the same model
            try await streamingService.setupModel(
                modelName: model,
                onDownloadProgress: { progress in
                    Task { @MainActor in
                        appState.modelLoadProgress = progress
                        UserDefaults.standard.set(progress, forKey: "modelDownloadProgress")
                    }
                }
            )
            appState.modelReady = true
            UserDefaults.standard.set("", forKey: "modelDownloadingName")
            UserDefaults.standard.set(0, forKey: "modelDownloadProgress")
        } catch {
            modelLoading = false
            UserDefaults.standard.set("", forKey: "modelDownloadingName")
            UserDefaults.standard.set(0, forKey: "modelDownloadProgress")
        }
    }

    private func reloadModel(_ modelName: String) async {
        appState.modelReady = false
        modelLoading = true
        appState.modelLoadProgress = 0
        UserDefaults.standard.set(modelName, forKey: "modelDownloadingName")
        UserDefaults.standard.set(0, forKey: "modelDownloadProgress")
        await transcriptionService.unloadModel()
        await streamingService.unloadModel()
        do {
            try await transcriptionService.setupModel(
                modelName: modelName,
                onDownloadProgress: { progress in
                    Task { @MainActor in
                        appState.modelLoadProgress = progress
                        UserDefaults.standard.set(progress, forKey: "modelDownloadProgress")
                    }
                }
            )
            try await streamingService.setupModel(
                modelName: modelName,
                onDownloadProgress: { progress in
                    Task { @MainActor in
                        appState.modelLoadProgress = progress
                        UserDefaults.standard.set(progress, forKey: "modelDownloadProgress")
                    }
                }
            )
            appState.modelReady = true
            UserDefaults.standard.set("", forKey: "modelDownloadingName")
            UserDefaults.standard.set(0, forKey: "modelDownloadProgress")
        } catch {
            modelLoading = false
            UserDefaults.standard.set("", forKey: "modelDownloadingName")
            UserDefaults.standard.set(0, forKey: "modelDownloadProgress")
        }
    }

    private func checkMicPermission() {
        Task {
            let permission = await micPermissionManager.checkPermission()
            appState.micPermission = permission
        }
    }

    private func setupHotkeyIfNeeded() {
        guard !appState.hotkeyConfigured else { return }

        if !hotkeyStorage.isConfigured {
            hotkeyStorage.save(combo: .default)
        } else if let combo = hotkeyStorage.loadCombo(),
                  combo.keyCode == 0x3F || combo.keyCode == 0x6F || combo.keyCode == 0x0F {
            hotkeyStorage.save(combo: .default)
        }

        guard let combo = hotkeyStorage.loadCombo() else { return }

        Task {
            do {
                try await hotkeyService.register(
                    combo: combo,
                    onKeyDown: { [self] in
                        Task { @MainActor in
                            let started = appState.handleHotkeyDown()
                            if started {
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
            } catch let error as HotkeyError {
                let reason: String
                if case .registrationFailed(let msg) = error {
                    reason = msg
                } else {
                    reason = String(describing: error)
                }
                notificationService.showNotification(
                    title: "Susurrus",
                    body: "Hotkey registration failed: \(reason). The hotkey may conflict with another app."
                )
            } catch {
                notificationService.showNotification(
                    title: "Susurrus",
                    body: "Hotkey registration failed for an unknown reason."
                )
        }
    }

    private func setupLLMHotkeyIfNeeded() {
        guard !appState.llmHotkeyConfigured else { return }

        let combo = HotkeyCombo.withLLM
        Task {
            do {
                try await llmHotkeyService.register(
                    combo: combo,
                    onKeyDown: { [self] in
                        Task { @MainActor in
                            appState.forceLLM = true
                            let started = appState.handleHotkeyDown()
                            if started {
                                if appState.micPermission == .undetermined {
                                    let perm = await micPermissionManager.requestPermission()
                                    appState.micPermission = perm
                                }
                                guard appState.micPermission == .granted else {
                                    appState.forceLLM = false
                                    appState.cancel()
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
                appState.llmHotkeyConfigured = true
            } catch let error as HotkeyError {
                let reason: String
                if case .registrationFailed(let msg) = error {
                    reason = msg
                } else {
                    reason = String(describing: error)
                }
                notificationService.showNotification(
                    title: "Susurrus",
                    body: "LLM hotkey registration failed: \(reason). The hotkey may conflict with another app."
                )
            } catch {
                notificationService.showNotification(
                    title: "Susurrus",
                    body: "LLM hotkey registration failed for an unknown reason."
                )
        }
    }

    // MARK: - State change handling

    private func handleStateChange(_ newState: RecordingState) {
        updatePulseAnimation(newState)

        switch newState {
        case .streaming:
            startStreamingSession()
        case .finalizing:
            stopStreamingSession()
        case .idle:
            stopDurationTimer()
        case .recording, .processing:
            // Batch mode — handled by Phase 7; no-op for now
            break
        }
    }

    /// Called whenever appState.interimText changes.
    /// Throttled to avoid rebuilding the overlay on every audio callback (~10/sec).
    private func handleInterimTextChange(_ interim: InterimTranscript?) {
        guard let interim else { return }
        let now = Date()
        guard now.timeIntervalSince(lastOverlayUpdate) >= overlayThrottleInterval else { return }
        lastOverlayUpdate = now
        overlayWindow?.show(confirmed: interim.confirmed, unconfirmed: interim.unconfirmed)
    }

    // MARK: - Streaming session

    private func startStreamingSession() {
        startDurationTimer()

        // Lazily create the overlay window
        if overlayWindow == nil {
            overlayWindow = StreamingOverlayWindow()
        }

        // Sync vocabulary bias
        let vocab = vocabularyManager.promptString()
        Task {
            await streamingService.setVocabularyPrompt(vocab)
        }

        // Start streaming
        Task {
            do {
                try await streamingService.startStreamTranscription { [weak self] transcript in
                    Task { @MainActor in
                        self?.appState.interimText = transcript
                    }
                }
            } catch {
                Task { @MainActor in
                    self.appState.cancel()
                    self.notificationService.showNotification(
                        title: "Susurrus",
                        body: "Streaming failed to start"
                    )
                }
            }
        }
    }

    private func stopStreamingSession() {
        stopDurationTimer()
        overlayWindow?.hide()

        let appendMode = preferences.appendToClipboard()
        let shouldLLM = appState.forceLLM || preferences.llmEnabled()
        appState.forceLLM = false

        Task {
            do {
                let text = try await streamingService.stopStreamTranscription()

                if !text.isEmpty {
                    var finalText = text

                    if shouldLLM {
                        do {
                            let prompt = preferences.llmSystemPrompt()
                            finalText = try await llmService.process(text: text, systemPrompt: prompt)
                        } catch {
                            // LLM failed — use raw transcription
                        }
                    }

                    if appendMode {
                        clipboard.appendText(finalText)
                    } else {
                        clipboard.writeText(finalText)
                    }

                    let autoPaste = preferences.autoPasteEnabled()
                    Logger(subsystem: "com.susurrus.app", category: "Flow").info("autoPaste=\(autoPaste)")
                    if autoPaste {
                        try? await Task.sleep(for: .milliseconds(150))
                        let pasted = clipboard.simulatePaste()
                        if !pasted {
                            notificationService.showNotification(
                                title: "Susurrus",
                                body: "Auto-paste requires Accessibility access. Enable in System Settings > Privacy & Security > Accessibility."
                            )
                        }
                    }

                    historyManager.add(finalText)
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
                // Transcription failed — clipboard untouched
            }

            // Consume the duration cap flag after notification (Behaviour 2.6)
            if appState.wasDurationCapped {
                appState.consumeDurationCapped()
            }

            appState.finishStreaming()
        }
    }

    // MARK: - Duration cap

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

        guard state == .streaming || state == .finalizing || state == .recording || state == .processing else {
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
