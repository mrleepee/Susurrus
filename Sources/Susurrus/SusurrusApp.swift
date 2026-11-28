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
    /// Process-wide, not `@State`: `init()` and the menu's `onAppear` both
    /// call `startModelLoadingIfNeeded()`, and `@State` written from `init`
    /// doesn't persist — that guard let every launch load the models twice.
    @MainActor private static var modelLoadStarted = false
    /// Bumped per model-picker change; only the newest reload may touch app
    /// state, and each waits for the previous one so they never interleave.
    @MainActor private static var reloadGeneration = 0
    @MainActor private static var windowCloseObserved = false
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
    // Renders through our own overlay window rather than Notification Center,
    // which has repeatedly delivered this app's messages with no readable
    // content — see OverlayMessageService for the diagnosis.
    private var notificationService: OverlayMessageService { OverlayMessageService.shared }
    private static let sharedPreferences = UserDefaultsPreferencesManager()
    private var preferences: UserDefaultsPreferencesManager { Self.sharedPreferences }
    private var vocabularyManager: VocabularyManager { VocabularyManager.shared }
    private static let sharedHotkeyService = GlobalHotkeyService()
    private var hotkeyService: GlobalHotkeyService { Self.sharedHotkeyService }
    private static let sharedLLMHotkeyService = GlobalHotkeyService()
    private var llmHotkeyService: GlobalHotkeyService { Self.sharedLLMHotkeyService }
    private static let sharedFixHotkeyService = GlobalHotkeyService()
    private var fixHotkeyService: GlobalHotkeyService { Self.sharedFixHotkeyService }
    // Registered dynamically only while actually recording (see
    // startStreamingSession) — a permanent global Esc hotkey would swallow
    // Esc everywhere else in the OS.
    private static let sharedEscHotkeyService = GlobalHotkeyService()
    private var escHotkeyService: GlobalHotkeyService { Self.sharedEscHotkeyService }
    // ⌘⏎ / ⌥⌘⏎ / ⇧⌘⏎ finish-from-listening keys for the review panel — like
    // Esc, registered only while the panel is listening.
    private static let sharedPanelInsertHotkeyService = GlobalHotkeyService()
    private var panelInsertHotkeyService: GlobalHotkeyService { Self.sharedPanelInsertHotkeyService }
    private static let sharedPanelCopyHotkeyService = GlobalHotkeyService()
    private var panelCopyHotkeyService: GlobalHotkeyService { Self.sharedPanelCopyHotkeyService }
    private static let sharedPanelGoHotkeyService = GlobalHotkeyService()
    private var panelGoHotkeyService: GlobalHotkeyService { Self.sharedPanelGoHotkeyService }
    private static let sharedHotkeyStorage = HotkeyStorage()
    private var hotkeyStorage: HotkeyStorage { Self.sharedHotkeyStorage }
    private static let sharedMicPermissionManager = MicPermissionManager()
    private var micPermissionManager: MicPermissionManager { Self.sharedMicPermissionManager }
    private static let sharedLLMService = LLMService()
    private var llmService: LLMService { Self.sharedLLMService }
    private var historyManager: TranscriptionHistoryManager { TranscriptionHistoryManager.shared }
    private var correctionManager: CorrectionLearningManager { CorrectionLearningManager.shared }
    // Value types — cheap and stateless, safe to live per-copy.
    private let promptComposer = PromptComposer()
    private let transcriptCorrector = TranscriptCorrector()
    private let transcriptFinalizer = TranscriptFinalizer()
    private static let sharedMediaService = MediaService()
    private var mediaService: MediaService { Self.sharedMediaService }
    private static let sharedAudioDeviceService = AudioDeviceService()
    private var audioDeviceService: AudioDeviceService { Self.sharedAudioDeviceService }

    // Recording duration timer
    @State private var durationTimer: Timer?

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
    /// The last discarded dictation, for "Restore Discarded Dictation".
    private static let sharedDiscarded = DiscardedDictationStore()
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

        // One-time repair of learning data written before the promotion
        // and activation guards existed (lowercase common-word vocab junk,
        // common-phrase rules activated off a single sighting).
        let migration = correctionManager.runLearningQualityMigration()
        if !migration.removedTerms.isEmpty || !migration.addedTerms.isEmpty || !migration.disabledRules.isEmpty {
            traceApp("learning migration: removed vocab \(migration.removedTerms); added vocab \(migration.addedTerms); disabled rules \(migration.disabledRules)")
        }

        // Give terms already in the store a createdAt, so the ranker's grace
        // tier reaches them too and not just terms learned from here on.
        let backfilled = vocabularyManager.runCreatedAtBackfill()
        if backfilled > 0 {
            traceApp("vocab migration: backfilled createdAt on \(backfilled) entries")
        }

        // Tell the user when an edit changes future behaviour — a rule
        // activating or a term joining the vocabulary. Quiet on first
        // sightings; only speaks when something will actually rewrite
        // future transcriptions.
        let notifications = notificationService
        correctionManager.onLearn = { outcome in
            traceApp("learning: activated=\(outcome.activatedRules.map { "\($0.match)→\($0.replacement)" }) promoted=\(outcome.promotedTerms)")
            if let rule = outcome.activatedRules.first {
                // No "manage in Preferences" tail: this is a two-second glance
                // at the corner of the screen, not a menu.
                notifications.showNotification(
                    title: "Correction learned",
                    body: "'\(rule.match)' → '\(rule.replacement)'"
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
            MenuBarView(appState: appState) {
                startModelLoadingIfNeeded()
                checkMicPermission()
                setupHotkeyIfNeeded()
                setupLLMHotkeyIfNeeded()
                setupFixHotkeyIfNeeded()
                observeWindowClose()
                appState.recordingMode = preferences.recordingMode()
                appState.onStreamingStart = { self.startStreamingSession() }
                appState.onStreamingStop = { self.stopStreamingSession() }
                appState.onCancelRequested = { self.cancelActiveDictation() }
                let state = appState
                let deps = panelDeps
                let streaming = streamingService
                Self.sharedDiscarded.onAvailabilityChange = { state.canRestoreDiscarded = $0 }
                appState.onRestoreDiscarded = {
                    Self.restoreDiscarded(deps: deps, streaming: streaming, state: state)
                }
            }
        }
        .onChange(of: appState.recordingState) { _, newState in
            handleStateChange(newState)
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
            // Reloads run one at a time: each waits for the previous, and
            // a superseded one skips itself, so two loads never interleave
            // on the streaming actor and an older one can't clear the
            // "reloading" flag or mark the model ready under a newer one.
            Self.reloadGeneration += 1
            let generation = Self.reloadGeneration
            let previous = currentModelReloadTask
            modelReloading = true
            UserDefaults.standard.set(true, forKey: "modelReloading")
            let task = Task { @MainActor in
                await previous?.value
                guard generation == Self.reloadGeneration else { return }
                traceApp("model switch: reloading '\(newModel)'")
                await reloadModel(newModel, generation: generation)
                guard generation == Self.reloadGeneration else { return }
                traceApp("model switch: '\(newModel)' done")
                modelReloading = false
                UserDefaults.standard.set(false, forKey: "modelReloading")
            }
            currentModelReloadTask = task
        }

        Window("History", id: "history") {
            HistoryView()
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
        // Called from the menu's onAppear, which fires on every menu open.
        guard !Self.windowCloseObserved else { return }
        Self.windowCloseObserved = true
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: nil,
            queue: .main
        ) { notification in
            // Only react to our titled windows closing, not menu bar popovers
            guard let window = notification.object as? NSWindow,
                  (window.title == "Susurrus Preferences" || window.title == "History") else {
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
        guard !Self.modelLoadStarted else { return }
        Self.modelLoadStarted = true
        // A quit mid-reload leaves these persisted values set, which would
        // grey out the model picker (and show a stale "Downloading...") on
        // every later launch.
        UserDefaults.standard.set(false, forKey: "modelReloading")
        UserDefaults.standard.set("", forKey: "modelDownloadingName")
        UserDefaults.standard.set(0, forKey: "modelDownloadProgress")
        traceApp("startModelLoadingIfNeeded: starting model load")
        Task {
            await preloadModel()
        }
        // The system word list is ~236k entries and takes ~210ms to read. It is
        // needed when bias terms are composed at the start of a dictation, so
        // load it now, off any path the user is waiting on.
        Task.detached(priority: .utility) {
            let started = Date()
            let available = EnglishDictionary.shared.isAvailable
            traceApp("englishDictionary: loaded=\(available) in \(Int(Date().timeIntervalSince(started) * 1000))ms")
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
            // Cleared so the next menu open retries the load.
            Self.modelLoadStarted = false
            UserDefaults.standard.set("", forKey: "modelDownloadingName")
            UserDefaults.standard.set(0, forKey: "modelDownloadProgress")
            notificationService.showNotification(
                title: "Couldn't load the speech model",
                body: "\(error.localizedDescription) Open the menu to retry, or pick another model in Preferences > Model."
            )
        }
    }

    /// `generation` is the model-picker change this reload serves; a reload
    /// superseded while it was loading leaves app state to the newer one.
    private func reloadModel(_ modelName: String, generation: Int) async {
        let state = appState
        let streaming = streamingService
        state.modelReady = false
        Self.modelLoadStarted = true
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
            guard generation == Self.reloadGeneration else { return }
            state.modelReady = true
            startKeepWarmTimer()
            UserDefaults.standard.set("", forKey: "modelDownloadingName")
            UserDefaults.standard.set(0, forKey: "modelDownloadProgress")
        } catch {
            traceApp("reloadModel: FAILED for '\(modelName)': \(error)")
            guard generation == Self.reloadGeneration else { return }
            UserDefaults.standard.set("", forKey: "modelDownloadingName")
            UserDefaults.standard.set(0, forKey: "modelDownloadProgress")
            notificationService.showNotification(
                title: "Couldn't load \(modelName)",
                body: "\(error.localizedDescription) Pick another model in Preferences > Model."
            )
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
                                        body: "Enable Susurrus in System Settings → Privacy & Security → Microphone."
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
                            // Only once a session actually started: set
                            // before, a press while the model is loading
                            // left the flag on for the next dictation.
                            let started = state.handleHotkeyDown()
                            if started {
                                state.forceLLM = true
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

    /// Control+Option+Space: dictate into a review panel. The transcript
    /// streams into the panel; finishing with the main hotkey (or releasing,
    /// in push-to-talk) opens it for editing; there ⌘⏎ copies and ⌥⌘⏎
    /// inserts the corrected text into the app you were in with one clean
    /// paste. While it's listening, the same keys (see
    /// registerPanelFinishKeys) or a second Control+Option+Space finish
    /// straight to copy / insert and close the panel. Nothing is written to the target app until you
    /// insert, so no editor's accessibility quirks can block it.
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
                            // Second press while the panel is listening:
                            // finish, copy, close — no editor.
                            if state.recordingState == .streaming,
                               state.dictationDestination == .reviewPanel {
                                traceApp("Review-panel hotkey: quick copy")
                                panel.quickFinish = .copy
                                state.stopStreaming()
                                return
                            }
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
                        body: "Enable Susurrus in System Settings → Privacy & Security → Microphone."
                    )
                }
            }
            return
        case .denied, .restricted:
            traceApp("startStreamingSession: mic permission denied, cancelling")
            appState.cancel()
            notificationService.showNotification(
                title: "Microphone access needed",
                body: "Enable Susurrus in System Settings → Privacy & Security → Microphone."
            )
            return
        @unknown default:
            traceApp("startStreamingSession: unknown mic status, cancelling")
            appState.cancel()
            return
        }

        traceApp("startStreamingSession: starting streaming session")
        startDurationTimer()

        // Esc cancels the in-flight session — registered only for the
        // duration of this recording (unregistered in cancelActiveDictation
        // and at stopStreamingSession's convergence point), so it never
        // intercepts Esc anywhere else in the system.
        let escState = appState
        let esc = escHotkeyService
        Task {
            do {
                try await esc.register(
                    combo: HotkeyCombo(keyCode: 0x35, modifiers: 0),
                    onKeyDown: {
                        Task { @MainActor in
                            escState.requestCancel()
                        }
                    }
                )
            } catch {
                traceApp("Esc-cancel hotkey registration failed: \(error)")
            }
        }

        // Pause any playing media (Spotify, Apple Music, etc.)
        let media = mediaService
        Task {
            let paused = await media.pausePlayingApps()
            if !paused.isEmpty {
                traceApp("startStreamingSession: paused media: \(paused.joined(separator: ", "))")
                pausedMediaApps = paused
            }
        }

        // Shared with the message path — see StreamingOverlayWindow.shared.
        if overlayWindow == nil {
            overlayWindow = StreamingOverlayWindow.shared
        }

        // Sync vocabulary bias: relevance-ranked at stop time against the
        // streaming preview, so the prompt-token budget goes to terms this
        // session plausibly contains. Context terms come from recent
        // dictation history — the "what am I talking about lately" bias
        // needs no setup or habit.
        let vocabMgr = vocabularyManager
        let historyMgr = historyManager
        Task {
            await streamingService.setVocabularySelector { preview in
                let contextTerms = historyMgr.recentBiasTerms()
                return VocabularyRanker().selectTerms(
                    previewText: preview,
                    vocabulary: vocabMgr.entries(),
                    contextTerms: contextTerms
                )
            }
        }

        // Record from the Studio Display mic when connected, otherwise the
        // built-in mic — never Bluetooth or whatever else macOS has selected
        // (see AudioDeviceService.dictationInput) — unless Settings says to
        // use the Mac's default input. Re-picked if the hardware changes
        // mid-session.
        let devices = audioDeviceService
        let useSystemDefault = UserDefaults.standard.bool(forKey: AudioDeviceService.useSystemDefaultInputKey)
        var resolvedDeviceID: UInt32?
        if let input = devices.dictationInput(useSystemDefault: useSystemDefault) {
            traceApp("startStreamingSession: routing to '\(input.name)' (id \(input.id)\(useSystemDefault ? ", Mac default input" : ""))")
            resolvedDeviceID = input.id
        } else if !useSystemDefault {
            traceApp("startStreamingSession: no Studio Display or built-in mic — using system default")
            notificationService.showNotification(
                title: "Microphone not found",
                body: "Neither the Studio Display nor the built-in microphone is available. Using the system default input."
            )
        }
        let reselectDevice: @Sendable () -> UInt32? = {
            devices.dictationInput(useSystemDefault: useSystemDefault)?.id
        }

        // Capture reference types only for the streaming Task
        let state = appState
        let streaming = streamingService
        let notifications = notificationService
        let panel = reviewPanel

        // Review-panel mode streams into the editable panel instead of the
        // overlay; open it now. It takes keyboard focus so its shortcuts work
        // over apps that capture the keyboard (WorkSpaces).
        let toPanel = appState.dictationDestination == .reviewPanel
        let overlay = toPanel ? nil : overlayWindow
        if toPanel {
            registerPanelFinishKeys()
            // The footer buttons do what their shortcuts do.
            panel.onFinishRecording = { finish in
                guard state.recordingState == .streaming,
                      state.dictationDestination == .reviewPanel else { return }
                traceApp("Review panel: footer \(finish.map { "\($0)" } ?? "review")")
                panel.quickFinish = finish
                state.stopStreaming()
            }
            panel.onCancelRecording = {
                traceApp("Review panel: footer cancel")
                state.requestCancel()
            }
            panel.beginRecording(
                targetApp: panel.targetApp,
                isPushToTalk: appState.recordingMode == .pushToTalk,
                editCombo: hotkeyStorage.loadCombo()
            )
            // Warn in the panel if the mic is delivering pure silence — a
            // stuck coreaudiod otherwise just looks like a blank panel.
            let micSession = panel.sessionID
            Task { @MainActor in
                while panel.sessionID == micSession, state.recordingState == .streaming {
                    try? await Task.sleep(for: .seconds(1))
                    guard panel.sessionID == micSession, state.recordingState == .streaming else { break }
                    if let peak = await streaming.recentPeak(seconds: MicSilence.window) {
                        panel.showMicSilent(MicSilence.isDead(peak: peak))
                    }
                }
            }
            // An earlier dictation was discarded: offer it back. Restoring
            // puts its text ahead of this one and keeps listening, so the
            // user can carry on from where they were cut off.
            let discarded = Self.sharedDiscarded
            panel.restoreOffer = discarded.snippet
            let finalizer = transcriptFinalizer
            let vocab = vocabularyManager
            let corrections = correctionManager
            panel.onRestoreLast = {
                guard state.recordingState == .streaming,
                      state.dictationDestination == .reviewPanel,
                      let item = discarded.take() else { return }
                let session = panel.sessionID
                switch item.content {
                case .text(let edited, _, let raw):
                    traceApp("Review panel: restored \(edited.count) chars of edited text, still listening")
                    let prefix = RestoredPrefix(text: edited, raw: raw)
                    panel.showRestored(edited)
                    panel.restoredPrefix = Task { prefix }
                case .audio(let samples, let preview, let before):
                    traceApp("Review panel: restoring \(String(format: "%.1f", Double(samples.count) / 16_000))s of discarded audio, still listening")
                    // The preview shows at once; the final decode replaces it.
                    panel.showRestored(RestoredPrefix.join(before?.text, preview))
                    panel.restoredPrefix = Task { @MainActor in
                        let prefix = await Self.decodeDiscarded(
                            samples: samples, preview: preview, before: before,
                            streaming: streaming, finalizer: finalizer, vocab: vocab, corrections: corrections
                        )
                        if panel.sessionID == session { panel.showRestored(prefix.text) }
                        return prefix
                    }
                }
            }
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
                try await streaming.startStreamTranscription(
                    deviceID: resolvedDeviceID,
                    reselectDevice: reselectDevice
                ) { transcript in
                    // Strip Whisper's special tokens / silence markers first
                    // (<|startoftranscript|>, [ Silence ], …) so neither the
                    // corrector fuzzy-matches them nor the preview shows them.
                    // Then correct the confirmed (stable) portion live so the
                    // preview shows the same fixes the final text gets; the
                    // unconfirmed tail stays raw of correction — a half-spoken
                    // word shouldn't be fuzzy-matched — but is still cleaned.
                    // Preview only — never record fires from here. This runs at
                    // ~10 Hz on partial text; crediting it would swamp the real
                    // per-dictation counts recorded in stopStreamingSession.
                    let preview = StreamingTranscriptionService.preview(
                        confirmed: transcript.confirmed,
                        unconfirmed: transcript.unconfirmed
                    ) { corrector.correct($0, vocabulary: sessionVocab, rules: sessionRules).text }
                    Task { @MainActor in
                        if toPanel {
                            panel.updateStreaming(preview.text)
                        } else {
                            // The only overlay writer: an onChange(of:
                            // interimText) path used to repaint it with the
                            // raw, uncorrected transcript right after this.
                            overlay?.show(confirmed: preview.confirmed, unconfirmed: preview.tail)
                        }
                    }
                }
            } catch {
                traceApp("startStreamingSession: streaming failed: \(error.localizedDescription)")
                Task { @MainActor in
                    // Only a session that is still recording failed here;
                    // once it has moved on to finalizing or idle, the stop
                    // or cancel path owns cleanup.
                    guard state.recordingState == .streaming else { return }
                    // Route through the Esc-cancel path so the session is
                    // torn down completely: the global Esc and panel finish
                    // keys unregistered (they would otherwise keep
                    // swallowing those keys in every app), the review panel
                    // closed, paused media resumed, the timer stopped.
                    state.requestCancel()
                    notifications.showNotification(
                        title: "Recording failed",
                        body: "\(error.localizedDescription) Try again — if it keeps happening, check the input device in Preferences > Audio."
                    )
                }
            }
        }
    }

    // MARK: - Review panel delivery

    /// What the review panel needs to turn a transcript into delivered text.
    /// A struct of references so static helpers can run inside Tasks without
    /// capturing the `SusurrusApp` struct.
    private struct PanelDeps {
        let panel: DictationReviewPanel
        let clip: PasteboardClipboardService
        let history: TranscriptionHistoryManager
        let vocab: VocabularyManager
        let corrections: CorrectionLearningManager
        let finalizer: TranscriptFinalizer
        let discarded: DiscardedDictationStore
    }

    private var panelDeps: PanelDeps {
        PanelDeps(
            panel: reviewPanel, clip: clipboard, history: historyManager,
            vocab: vocabularyManager, corrections: correctionManager,
            finalizer: transcriptFinalizer, discarded: Self.sharedDiscarded
        )
    }

    /// Deterministic corrections over the raw ASR, then the editor — or, for
    /// a quick finish, straight to copy / insert.
    private static func finishInPanel(
        rawText text: String,
        prefix: RestoredPrefix? = nil,
        retained: StreamingTranscriptionService.RetainedSession?,
        quickFinish: DictationReviewPanel.QuickFinish?,
        deps: PanelDeps
    ) async {
        let vocab = deps.vocab
        let corrections = deps.corrections
        let history = deps.history
        // Deterministic corrections only; the user edits the rest
        // by hand in the panel. Even empty text opens the editor
        // (so the panel never gets stuck in the recording phase).
        let panelOutcome = await deps.finalizer.finalize(
            text,
            vocabulary: vocab.entries(),
            rules: corrections.activeRules()
        )
        // Restored text comes first, as it was (already corrected or edited
        // by hand); only the newly spoken part goes through the corrector.
        let corrected = RestoredPrefix.join(prefix?.text, panelOutcome.corrected)
        let rawASR = RestoredPrefix.join(prefix?.raw, text)
        if !panelOutcome.changes.isEmpty {
            let summary = panelOutcome.changes
                .map { "\($0.original)→\($0.corrected)" }
                .joined(separator: ", ")
            traceApp("stopStreamingSession: corrector applied \(panelOutcome.changes.count) fixes (panel): \(summary)")
        }
        // Credit whatever actually fired, once per dictation. The
        // preview pass is never counted — see TranscriptCorrector.
        corrections.recordFires(ruleIDs: panelOutcome.changes.compactMap(\.firedRuleID))
        vocab.recordFixes(ids: panelOutcome.changes.compactMap(\.firedVocabularyID))
        // Whisper Title-Cases noun phrases it reads as names. The
        // user's own approved transcripts are the only corpus that
        // knows "documents" is normally lowercase but "Datavid"
        // isn't, so the profile is built from history rather than
        // any fixed word list.
        let casing = CasingProfile
            .build(from: history.items().map(\.text))
            .suggestions(for: corrected, vocabulary: vocab.entries())
        if !casing.isEmpty {
            traceApp("stopStreamingSession: casing suggestions: \(casing.map { "\($0.original)→\($0.suggested)" }.joined(separator: ", "))")
        }
        await MainActor.run {
            presentInPanel(
                initialText: corrected, corrected: corrected, rawASR: rawASR,
                casing: casing,
                // An accuracy capture pairs audio with its text; with restored
                // text in front the two no longer match, so skip it.
                retained: prefix == nil ? retained : nil,
                quickFinish: quickFinish, deps: deps
            )
        }
    }

    /// Open the editor on `initialText` (or quick-finish it). `corrected` and
    /// `rawASR` are what a manual edit is learned against.
    @MainActor
    private static func presentInPanel(
        initialText: String,
        corrected: String,
        rawASR: String,
        casing: [CasingSuggestion],
        retained: StreamingTranscriptionService.RetainedSession?,
        quickFinish: DictationReviewPanel.QuickFinish?,
        deps: PanelDeps
    ) {
        let panel = deps.panel
        let clip = deps.clip
        let history = deps.history
        let vocab = deps.vocab
        let corrections = deps.corrections
        let discarded = deps.discarded
        let targetApp = panel.targetApp
        let deliver: (String, DictationReviewPanel.QuickFinish) -> Void = { edited, mode in
            panel.releaseFocus()
            let final = edited.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !final.isEmpty else {
                panel.cancel()
                return
            }
            // Learn from any manual edit beyond the corrector.
            // Copy and Insert are equally good teaching signal.
            if final != corrected, !corrected.isEmpty {
                corrections.recordCorrection(raw: corrected, edited: final)
            }
            vocab.recordUsage(in: final)
            history.add(final, rawText: rawASR)
            clip.writeText(final)
            if let retained {
                let capture = EvalCaptureStore.Capture(
                    samples: retained.samples, approved: final, raw: rawASR,
                    corrected: corrected, promptTerms: retained.promptTerms,
                    model: retained.model
                )
                Task.detached(priority: .utility) {
                    do {
                        if let entry = try EvalCaptureStore().save(capture) {
                            traceApp("evalCapture: kept \(entry.id) (\(entry.seconds ?? 0)s)")
                        }
                    } catch {
                        traceApp("evalCapture: save failed: \(error)")
                    }
                }
            }
            guard mode != .copy else {
                traceApp("reviewCopy: copied \(final.count) chars, target untouched")
                panel.showFinished(final, message: "Copied to Clipboard")
                return
            }
            // Return focus to the target app, then one clean
            // paste — the only thing we ever do to it. If its
            // focused element is clearly not somewhere to type
            // (a file list, a sidebar), skip the ⌘V: the text
            // is already on the clipboard, so say so instead.
            targetApp?.activate(options: [])
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(150))
                let target = targetApp?.bundleIdentifier ?? "?"
                let verdict = targetApp.map { FocusedTextProbe.check(pid: $0.processIdentifier) } ?? .unknown
                guard verdict != .notEditable else {
                    traceApp("reviewInsert: no text field focused in \(target), copied only")
                    panel.showFinished(final, message: "Copied to Clipboard", detail: "No text field to insert into")
                    return
                }
                // Go: Return straight after the paste, to send it.
                let go = mode == .go
                let pasted = clip.simulatePaste(into: targetApp?.bundleIdentifier, pressReturn: go)
                traceApp("reviewInsert: pasted=\(pasted)\(go ? " + Return" : "") into \(target) (field: \(verdict))")
                if pasted {
                    panel.showFinished(final, message: go ? "Sent" : "Inserted")
                } else {
                    panel.showFinished(final, message: "Copied to Clipboard", detail: "Couldn't paste — press ⌘V to insert")
                }
            }
        }
        if let quickFinish {
            let final = corrected.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !final.isEmpty else {
                traceApp("reviewQuickFinish: nothing heard, closing")
                panel.cancel()
                return
            }
            deliver(corrected, quickFinish)
        } else {
            // Esc in the editor keeps the text for "Restore Discarded Dictation".
            panel.onDiscardEdits = { edited in
                if discarded.keep(.text(edited: edited, corrected: corrected, raw: rawASR), targetApp: targetApp) {
                    traceApp("reviewDiscard: kept \(edited.count) chars for restore")
                }
            }
            panel.enterEditing(finalText: initialText, casingSuggestions: casing, onFinish: deliver)
        }
    }

    /// Final-decode discarded audio while a new dictation is listening, for
    /// use as restored text. Falls back to the preview it showed if the
    /// decode fails or hears nothing.
    @MainActor
    private static func decodeDiscarded(
        samples: [Float],
        preview: String,
        before: RestoredPrefix?,
        streaming: StreamingTranscriptionService,
        finalizer: TranscriptFinalizer,
        vocab: VocabularyManager,
        corrections: CorrectionLearningManager
    ) async -> RestoredPrefix {
        var raw = preview
        if samples.count >= DiscardedDictationStore.minAudioSamples {
            do {
                let transcript = try await streaming.transcribeOffline(samples: samples, previewText: preview)
                if !transcript.text.isEmpty { raw = transcript.text }
            } catch {
                traceApp("restore: decode of discarded audio failed, using its preview: \(error)")
            }
        }
        let corrected = await finalizer.finalize(raw, vocabulary: vocab.entries(), rules: corrections.activeRules()).corrected
        return RestoredPrefix(
            text: RestoredPrefix.join(before?.text, corrected),
            raw: RestoredPrefix.join(before?.raw, raw)
        )
    }

    /// "Restore Discarded Dictation": reopen the last discarded dictation in
    /// the editor — decoding its audio first if it was discarded while still
    /// listening. One-shot: the kept copy is gone once restored.
    @MainActor
    private static func restoreDiscarded(deps: PanelDeps, streaming: StreamingTranscriptionService, state: AppState) {
        guard state.recordingState == .idle, let item = deps.discarded.take() else { return }
        restore(item, deps: deps, streaming: streaming, state: state)
    }

    /// Reopen `item` (already taken from the store) in the editor.
    @MainActor
    private static func restore(
        _ item: DiscardedDictationStore.Item,
        deps: PanelDeps,
        streaming: StreamingTranscriptionService,
        state: AppState
    ) {
        let panel = deps.panel
        switch item.content {
        case .text(let edited, let corrected, let raw):
            traceApp("restoreDiscarded: reopening edited text (\(edited.count) chars)")
            panel.beginRestoring(targetApp: item.targetApp)
            presentInPanel(
                initialText: edited, corrected: corrected, rawASR: raw,
                casing: [], retained: nil, quickFinish: nil, deps: deps
            )
        case .audio(let samples, let preview, let before):
            traceApp("restoreDiscarded: decoding \(String(format: "%.1f", Double(samples.count) / 16_000))s of discarded audio")
            panel.beginRestoring(targetApp: item.targetApp)
            Task { @MainActor in
                do {
                    let transcript = try await streaming.transcribeOffline(samples: samples, previewText: preview)
                    // A new dictation took the panel while this decoded: put
                    // the discard back rather than open the editor over it.
                    guard state.recordingState == .idle else {
                        deps.discarded.keep(item.content, targetApp: item.targetApp)
                        return
                    }
                    let text = transcript.text.isEmpty ? preview : transcript.text
                    await finishInPanel(rawText: text, prefix: before, retained: nil, quickFinish: nil, deps: deps)
                } catch {
                    traceApp("restoreDiscarded: decode failed: \(error)")
                    deps.discarded.keep(item.content, targetApp: item.targetApp)
                    panel.cancel()
                    OverlayMessageService.shared.showNotification(
                        title: "Couldn't restore the dictation",
                        body: "\(error.localizedDescription) It's still kept — try again from the menu bar."
                    )
                }
            }
        }
    }

    /// ⌘⏎ copies, ⌥⌘⏎ inserts and ⇧⌘⏎ inserts then presses Return (Go)
    /// straight from the listening panel, skipping
    /// the editor — the same keys the editor uses, so they mean the same
    /// thing in both phases. Global only while the panel is listening (torn
    /// down with Esc), so they never shadow those keys in other apps.
    private func registerPanelFinishKeys() {
        let state = appState
        let panel = reviewPanel
        let keys: [(GlobalHotkeyService, HotkeyCombo, DictationReviewPanel.QuickFinish)] = [
            // Carbon modifiers: cmdKey 0x0100, shiftKey 0x0200, optionKey 0x0800;
            // 0x24 is Return.
            (panelCopyHotkeyService, HotkeyCombo(keyCode: 0x24, modifiers: 0x0100), .copy),
            (panelInsertHotkeyService, HotkeyCombo(keyCode: 0x24, modifiers: 0x0900), .insert),
            (panelGoHotkeyService, HotkeyCombo(keyCode: 0x24, modifiers: 0x0300), .go),
        ]
        for (service, combo, finish) in keys {
            Task {
                do {
                    try await service.register(
                        combo: combo,
                        onKeyDown: {
                            Task { @MainActor in
                                guard state.recordingState == .streaming,
                                      state.dictationDestination == .reviewPanel else { return }
                                traceApp("Review panel: quick finish \(finish)")
                                panel.quickFinish = finish
                                state.stopStreaming()
                            }
                        }
                    )
                } catch {
                    traceApp("Panel finish hotkey registration failed: \(error)")
                }
            }
        }
    }

    /// Discards the in-flight streaming session with no output: no history
    /// entry, no notification, no paste — the target app is never touched.
    /// Bound to Esc, which is only registered while actively recording (see
    /// startStreamingSession), so this is unreachable once a session has
    /// already finished or wasn't running.
    private func cancelActiveDictation() {
        traceApp("cancelActiveDictation: Esc pressed, discarding session")

        // Capture reference types only — do NOT capture `self` (the struct).
        let state = appState
        let streaming = streamingService
        let media = mediaService
        let esc = escHotkeyService
        let panelInsert = panelInsertHotkeyService
        let panelCopy = panelCopyHotkeyService
        let panelGo = panelGoHotkeyService
        let apps = pausedMediaApps
        pausedMediaApps = []
        // Keep what was said so an accidental Esc can be undone from the menu
        // bar ("Restore Discarded Dictation"). Memory only, never history.
        let discarded = Self.sharedDiscarded
        let toPanel = state.dictationDestination == .reviewPanel
        let preview = toPanel ? reviewPanel.livePreviewText : ""
        let restored = toPanel ? reviewPanel.restoredPrefix : nil
        let target = toPanel ? reviewPanel.targetApp : NSWorkspace.shared.frontmostApplication

        stopDurationTimer()
        state.dictationDestination = .clipboard
        overlayWindow?.hide()
        reviewPanel.cancel()
        state.cancel()

        Task {
            let samples = await streaming.sessionAudio()
            let before = await restored?.value
            if discarded.keep(.audio(samples: samples, preview: preview, before: before), targetApp: target) {
                traceApp("cancelActiveDictation: kept \(String(format: "%.1f", Double(samples.count) / 16_000))s for restore")
            }
            await streaming.cancelStreamTranscription()
            await esc.unregister()
            await panelInsert.unregister()
            await panelCopy.unregister()
            await panelGo.unregister()
            if !apps.isEmpty {
                traceApp("cancelActiveDictation: resuming media: \(apps.joined(separator: ", "))")
                await media.resumeApps(apps)
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
        let quickFinish = toPanel ? reviewPanel.quickFinish : nil
        reviewPanel.quickFinish = nil
        let restoredPrefix = toPanel ? reviewPanel.restoredPrefix : nil
        reviewPanel.restoredPrefix = nil

        // Keep the overlay up in a dimmed "Finalizing…" state through the
        // whole-buffer decode (1–8s) — it hides once the text is delivered.
        // Panel mode never showed the overlay; the panel shows its own
        // processing state instead.
        if toPanel {
            reviewPanel.beginProcessing()
        } else {
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
        let finalizer = transcriptFinalizer
        let vocab = vocabularyManager
        let corrections = correctionManager
        let composer = promptComposer
        let overlay = overlayWindow
        let panel = reviewPanel
        let panelInsert = panelInsertHotkeyService
        let panelCopy = panelCopyHotkeyService
        let panelGo = panelGoHotkeyService
        let panelDeps = self.panelDeps
        // Opt-in accuracy-testing capture (tier C): panel dictations only.
        // Quick finishes count too, now that nearly every dictation ends in
        // one: every capture is saved unverified, so text the user never
        // looked at stays out of the headline numbers until reviewed.
        let keepRecording = toPanel && UserDefaults.standard.bool(forKey: EvalCaptureStore.enabledKey)

        Task {
            // Restored text survives a failed stop: on 11-20 a Restore
            // followed by Insert with nothing new said threw "no speech",
            // the panel closed, and the restored dictation was gone for good.
            let keepRestoredText: @Sendable () async -> Bool = {
                guard toPanel, let prefix = await restoredPrefix?.value else { return false }
                traceApp("stopStreamingSession: new audio failed, keeping the restored text")
                await Self.finishInPanel(rawText: "", prefix: prefix, retained: nil, quickFinish: quickFinish, deps: panelDeps)
                return true
            }
            do {
                // Mic off first, without waiting on the streaming actor: a
                // busy preview pass held the actor for 9–45 s twice, and
                // everything said in that time was recorded too.
                streaming.stopCaptureNow()
                // Listening is over: hand ⌘⏎ / ⌥⌘⏎ back before the editor
                // opens, so its own Insert/Copy shortcuts aren't swallowed.
                await panelInsert.unregister()
                await panelCopy.unregister()
                await panelGo.unregister()
                let stopStart = Date()
                traceApp("stopStreamingSession: calling stopStreamTranscription")
                await streaming.setRetainSessionAudio(keepRecording)
                traceApp("stopStreamingSession: retain set after \(Int(Date().timeIntervalSince(stopStart) * 1000))ms")
                let text = try await streaming.stopStreamTranscription()
                traceApp("stopStreamingSession: got text in \(Int(Date().timeIntervalSince(stopStart) * 1000))ms (\(text.count) chars): \(text.prefix(100))")

                if toPanel {
                    let retained = await streaming.takeRetainedSession()
                    let prefix = await restoredPrefix?.value
                    await Self.finishInPanel(rawText: text, prefix: prefix, retained: retained, quickFinish: quickFinish, deps: panelDeps)
                } else if !text.isEmpty {
                    // Layer 1 (deterministic corrections — learned rules,
                    // fuzzy vocabulary, casing; always on, ~0ms), then the
                    // optional guarded LLM pass. TranscriptFinalizer is the
                    // same code the eval harness scores.
                    let correctStart = Date()
                    var llmStage: TranscriptFinalizer.LLMStage?
                    if shouldLLM {
                        traceApp("stopStreamingSession: starting LLM processing")
                        let base = prefs.llmSystemPrompt()
                        llmStage = TranscriptFinalizer.LLMStage(processor: llm) { corrected in
                            composer.compose(
                                base: base,
                                vocabularyContext: vocab.llmContextString(relevantTo: corrected),
                                correctionExamples: corrections.fewShotString(for: corrected, limit: 5)
                            )
                        }
                    }
                    let outcome = await finalizer.finalize(
                        text,
                        vocabulary: vocab.entries(),
                        rules: corrections.activeRules(),
                        llm: llmStage
                    )
                    if !outcome.changes.isEmpty {
                        let summary = outcome.changes
                            .map { "\($0.original)→\($0.corrected)" }
                            .joined(separator: ", ")
                        traceApp("stopStreamingSession: corrector applied \(outcome.changes.count) fixes in \(Int(Date().timeIntervalSince(correctStart) * 1000))ms: \(summary)")
                    }
                    // Credit fires from the first corrector pass only — see
                    // TranscriptFinalizer.Result.changes.
                    corrections.recordFires(ruleIDs: outcome.changes.compactMap(\.firedRuleID))
                    vocab.recordFixes(ids: outcome.changes.compactMap(\.firedVocabularyID))
                    let finalText = outcome.text

                    switch outcome.llm {
                    case .skipped:
                        break
                    case .accepted:
                        traceApp("stopStreamingSession: LLM done, finalText=\(finalText.prefix(50))")
                    case .rejected(let llmText):
                        traceApp("stopStreamingSession: LLM output rejected by guardrail (drifted from input), keeping corrected text. LLM said: \(llmText.prefix(80))")
                        notifications.showNotification(
                            title: "LLM cleanup skipped",
                            body: "The model rewrote the text instead of just cleaning it up, so the corrected transcription was used instead."
                        )
                    case .failed(let reason):
                        traceApp("stopStreamingSession: LLM cleanup failed: \(reason)")
                        notifications.showNotification(
                            title: "LLM cleanup failed",
                            body: "\(reason) Using the raw transcription instead."
                        )
                    }

                    // Usage stats drive the prompt-token ranking next session.
                    vocab.recordUsage(in: finalText)

                    traceApp("stopStreamingSession: writing to clipboard")
                    if appendMode {
                        clip.appendText(finalText)
                    } else {
                        clip.writeText(finalText)
                    }

                    let autoPaste = prefs.autoPasteEnabled()
                    traceApp("stopStreamingSession: autoPaste=\(autoPaste)")
                    if autoPaste {
                        try? await Task.sleep(for: .milliseconds(150))
                        // Same guard as the panel's Insert: a ⌘V into a
                        // file list or sidebar does nothing useful (or
                        // worse), and the text is already on the clipboard.
                        let front = NSWorkspace.shared.frontmostApplication
                        let verdict = front.map { FocusedTextProbe.check(pid: $0.processIdentifier) } ?? .unknown
                        if verdict == .notEditable {
                            traceApp("stopStreamingSession: no text field focused in \(front?.bundleIdentifier ?? "?"), copied only")
                            overlay?.showMessage("Copied to clipboard — no text field to insert into", duration: 2.2)
                        } else if !clip.simulatePaste(into: front?.bundleIdentifier) {
                            notifications.showNotification(
                                title: "Auto-paste blocked — text is on the clipboard",
                                body: "Grant System Settings → Privacy & Security → Accessibility. If Susurrus is already listed, remove and re-add it."
                            )
                        }
                    }

                    traceApp("stopStreamingSession: saving to history")
                    history.add(finalText, rawText: text)
                    traceApp("stopStreamingSession: done")
                } else {
                    // Not a system notification: this machine has been
                    // observed dropping UNUserNotificationCenter banner
                    // bodies for this app, so this goes through the overlay
                    // instead, which is guaranteed to actually render.
                    overlay?.showMessage("No speech detected — check the input device in Preferences.")
                }
            } catch let error as TranscriptionError where error.isRecordingInterrupted {
                traceApp("stopStreamingSession: \(error.localizedDescription)")
                if await keepRestoredText() {
                    // The panel shows the restored text; the message below
                    // still says the new part was lost.
                } else if toPanel {
                    await MainActor.run { panel.cancel() }
                }
                // Overlay, not a notification: see the no-speech case below.
                overlay?.showMessage("\(error.localizedDescription) Please dictate it again.")
            } catch TranscriptionError.noSpeechDetected {
                traceApp("stopStreamingSession: no speech detected")
                // Panel mode: nothing to edit — just close, no nagging banner.
                if await keepRestoredText() {
                    // Nothing new was said; the restored text is in the panel.
                } else if toPanel {
                    await MainActor.run { panel.cancel() }
                } else {
                    // Not a system notification: this machine has been
                    // observed dropping UNUserNotificationCenter banner
                    // bodies for this app, so this goes through the overlay
                    // instead, which is guaranteed to actually render.
                    overlay?.showMessage("No speech detected — check the input device in Preferences.")
                }
            } catch {
                traceApp("stopStreamingSession: transcription failed: \(error.localizedDescription)")
                if await keepRestoredText() {
                    // Restored text kept; the notification covers the rest.
                } else if toPanel {
                    await MainActor.run { panel.cancel() }
                }
                notifications.showNotification(
                    title: "Transcription failed",
                    body: "\(error.localizedDescription) The recording was discarded — try again."
                )
            }

            // All paths land here (success, no-speech, errors) — drop the
            // finalizing overlay now that the outcome is known. (Panel mode
            // never showed it; hide() is a no-op there.)
            await MainActor.run { overlay?.hide() }
            // Esc is only meaningful while state == .streaming (see
            // AppState.requestCancel); tear it down now that this session
            // has reached a terminal state via the normal stop path. The
            // cancel path unregisters it itself and never reaches here.
            await escHotkeyService.unregister()

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
                        body: "Recordings stop after \(Int(AppState.maxRecordingDuration / 60)) minutes. The text so far is being transcribed."
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
