import SwiftUI
import SusurrusKit
import AVFoundation
import os.log

private let log = Logger(subsystem: "com.susurrus.app", category: "App")

/// NSLog wrapper — always visible in Console.app and `log show`, unlike os.Logger info.
private func traceApp(_ message: String) {
    let path = NSHomeDirectory() + "/susurrus_debug.log"
    let line = "\(Date()) \(message)\n"
    if let handle = FileHandle(forWritingAtPath: path) {
        handle.seekToEndOfFile()
        handle.write(Data(line.utf8))
        handle.closeFile()
    } else {
        FileManager.default.createFile(atPath: path, contents: Data(line.utf8))
    }
}

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
    @State private var lastOverlayUpdate: Date = .distantPast

    /// Set to true while a model reload is in flight; disables model picker in UI.
    @State private var modelReloading = false

    /// The currently in-flight model reload task. Stored so it can be cancelled
    /// when the user selects a different model before the current reload finishes.
    @State private var currentModelReloadTask: Task<Void, Never>?

    // Streaming overlay window
    @State private var overlayWindow: StreamingOverlayWindow?

    init() {
        NSApplication.shared.setActivationPolicy(.accessory)

        if !AXIsProcessTrusted() {
            PasteboardClipboardService.promptAccessibility()
        }

        // Note: setupHotkeyIfNeeded and setupLLMHotkeyIfNeeded are called
        // from MenuBarView.onAppear to avoid actor isolation issues in init.
        // Model loading also starts from onAppear.
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
                appState.recordingMode = preferences.recordingMode()
                appState.onStreamingStart = { self.startStreamingSession() }
                appState.onStreamingStop = { self.stopStreamingSession() }
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

        Window("History", id: "history") {
            HistoryView()
        }
    }

    // MARK: - Setup

    private func startModelLoadingIfNeeded() {
        guard !modelLoading else { return }
        modelLoading = true
        traceApp("startModelLoadingIfNeeded: starting model load")
        Task {
            await preloadModel()
        }
    }

    private func preloadModel() async {
        let model = preferences.selectedModel()
        traceApp("preloadModel: loading model '\(model)'")
        UserDefaults.standard.set(model, forKey: "modelDownloadingName")
        let state = appState
        let transcription = transcriptionService
        let streaming = streamingService
        do {
            try await transcription.setupModel(
                modelName: model,
                onDownloadProgress: { progress in
                    Task { @MainActor in
                        state.modelLoadProgress = progress
                        UserDefaults.standard.set(progress, forKey: "modelDownloadProgress")
                    }
                }
            )
            // Also preload the streaming service with the same model
            try await streaming.setupModel(
                modelName: model,
                onDownloadProgress: { progress in
                    Task { @MainActor in
                        state.modelLoadProgress = progress
                        UserDefaults.standard.set(progress, forKey: "modelDownloadProgress")
                    }
                }
            )
            state.modelReady = true
            traceApp("preloadModel: model loaded successfully")
            UserDefaults.standard.set("", forKey: "modelDownloadingName")
            UserDefaults.standard.set(0, forKey: "modelDownloadProgress")
        } catch {
            traceApp("preloadModel: FAILED: \(error)")
            modelLoading = false
            UserDefaults.standard.set("", forKey: "modelDownloadingName")
            UserDefaults.standard.set(0, forKey: "modelDownloadProgress")
        }
    }

    private func reloadModel(_ modelName: String) async {
        let state = appState
        let transcription = transcriptionService
        let streaming = streamingService
        state.modelReady = false
        modelLoading = true
        state.modelLoadProgress = 0
        UserDefaults.standard.set(modelName, forKey: "modelDownloadingName")
        UserDefaults.standard.set(0, forKey: "modelDownloadProgress")
        await transcription.unloadModel()
        await streaming.unloadModel()
        do {
            try await transcription.setupModel(
                modelName: modelName,
                onDownloadProgress: { progress in
                    Task { @MainActor in
                        state.modelLoadProgress = progress
                        UserDefaults.standard.set(progress, forKey: "modelDownloadProgress")
                    }
                }
            )
            try await streaming.setupModel(
                modelName: modelName,
                onDownloadProgress: { progress in
                    Task { @MainActor in
                        state.modelLoadProgress = progress
                        UserDefaults.standard.set(progress, forKey: "modelDownloadProgress")
                    }
                }
            )
            state.modelReady = true
            UserDefaults.standard.set("", forKey: "modelDownloadingName")
            UserDefaults.standard.set(0, forKey: "modelDownloadProgress")
        } catch {
            modelLoading = false
            UserDefaults.standard.set("", forKey: "modelDownloadingName")
            UserDefaults.standard.set(0, forKey: "modelDownloadProgress")
        }
    }

    private func checkMicPermission() {
        let state = appState
        let micManager = micPermissionManager
        Task {
            let permission = await micManager.checkPermission()
            state.micPermission = permission
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

        // Capture reference types only — do NOT capture `self` (the struct).
        // SwiftUI recreates the App struct on each body evaluation, so a captured
        // `self` would hold stale `@State` storage and cause use-after-free crashes.
        let state = appState
        let micManager = micPermissionManager
        let notifications = notificationService

        Task {
            do {
                try await hotkeyService.register(
                    combo: combo,
                    onKeyDown: {
                        Task { @MainActor in
                            traceApp("Hotkey down fired, state=\(String(describing: state.recordingState))")
                            let started = state.handleHotkeyDown()
                            if started {
                                if state.micPermission == .undetermined {
                                    let perm = await micManager.requestPermission()
                                    state.micPermission = perm
                                }
                                guard state.micPermission == .granted else {
                                    traceApp("Hotkey: mic permission not granted, cancelling")
                                    state.cancel()
                                    notifications.showNotification(
                                        title: "Susurrus",
                                        body: "Microphone access required. Enable in System Settings > Privacy > Microphone."
                                    )
                                    return
                                }
                            }
                        }
                    },
                    onKeyUp: {
                        Task { @MainActor in
                            state.handleHotkeyUp()
                        }
                    }
                )
                state.hotkeyConfigured = true
                traceApp("Hotkey registered successfully")
            } catch {
                traceApp("Hotkey registration failed: \(error)")
            }
        }
    }

    private func setupLLMHotkeyIfNeeded() {
        guard !appState.llmHotkeyConfigured else { return }

        let combo = HotkeyCombo.withLLM

        // Capture reference types only — same reason as setupHotkeyIfNeeded.
        let state = appState
        let micManager = micPermissionManager

        Task {
            do {
                try await llmHotkeyService.register(
                    combo: combo,
                    onKeyDown: {
                        Task { @MainActor in
                            state.forceLLM = true
                            let started = state.handleHotkeyDown()
                            if started {
                                if state.micPermission == .undetermined {
                                    let perm = await micManager.requestPermission()
                                    state.micPermission = perm
                                }
                                guard state.micPermission == .granted else {
                                    state.forceLLM = false
                                    state.cancel()
                                    return
                                }
                            }
                        }
                    },
                    onKeyUp: {
                        Task { @MainActor in
                            state.handleHotkeyUp()
                        }
                    }
                )
                state.llmHotkeyConfigured = true
            } catch {
                // LLM hotkey registration failed
            }
        }
    }

    // MARK: - State change handling

    private func handleStateChange(_ newState: RecordingState) {
        traceApp("handleStateChange: \(String(describing: newState))")
        updatePulseAnimation(newState)

        switch newState {
        case .streaming:
            break // handled by onStreamingStart callback
        case .finalizing:
            break // handled by onStreamingStop callback
        case .idle:
            stopDurationTimer()
        case .recording, .processing:
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
        // Check mic permission synchronously. If not determined, request it.
        // If denied, show notification and cancel.
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        traceApp("startStreamingSession: micStatus=\(micStatus.rawValue), cached=\(String(describing: appState.micPermission))")

        switch micStatus {
        case .authorized:
            appState.micPermission = .granted
        case .notDetermined:
            traceApp("startStreamingSession: requesting mic permission")
            // Request permission asynchronously, then retry
            let state = appState
            let micManager = micPermissionManager
            let notifications = notificationService
            Task { @MainActor in
                let perm = await micManager.requestPermission()
                state.micPermission = perm
                if perm == .granted {
                    traceApp("startStreamingSession: permission granted, restarting session")
                    state.cancel() // reset to idle
                    state.startStreaming() // re-enter streaming
                } else {
                    traceApp("startStreamingSession: permission denied after request")
                    state.cancel()
                    notifications.showNotification(
                        title: "Susurrus",
                        body: "Microphone access required. Enable in System Settings > Privacy > Microphone."
                    )
                }
            }
            return
        case .denied, .restricted:
            traceApp("startStreamingSession: mic permission denied, cancelling")
            appState.cancel()
            notificationService.showNotification(
                title: "Susurrus",
                body: "Microphone access required. Enable in System Settings > Privacy > Microphone."
            )
            return
        @unknown default:
            traceApp("startStreamingSession: unknown mic status, cancelling")
            appState.cancel()
            return
        }

        traceApp("startStreamingSession: starting streaming session")
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

        // Capture reference types only for the streaming Task
        let state = appState
        let streaming = streamingService
        let notifications = notificationService
        let overlay = overlayWindow

        // Start streaming
        Task {
            do {
                traceApp("startStreamingSession: calling startStreamTranscription")
                try await streaming.startStreamTranscription { transcript in
                    Task { @MainActor in
                        state.interimText = transcript
                        overlay?.show(confirmed: transcript.confirmed, unconfirmed: transcript.unconfirmed)
                    }
                }
            } catch {
                traceApp("startStreamingSession: streaming failed: \(error.localizedDescription)")
                Task { @MainActor in
                    state.cancel()
                    notifications.showNotification(
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

        // Capture reference types only
        let state = appState
        let streaming = streamingService
        let notifications = notificationService
        let clip = clipboard
        let prefs = preferences
        let llm = llmService
        let history = historyManager

        Task {
            do {
                let text = try await streaming.stopStreamTranscription()

                if !text.isEmpty {
                    var finalText = text

                    if shouldLLM {
                        do {
                            let prompt = prefs.llmSystemPrompt()
                            finalText = try await llm.process(text: text, systemPrompt: prompt)
                        } catch {
                            // LLM failed — use raw transcription
                        }
                    }

                    if appendMode {
                        clip.appendText(finalText)
                    } else {
                        clip.writeText(finalText)
                    }

                    let autoPaste = prefs.autoPasteEnabled()
                    Logger(subsystem: "com.susurrus.app", category: "Flow").info("autoPaste=\(autoPaste)")
                    if autoPaste {
                        try? await Task.sleep(for: .milliseconds(150))
                        let pasted = clip.simulatePaste()
                        if !pasted {
                            notifications.showNotification(
                                title: "Susurrus",
                                body: "Auto-paste requires Accessibility access. Enable in System Settings > Privacy & Security > Accessibility."
                            )
                        }
                    }

                    history.add(finalText)
                } else {
                    notifications.showNotification(
                        title: "Susurrus",
                        body: "No speech detected"
                    )
                }
            } catch TranscriptionError.noSpeechDetected {
                notifications.showNotification(
                    title: "Susurrus",
                    body: "No speech detected"
                )
            } catch {
                // Transcription failed — clipboard untouched
            }

            // Consume the duration cap flag after notification (Behaviour 2.6)
            if state.wasDurationCapped {
                state.consumeDurationCapped()
            }

            state.finishStreaming()
        }
    }

    // MARK: - Duration cap

    private func startDurationTimer() {
        durationTimer?.invalidate()
        let state = appState
        let notifications = notificationService
        durationTimer = Timer.scheduledTimer(
            withTimeInterval: AppState.maxRecordingDuration,
            repeats: false
        ) { _ in
            Task { @MainActor in
                if state.enforceDurationCap() {
                    notifications.showNotification(
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
