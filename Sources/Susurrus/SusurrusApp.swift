import SwiftUI
import SusurrusKit
import AVFoundation
import os.log

private let log = Logger(subsystem: "com.susurrus.app", category: "App")

/// NSLog wrapper — always visible in Console.app and `log show`, unlike os.Logger info.
func traceApp(_ message: String) {
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

    // Services — process-stable singletons, NOT per-copy stored properties.
    // SwiftUI recreates the App struct freely (observed 19 re-inits/sec
    // during window churn); a `let` service here is deallocated on every
    // re-init. Carbon keeps an *unretained* pointer to its registered
    // GlobalHotkeyService, so a per-copy instance is a use-after-free that
    // killed the fix hotkey after one use; StreamingTranscriptionService
    // holds the loaded model. Forwarding vars keep call sites unchanged.
    private static let sharedStreamingService = StreamingTranscriptionService()
    private var streamingService: StreamingTranscriptionService { Self.sharedStreamingService }
    private static let sharedClipboard = PasteboardClipboardService()
    private var clipboard: PasteboardClipboardService { Self.sharedClipboard }
    private var notificationService: UserNotificationService { UserNotificationService.shared }
    private static let sharedPreferences = UserDefaultsPreferencesManager()
    private var preferences: UserDefaultsPreferencesManager { Self.sharedPreferences }
    private var vocabularyManager: VocabularyManager { VocabularyManager.shared }
    private static let sharedHotkeyService = GlobalHotkeyService()
    private var hotkeyService: GlobalHotkeyService { Self.sharedHotkeyService }
    private static let sharedLLMHotkeyService = GlobalHotkeyService()
    private var llmHotkeyService: GlobalHotkeyService { Self.sharedLLMHotkeyService }
    private static let sharedFixHotkeyService = GlobalHotkeyService()
    private var fixHotkeyService: GlobalHotkeyService { Self.sharedFixHotkeyService }
    private static let sharedHotkeyStorage = HotkeyStorage()
    private var hotkeyStorage: HotkeyStorage { Self.sharedHotkeyStorage }
    private static let sharedMicPermissionManager = MicPermissionManager()
    private var micPermissionManager: MicPermissionManager { Self.sharedMicPermissionManager }
    private static let sharedLLMService = LLMService()
    private var llmService: LLMService { Self.sharedLLMService }
    private var historyManager: TranscriptionHistoryManager { TranscriptionHistoryManager.shared }
    private var correctionManager: CorrectionLearningManager { CorrectionLearningManager.shared }
    private var notebookManager: NotebookManager { NotebookManager.shared }
    // Value types — cheap and stateless, safe to live per-copy.
    private let promptComposer = PromptComposer()
    private let transcriptCorrector = TranscriptCorrector()
    private static let sharedMediaService = MediaService()
    private var mediaService: MediaService { Self.sharedMediaService }
    private static let sharedAudioDeviceService = AudioDeviceService()
    private var audioDeviceService: AudioDeviceService { Self.sharedAudioDeviceService }

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

    // Review panel for "dictate into the panel" mode (Control+Option+Space).
    // Process-stable like the other services so it survives App-struct
    // re-inits (see the services block above).
    private static let sharedReviewPanel = DictationReviewPanel()
    private var reviewPanel: DictationReviewPanel { Self.sharedReviewPanel }

    /// Media apps that were paused when recording started.
    @State private var pausedMediaApps: [String] = []

    /// Periodically reruns a silent inference so the model's ANE context stays
    /// resident and the first recording after an idle spell doesn't pay the
    /// cold-start cost.
    @State private var keepWarmTimer: Timer?

    init() {
        NSApplication.shared.setActivationPolicy(.accessory)

        if !AXIsProcessTrusted() {
            PasteboardClipboardService.promptAccessibility()
        }

        // Edits anywhere feed the learning loop (rules + vocab promotion).
        historyManager.correctionManager = correctionManager
        notebookManager.correctionLearning = correctionManager

        // One-time repair of learning data written before the promotion
        // and activation guards existed (lowercase common-word vocab junk,
        // common-phrase rules activated off a single sighting).
        let migration = correctionManager.runLearningQualityMigration()
        if !migration.removedTerms.isEmpty || !migration.disabledRules.isEmpty {
            traceApp("learning migration: removed vocab \(migration.removedTerms); disabled rules \(migration.disabledRules)")
        }

        // Tell the user when an edit changes future behaviour — a rule
        // activating or a term joining the vocabulary. Quiet on first
        // sightings; only speaks when something will actually rewrite
        // future transcriptions.
        let notifications = notificationService
        correctionManager.onLearn = { outcome in
            traceApp("learning: activated=\(outcome.activatedRules.map { "\($0.match)→\($0.replacement)" }) promoted=\(outcome.promotedTerms)")
            if let rule = outcome.activatedRules.first {
                notifications.showNotification(
                    title: "Correction learned",
                    body: "Susurrus will now write '\(rule.replacement)' when it hears '\(rule.match)'. Manage in Preferences → Corrections."
                )
            } else if !outcome.promotedTerms.isEmpty {
                let terms = outcome.promotedTerms.map { "'\($0)'" }.joined(separator: ", ")
                notifications.showNotification(
                    title: "Vocabulary updated",
                    body: "\(terms) added from your edit."
                )
            }
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
                setupFixHotkeyIfNeeded()
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
        let streaming = streamingService
        do {
            // Only the streaming service needs the model. Loading it into the
            // batch WhisperKitTranscriptionService too doubled memory and ANE
            // pressure (two full CoreML model instances) for a service the app
            // flow never calls.
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
            startKeepWarmTimer()
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
        let streaming = streamingService
        state.modelReady = false
        modelLoading = true
        state.modelLoadProgress = 0
        UserDefaults.standard.set(modelName, forKey: "modelDownloadingName")
        UserDefaults.standard.set(0, forKey: "modelDownloadProgress")
        await streaming.unloadModel()
        do {
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
            startKeepWarmTimer()
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
                                        title: "Microphone access needed",
                                        body: "Enable Susurrus in System Settings > Privacy & Security > Microphone."
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

    /// Control+Option+Space: dictate into a review panel. Hold to record —
    /// the transcript streams into an editable panel; release to edit it;
    /// ⌘⏎ inserts the corrected text into the app you were in with one clean
    /// paste. Nothing is written to the target app until you insert, so no
    /// editor's accessibility quirks can block it.
    private func setupFixHotkeyIfNeeded() {
        guard !appState.fixHotkeyConfigured else { return }

        // Capture reference/value locals only — never struct self.
        let state = appState
        let micManager = micPermissionManager
        let panel = reviewPanel

        Task {
            do {
                try await fixHotkeyService.register(
                    combo: .reviewPanel,
                    onKeyDown: {
                        Task { @MainActor in
                            guard state.recordingState == .idle else { return }
                            // Capture the paste target before the panel opens.
                            panel.targetApp = NSWorkspace.shared.frontmostApplication
                            state.dictationDestination = .reviewPanel
                            let started = state.handleHotkeyDown()
                            if started {
                                if state.micPermission == .undetermined {
                                    let perm = await micManager.requestPermission()
                                    state.micPermission = perm
                                }
                                guard state.micPermission == .granted else {
                                    state.dictationDestination = .clipboard
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
                state.fixHotkeyConfigured = true
                traceApp("Review-panel hotkey registered (Control+Option+Space)")
            } catch {
                traceApp("Review-panel hotkey registration failed: \(error)")
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
                        title: "Microphone access needed",
                        body: "Enable Susurrus in System Settings > Privacy & Security > Microphone."
                    )
                }
            }
            return
        case .denied, .restricted:
            traceApp("startStreamingSession: mic permission denied, cancelling")
            appState.cancel()
            notificationService.showNotification(
                title: "Microphone access needed",
                body: "Enable Susurrus in System Settings > Privacy & Security > Microphone."
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

        // Sync vocabulary bias: relevance-ranked at stop time against the
        // streaming preview, so the prompt-token budget goes to terms this
        // session plausibly contains. Context terms come from the active
        // notebook, falling back to recent dictation history so the "what
        // am I talking about lately" bias needs no notebook habit.
        let vocabMgr = vocabularyManager
        let nbMgr = notebookManager
        let historyMgr = historyManager
        Task {
            await streamingService.setVocabularySelector { preview in
                var contextTerms = nbMgr.activeNotebookBiasTerms()
                if contextTerms.isEmpty {
                    contextTerms = historyMgr.recentBiasTerms()
                }
                return VocabularyRanker().selectTerms(
                    previewText: preview,
                    vocabulary: vocabMgr.entries(),
                    notebookTerms: contextTerms
                )
            }
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
                title: "Preferred microphone not connected",
                body: "'\(requestedName)' is unavailable. Using the system default input."
            )
            resolvedDeviceID = nil
        }

        // Capture reference types only for the streaming Task
        let state = appState
        let streaming = streamingService
        let notifications = notificationService
        let panel = reviewPanel

        // Review-panel mode streams into the editable panel instead of the
        // overlay; open it now (non-key, so it doesn't steal focus while the
        // user is still holding the hotkey).
        let toPanel = appState.dictationDestination == .reviewPanel
        let overlay = toPanel ? nil : overlayWindow
        if toPanel {
            panel.beginRecording(targetApp: panel.targetApp)
        }

        // Snapshot vocab and rules once per session so the interim callback
        // (fires ~10Hz) doesn't re-read and re-decode UserDefaults each time.
        let corrector = transcriptCorrector
        let sessionVocab = vocabularyManager.entries()
        let sessionRules = correctionManager.activeRules()

        // Start streaming
        Task {
            do {
                traceApp("startStreamingSession: calling startStreamTranscription (panel=\(toPanel))")
                try await streaming.startStreamTranscription(deviceID: resolvedDeviceID) { transcript in
                    // Strip Whisper's special tokens / silence markers first
                    // (<|startoftranscript|>, [ Silence ], …) so neither the
                    // corrector fuzzy-matches them nor the preview shows them.
                    // Then correct the confirmed (stable) portion live so the
                    // preview shows the same fixes the final text gets; the
                    // unconfirmed tail stays raw of correction — a half-spoken
                    // word shouldn't be fuzzy-matched — but is still cleaned.
                    let cleanConfirmed = StreamingTranscriptionService.stripNoiseTokens(from: transcript.confirmed)
                    let cleanTail = StreamingTranscriptionService.stripNoiseTokens(from: transcript.unconfirmed)
                    let confirmed = cleanConfirmed.isEmpty
                        ? ""
                        : corrector.correct(cleanConfirmed, vocabulary: sessionVocab, rules: sessionRules).text
                    Task { @MainActor in
                        if toPanel {
                            let tail = cleanTail.isEmpty ? "" : (confirmed.isEmpty ? cleanTail : " \(cleanTail)")
                            panel.updateStreaming(confirmed + tail)
                        } else {
                            state.interimText = transcript
                            overlay?.show(confirmed: confirmed, unconfirmed: cleanTail)
                        }
                    }
                }
            } catch {
                traceApp("startStreamingSession: streaming failed: \(error.localizedDescription)")
                Task { @MainActor in
                    state.cancel()
                    notifications.showNotification(
                        title: "Recording failed",
                        body: error.localizedDescription
                    )
                }
            }
        }
    }

    private func stopStreamingSession() {
        stopDurationTimer()

        // Review-panel mode finalizes into the editable panel, not the app;
        // reset the destination immediately so the next session defaults to
        // clipboard even if this one throws.
        let toPanel = appState.dictationDestination == .reviewPanel
        appState.dictationDestination = .clipboard

        // Keep the overlay up in a dimmed "Finalizing…" state through the
        // whole-buffer decode (1–8s) — it hides once the text is delivered.
        // Panel mode never showed the overlay, so leave it alone.
        if !toPanel {
            overlayWindow?.beginFinalizing()
        }

        let appendMode = preferences.appendToClipboard()
        // Panel mode skips the LLM — the user reviews and edits by hand.
        let shouldLLM = !toPanel && (appState.forceLLM || preferences.llmEnabled())
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
        let corrector = transcriptCorrector
        let vocab = vocabularyManager
        let corrections = correctionManager
        let composer = promptComposer
        let overlay = overlayWindow
        let panel = reviewPanel

        Task {
            do {
                let stopStart = Date()
                traceApp("stopStreamingSession: calling stopStreamTranscription")
                let text = try await streaming.stopStreamTranscription()
                traceApp("stopStreamingSession: got text in \(Int(Date().timeIntervalSince(stopStart) * 1000))ms (\(text.count) chars): \(text.prefix(100))")

                if toPanel {
                    // Deterministic corrections only; the user edits the rest
                    // by hand in the panel. Even empty text opens the editor
                    // (so the panel never gets stuck in the recording phase).
                    let corrected = text.isEmpty
                        ? ""
                        : corrector.correct(text, vocabulary: vocab.entries(), rules: corrections.activeRules()).text
                    let rawASR = text
                    let notebookMode = (UserDefaults.standard.string(forKey: "outputMode") ?? "clipboard") == "notebook"
                    await MainActor.run {
                        let targetApp = panel.targetApp
                        panel.enterEditing(finalText: corrected) { edited in
                            let final = edited.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !final.isEmpty else { return }
                            // Learn from any manual edit beyond the corrector.
                            if final != corrected, !corrected.isEmpty {
                                corrections.recordCorrection(raw: corrected, edited: final)
                            }
                            vocab.recordUsage(in: final)
                            history.add(final, rawText: rawASR)
                            if notebookMode {
                                nbManager.appendToActiveNotebook(text: final)
                            }
                            clip.writeText(final)
                            // Return focus to the target app, then one clean
                            // paste — the only thing we ever do to it.
                            targetApp?.activate(options: [])
                            Task {
                                try? await Task.sleep(for: .milliseconds(150))
                                let pasted = clip.simulatePaste()
                                if !pasted {
                                    notifications.showNotification(
                                        title: "Text copied — paste to insert",
                                        body: "Couldn't paste automatically. The corrected text is on the clipboard; press ⌘V where you want it."
                                    )
                                }
                                traceApp("reviewInsert: pasted=\(pasted) into \(targetApp?.bundleIdentifier ?? "?")")
                            }
                        }
                    }
                } else if !text.isEmpty {
                    // Layer 1: deterministic corrections — learned rules,
                    // fuzzy vocabulary matches, casing. Always on, ~0ms.
                    let correctStart = Date()
                    let outcome = corrector.correct(
                        text,
                        vocabulary: vocab.entries(),
                        rules: corrections.activeRules()
                    )
                    if !outcome.changes.isEmpty {
                        let summary = outcome.changes
                            .map { "\($0.original)→\($0.corrected)" }
                            .joined(separator: ", ")
                        traceApp("stopStreamingSession: corrector applied \(outcome.changes.count) fixes in \(Int(Date().timeIntervalSince(correctStart) * 1000))ms: \(summary)")
                    }
                    var finalText = outcome.text

                    if shouldLLM {
                        traceApp("stopStreamingSession: starting LLM processing")
                        do {
                            let prompt = composer.compose(
                                base: prefs.llmSystemPrompt(),
                                vocabularyContext: vocab.llmContextString(relevantTo: finalText),
                                correctionExamples: corrections.fewShotString(for: finalText, limit: 5),
                                notebookContext: nbManager.activeNotebookContext()
                            )
                            let llmText = try await llm.process(text: finalText, systemPrompt: prompt)
                            if TranscriptGuardrail.accepts(input: finalText, output: llmText) {
                                // Re-run the deterministic pass on the LLM
                                // output so vocabulary casing/spelling
                                // survives any LLM meddling.
                                finalText = corrector.correct(
                                    llmText,
                                    vocabulary: vocab.entries(),
                                    rules: corrections.activeRules()
                                ).text
                                traceApp("stopStreamingSession: LLM done, finalText=\(finalText.prefix(50))")
                            } else {
                                traceApp("stopStreamingSession: LLM output rejected by guardrail (drifted from input), keeping corrected text. LLM said: \(llmText.prefix(80))")
                                notifications.showNotification(
                                    title: "LLM cleanup skipped",
                                    body: "The model rewrote the text instead of just cleaning it up, so the corrected transcription was used instead."
                                )
                            }
                        } catch {
                            traceApp("stopStreamingSession: LLM cleanup failed: \(error.localizedDescription)")
                            notifications.showNotification(
                                title: "LLM cleanup failed",
                                body: "\(error.localizedDescription) Using the raw transcription instead."
                            )
                        }
                    }

                    // Usage stats drive the prompt-token ranking next session.
                    vocab.recordUsage(in: finalText)

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
                                    title: "Auto-paste blocked — text is on the clipboard",
                                    body: "Grant Accessibility access: System Settings > Privacy & Security > Accessibility. If Susurrus is already listed, remove it (−) and re-add it — the grant resets when the app's signature changes."
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
                        title: "No speech detected",
                        body: "Nothing was transcribed. Check the input device in Preferences."
                    )
                }
            } catch TranscriptionError.noSpeechDetected {
                traceApp("stopStreamingSession: no speech detected")
                // Panel mode: nothing to edit — just close, no nagging banner.
                if toPanel {
                    await MainActor.run { panel.cancel() }
                } else {
                    notifications.showNotification(
                        title: "No speech detected",
                        body: "Nothing was transcribed. Check the input device in Preferences."
                    )
                }
            } catch {
                traceApp("stopStreamingSession: transcription failed: \(error.localizedDescription)")
                if toPanel {
                    await MainActor.run { panel.cancel() }
                }
                notifications.showNotification(
                    title: "Transcription failed",
                    body: error.localizedDescription
                )
            }

            // All paths land here (success, no-speech, errors) — drop the
            // finalizing overlay now that the outcome is known. (Panel mode
            // never showed it; hide() is a no-op there.)
            await MainActor.run { overlay?.hide() }

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

    // MARK: - Keep-warm

    /// Reruns a small inference every 60s while idle so the model's ANE
    /// context stays resident. Skips while recording/finalizing so it never
    /// competes with a live decode. Guarded so model reloads don't stack a
    /// second timer (the streaming service instance is shared, so one timer
    /// serves every model).
    private func startKeepWarmTimer() {
        guard keepWarmTimer == nil else { return }
        let state = appState
        let streaming = streamingService
        keepWarmTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            Task { @MainActor in
                guard state.recordingState == .idle else { return }
                await streaming.keepWarm()
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
                        title: "Recording stopped",
                        body: "Maximum recording duration reached."
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
