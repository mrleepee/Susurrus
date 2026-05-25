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
    @Environment(\.openWindow) private var openWindow

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
    private let correctionManager = CorrectionLearningManager(vocabularyManager: VocabularyManager())
    private let notebookManager = NotebookManager()
    private let promptComposer = PromptComposer()
    private let mediaService = MediaService()
    private let audioDeviceService = AudioDeviceService()

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

    /// Media apps that were paused when recording started.
    @State private var pausedMediaApps: [String] = []

    init() {
        NSApplication.shared.setActivationPolicy(.accessory)

        if !AXIsProcessTrusted() {
            PasteboardClipboardService.promptAccessibility()
        }

        // Start model loading immediately — don't wait for menu bar click
        startModelLoadingIfNeeded()
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
            MenuBarView(appState: appState, notebookManager: notebookManager) {
                startModelLoadingIfNeeded()
                checkMicPermission()
                setupHotkeyIfNeeded()
                setupLLMHotkeyIfNeeded()
                observeWindowClose()
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

        Window("Notebooks", id: "notebooks") {
            NotebooksWindowView()
        }
    }

    // MARK: - Window management

    /// Opens a SwiftUI Window scene by temporarily switching to .regular
    /// activation policy so the window can become key and visible.
    private func openWindowWithActivation(id: String) {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.setActivationPolicy(.regular)
        openWindow(id: id)
    }

    /// Observes window close notifications to revert to .accessory policy
    /// when no visible windows remain (keeps menu bar icon clean).
    private func observeWindowClose() {
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: nil,
            queue: .main
        ) { notification in
            // Only react to our titled windows closing, not menu bar popovers
            guard let window = notification.object as? NSWindow,
                  (window.title == "Susurrus Preferences" || window.title == "History" || window.title == "Notebooks") else {
                return
            }
            Task { @MainActor in
                // Delay slightly to let the window actually close
                try? await Task.sleep(for: .milliseconds(100))
                let visibleWindows = NSApp.windows.filter { w in
                    w.isVisible && (w.title == "Susurrus Preferences" || w.title == "History")
                }
                if visibleWindows.isEmpty {
                    NSApp.setActivationPolicy(.accessory)
                }
            }
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

        // Pause any playing media (Spotify, Apple Music, etc.)
        let media = mediaService
        Task {
            let paused = await media.pausePlayingApps()
            if !paused.isEmpty {
                traceApp("startStreamingSession: paused media: \(paused.joined(separator: ", "))")
                pausedMediaApps = paused
            }
        }

        // Lazily create the overlay window
        if overlayWindow == nil {
            overlayWindow = StreamingOverlayWindow()
        }

        // Sync vocabulary bias
        let vocab = vocabularyManager.promptString()
        Task {
            await streamingService.setVocabularyPrompt(vocab)
        }

        // Resolve preferred device name to a current Core Audio device ID.
        // If the user has no preference, or the saved device is disconnected,
        // `resolvedDeviceID` is nil and streaming uses the system default.
        let preferredName = preferences.selectedInputDeviceName()
        let resolution = audioDeviceService.resolve(preferredName: preferredName)
        let resolvedDeviceID: UInt32?
        switch resolution {
        case .specific(let id, let name):
            traceApp("startStreamingSession: routing to device '\(name)' (id \(id))")
            resolvedDeviceID = id
        case .systemDefault:
            resolvedDeviceID = nil
        case .unavailable(let requestedName):
            traceApp("startStreamingSession: preferred device '\(requestedName)' unavailable — falling back to system default")
            notificationService.showNotification(
                title: "Susurrus",
                body: "Preferred microphone '\(requestedName)' is not connected. Using system default."
            )
            resolvedDeviceID = nil
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
                try await streaming.startStreamTranscription(deviceID: resolvedDeviceID) { transcript in
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
                        title: "Susurrus Error",
                        body: "Streaming failed: \(error.localizedDescription)"
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
        let nbManager = notebookManager

        Task {
            do {
                traceApp("stopStreamingSession: calling stopStreamTranscription")
                let text = try await streaming.stopStreamTranscription()
                traceApp("stopStreamingSession: got text (\(text.count) chars): \(text.prefix(100))")

                if !text.isEmpty {
                    var finalText = text

                    if shouldLLM {
                        traceApp("stopStreamingSession: starting LLM processing")
                        do {
                            let prompt = promptComposer.compose(
                                base: prefs.llmSystemPrompt(),
                                vocabularyContext: vocabularyManager.llmContextString(),
                                correctionExamples: correctionManager.fewShotString(for: text, limit: 5),
                                notebookContext: notebookManager.activeNotebookContext()
                            )
                            finalText = try await llm.process(text: text, systemPrompt: prompt)
                            traceApp("stopStreamingSession: LLM done, finalText=\(finalText.prefix(50))")
                        } catch {
                            traceApp("stopStreamingSession: LLM cleanup failed: \(error.localizedDescription)")
                        }
                    }

                    traceApp("stopStreamingSession: writing to clipboard")
                    let outputMode = UserDefaults.standard.string(forKey: "outputMode") ?? "clipboard"

                    if outputMode == "notebook" {
                        // Notebook mode: append to notebook, open notebooks window for editing
                        traceApp("stopStreamingSession: notebook mode — appending to notebook")
                        nbManager.appendToActiveNotebook(text: finalText)
                        history.add(finalText, rawText: text)
                        traceApp("stopStreamingSession: opening notebooks window")
                        NSApp.setActivationPolicy(.regular)
                        NSApp.activate(ignoringOtherApps: true)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            openWindow(id: "notebooks")
                        }
                    } else {
                        // Clipboard mode: write to clipboard, auto-paste, also append to notebook
                        if appendMode {
                            clip.appendText(finalText)
                        } else {
                            clip.writeText(finalText)
                        }

                        let autoPaste = prefs.autoPasteEnabled()
                        traceApp("stopStreamingSession: autoPaste=\(autoPaste)")
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

                        traceApp("stopStreamingSession: saving to history")
                        history.add(finalText, rawText: text)
                        traceApp("stopStreamingSession: appending to notebook")
                        nbManager.appendToActiveNotebook(text: finalText)
                    }
                    traceApp("stopStreamingSession: done")
                } else {
                    notifications.showNotification(
                        title: "Susurrus",
                        body: "No speech detected"
                    )
                }
            } catch TranscriptionError.noSpeechDetected {
                traceApp("stopStreamingSession: no speech detected")
                notifications.showNotification(
                    title: "Susurrus",
                    body: "No speech detected"
                )
            } catch {
                traceApp("stopStreamingSession: transcription failed: \(error.localizedDescription)")
                notifications.showNotification(
                    title: "Susurrus Error",
                    body: error.localizedDescription
                )
            }

            // Consume the duration cap flag after notification (Behaviour 2.6)
            if state.wasDurationCapped {
                state.consumeDurationCapped()
            }

            state.finishStreaming()

            // Resume media that was paused when recording started
            if !pausedMediaApps.isEmpty {
                let apps = pausedMediaApps
                pausedMediaApps = []
                traceApp("stopStreamingSession: resuming media: \(apps.joined(separator: ", "))")
                await mediaService.resumeApps(apps)
            }
        }
    }

    // MARK: - Duration cap

    private func startDurationTimer() {
        durationTimer?.invalidate()
        durationTimer = nil
        guard AppState.maxRecordingDuration > 0 else { return }
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
