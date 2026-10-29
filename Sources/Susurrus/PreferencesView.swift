import SwiftUI
import SusurrusKit
import UniformTypeIdentifiers

private let keychain = KeychainService()

struct PreferencesView: View {
    @AppStorage("recordingMode") private var recordingMode = "push-to-talk"
    @AppStorage("appendToClipboard") private var appendToClipboard = false
    @AppStorage("selectedModel") private var selectedModel = TranscriptionModelCatalog.defaultModel
    @AppStorage("llmEnabled") private var llmEnabled = false
    @AppStorage("autoPasteEnabled") private var autoPasteEnabled = true
    @AppStorage("pauseMediaOnRecord") private var pauseMediaOnRecord = true
    @State private var axTrusted = false
    @AppStorage("llmModel") private var llmModel: String = "MiniMax-M2.5"
    @AppStorage("llmEndpoint") private var llmEndpoint: String = "https://api.minimax.io/anthropic/v1/messages"
    @AppStorage("llmSystemPrompt") private var llmSystemPrompt = UserDefaultsPreferencesManager.defaultLLMPrompt
    @AppStorage("llmProvider") private var llmProvider = LLMProvider.cloud.rawValue
    @AppStorage("llmLocalEndpoint") private var llmLocalEndpoint = LLMService.defaultLocalEndpoint
    @AppStorage("llmLocalModel") private var llmLocalModel = ""
    @AppStorage(StreamingTranscriptionService.confidenceLoggingKey) private var confidenceLogging = false
    @AppStorage(EvalCaptureStore.enabledKey) private var keepRecordings = false
    @State private var recordingsCount = 0
    @State private var recordingsSummary = ""
    @State private var confirmDeleteRecordings = false
    @State private var localTestResult: String?
    @State private var localTestRunning = false
    @State private var entries: [VocabularyEntry] = []
    @State private var newTerm: String = ""
    @State private var newCategory: VocabularyCategory = .custom
    @State private var showApiKey: Bool = false
    @State private var apiKeyText: String = ""

    // Download state bridged from SusurrusApp via UserDefaults
    @AppStorage("modelDownloadProgress") private var modelDownloadProgress: Double = 0
    @AppStorage("modelDownloadingName") private var modelDownloadingName: String = ""

    @State private var cachedModels: Set<String> = []
    @State private var escapeMonitor: Any?
    /// True while a model reload is in flight — greys out the model picker.
    @State private var modelReloading = false
    @State private var importReplaceExisting = false

    private let modelOptions: [(id: String, label: String, detail: String)] = [
        (ParakeetTranscriber.Variant.v2.rawValue, "Parakeet v2 (NVIDIA)",
         "Most accurate on your voice, near-instant to finish; Small runs the live preview • ~480MB + Small"),
        (ParakeetTranscriber.Variant.unified.rawValue, "Parakeet Unified (NVIDIA)",
         "Newer Parakeet: slightly fewer word errors, fewer stray full stops, lighter punctuation • ~600MB + Small"),
        (Qwen3ASRTranscriber.modelID, "Qwen3-ASR 1.7B (Alibaba)",
         "Best on names and punctuation, uses your vocabulary; ~1 s per 20 s of speech • ~2.5GB + Small"),
        ("small", "Whisper Small", "Whisper only, with the vocabulary prompt; less accurate than Parakeet • ~464MB"),
    ]

    var body: some View {
        TabView {
            generalTab
                .tabItem { Label("General", systemImage: "gearshape") }
            vocabularyTab
                .tabItem { Label("Vocabulary", systemImage: "text.book.closed") }
            correctionsTab
                .tabItem { Label("Corrections", systemImage: "arrow.triangle.2.circlepath") }
            modelTab
                .tabItem { Label("Model", systemImage: "waveform") }
            llmTab
                .tabItem { Label("LLM", systemImage: "sparkles") }
        }
        .frame(minWidth: 500, idealWidth: 550, minHeight: 350, idealHeight: 400)
        .onAppear {
            loadCachedModels()
            axTrusted = PasteboardClipboardService.isAccessibilityTrusted()
            escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                if event.keyCode == 53 { // Escape
                    NSApp.keyWindow?.close()
                    return nil
                }
                return event
            }
            // Observe modelReloading state to disable picker during reload
            observeModelReloading()
            // Load API key from Keychain on appear
            apiKeyText = keychain.get("llmApiKey") ?? ""
        }
        .onDisappear {
            if let monitor = escapeMonitor {
                NSEvent.removeMonitor(monitor)
                escapeMonitor = nil
            }
        }
        .onChange(of: selectedModel) { _, _ in
            // Refresh cache status when model changes (may trigger download)
            loadCachedModels()
        }
        .onChange(of: autoPasteEnabled) { _, _ in
            axTrusted = PasteboardClipboardService.isAccessibilityTrusted()
        }
        .onChange(of: modelDownloadProgress) { _, newProgress in
            // Refresh cache list when download completes
            if newProgress >= 1.0 {
                loadCachedModels()
            }
        }
        .onReceive(Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()) { _ in
            // Poll modelReloading flag written by SusurrusApp
            let reloading = UserDefaults.standard.bool(forKey: "modelReloading")
            if modelReloading != reloading {
                modelReloading = reloading
            }
        }
    }

    // MARK: - General

    private var generalTab: some View {
        Form {
            Picker("Recording Mode", selection: $recordingMode) {
                Text("Push to Talk").tag("push-to-talk")
                Text("Toggle").tag("toggle")
            }

            Toggle("Append to Clipboard", isOn: $appendToClipboard)
            if appendToClipboard {
                Text("Transcriptions will be added after existing clipboard content.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Toggle("Auto-paste at Cursor", isOn: $autoPasteEnabled)
            if autoPasteEnabled {
                if axTrusted {
                    Label("Accessibility access granted", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("Accessibility access required", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                        HStack(spacing: 8) {
                            Button("Open System Settings") {
                                PasteboardClipboardService.promptAccessibility()
                            }
                            Button("Reveal Binary") {
                                if let exePath = Bundle.main.executablePath {
                                    NSWorkspace.shared.selectFile(exePath, inFileViewerRootedAtPath: "")
                                }
                            }
                        }
                        .font(.caption)
                        Text("Open System Settings, click +, then drag the Susurrus binary into the list.")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            Toggle("Pause Media While Recording", isOn: $pauseMediaOnRecord)
            if pauseMediaOnRecord {
                Text("Spotify, Apple Music, and other media apps will pause when recording starts and resume when it stops.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Log word confidence (debug)", isOn: $confidenceLogging)
                Text("Records how sure the speech model was about each word to the debug log. Slightly slows the final decode. Used to evaluate confidence highlighting before building it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Diagnostics")
            }

            Section {
                Toggle("Keep recordings for accuracy testing", isOn: $keepRecordings)
                Text("Saves the audio of each review-panel dictation (Control+Option+Space) you insert or copy, with its text, so speech-model changes can be tested on your own voice. Stays on this Mac; the oldest are removed after \(EvalCaptureStore.defaultMaxClips).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Text(recordingsSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Show in Finder") {
                        let dir = EvalCaptureStore.defaultDirectory
                        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                        NSWorkspace.shared.activateFileViewerSelecting([dir])
                    }
                    Button("Delete recordings", role: .destructive) {
                        confirmDeleteRecordings = true
                    }
                    .disabled(recordingsCount == 0)
                }
            } header: {
                Text("Accuracy testing")
            }
            .confirmationDialog(
                "Delete all kept recordings?",
                isPresented: $confirmDeleteRecordings
            ) {
                Button("Delete recordings", role: .destructive) {
                    do {
                        try EvalCaptureStore().deleteAll()
                    } catch {
                        traceApp("evalCapture: delete failed: \(error)")
                    }
                    refreshRecordingsSummary()
                }
            } message: {
                Text("This removes the audio and the review status of every kept clip. It can't be undone.")
            }
            .onAppear { refreshRecordingsSummary() }
            .onChange(of: keepRecordings) { _, _ in refreshRecordingsSummary() }

        }
        .formStyle(.grouped)
    }

    private func refreshRecordingsSummary() {
        let store = EvalCaptureStore()
        let count = store.clipCount()
        recordingsCount = count
        if count == 0 {
            recordingsSummary = "No recordings kept"
        } else {
            let size = ByteCountFormatter.string(fromByteCount: store.audioBytes(), countStyle: .file)
            recordingsSummary = "\(count) recording\(count == 1 ? "" : "s"), \(size)"
        }
    }

    // MARK: - Vocabulary

    private var vocabularyTab: some View {
        let vocabManager = VocabularyManager.shared
        return Form {
            Section {
                if entries.isEmpty {
                    Text("No vocabulary entries yet. Add terms below.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding()
                } else {
                    ForEach(VocabularyCategory.allCases, id: \.self) { category in
                        let categoryEntries = entries.filter { $0.category == category }
                        if !categoryEntries.isEmpty {
                            Section {
                                ForEach(categoryEntries) { entry in
                                    HStack {
                                        Text(entry.term)
                                            .font(.body)
                                        Spacer()
                                        if let count = entry.useCount, count > 0 {
                                            // Usage feeds the prompt-token
                                            // ranking — surfacing it makes
                                            // the learning loop visible.
                                            Text("\(count)×")
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 2)
                                                .background(Capsule().fill(Color.secondary.opacity(0.12)))
                                                .help("Appeared in \(count) dictation\(count == 1 ? "" : "s") — boosts this term's bias ranking")
                                        }
                                        Button {
                                            withAnimation { removeEntry(id: entry.id) }
                                        } label: {
                                            Image(systemName: "minus.circle.fill")
                                                .foregroundStyle(.red.opacity(0.7))
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            } header: {
                                Label(category.displayName, systemImage: category.systemImage)
                            }
                        }
                    }
                }
            } header: {
                Text("Vocabulary")
            } footer: {
                Text("Terms are used to bias WhisperKit transcription and provide context to LLM cleanup.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Section {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        TextField("Enter term...", text: $newTerm)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { addEntry(vocabManager) }
                        Button("Add") { addEntry(vocabManager) }
                            .disabled(newTerm.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    Picker("Category", selection: $newCategory) {
                        ForEach(VocabularyCategory.allCases, id: \.self) { cat in
                            Label(cat.displayName, systemImage: cat.systemImage)
                                .tag(cat)
                        }
                    }
                    .pickerStyle(.segmented)
                }
            } header: {
                Text("Add Term")
            }

            Section {
                HStack {
                    Button("Import CSV...") {
                        importCSV(vocabManager)
                    }
                    Button("Export CSV...") {
                        exportCSV(vocabManager)
                    }
                    Spacer()
                    Toggle("Replace on import", isOn: $importReplaceExisting)
                        .toggleStyle(.checkbox)
                        .help("When checked, importing replaces all entries. Otherwise entries are merged.")
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            entries = vocabManager.entries()
        }
    }

    private func addEntry(_ manager: VocabularyManager) {
        let term = newTerm.trimmingCharacters(in: .whitespaces)
        guard !term.isEmpty else { return }
        let entry = VocabularyEntry(term: term, category: newCategory)
        manager.addEntry(entry)
        withAnimation { entries = manager.entries() }
        newTerm = ""
    }

    private func removeEntry(id: UUID) {
        let manager = VocabularyManager.shared
        manager.removeEntry(id: id)
        entries = manager.entries()
    }

    private func importCSV(_ manager: VocabularyManager) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Select a CSV file with Word,Category columns"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let csv = try? String(contentsOf: url, encoding: .utf8) else { return }
        if importReplaceExisting {
            manager.setEntries([])
        }
        let count = manager.importCSV(csv)
        withAnimation { entries = manager.entries() }
    }

    private func exportCSV(_ manager: VocabularyManager) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "vocabulary.csv"
        panel.message = "Export vocabulary as CSV"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        let csv = manager.exportCSV()
        try? csv.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - Corrections

    @State private var correctionRules: [CorrectionRule] = []
    @State private var newRuleMatch: String = ""
    @State private var newRuleReplacement: String = ""
    @State private var correctionPairCount: Int = 0

    private var correctionsTab: some View {
        let manager = CorrectionLearningManager.shared
        return Form {
            Section {
                HStack {
                    TextField("Misheard as (e.g. core bee)", text: $newRuleMatch)
                        .textFieldStyle(.roundedBorder)
                    Image(systemName: "arrow.right")
                        .foregroundStyle(.secondary)
                    TextField("Replace with (e.g. CoRB)", text: $newRuleReplacement)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { addRule(manager) }
                    Button("Add") { addRule(manager) }
                        .disabled(
                            newRuleMatch.trimmingCharacters(in: .whitespaces).isEmpty ||
                            newRuleReplacement.trimmingCharacters(in: .whitespaces).isEmpty
                        )
                }
            } header: {
                Text("Replacement Rules")
            } footer: {
                Text("Applied to every transcription. Rules are also learned automatically when you edit transcriptions in History.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Section {
                if correctionRules.isEmpty {
                    Text("No rules yet. Edit a transcription in History and Susurrus will learn from your fix.")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                } else {
                    ForEach(correctionRules) { rule in
                        ruleRow(rule, manager: manager)
                    }
                }
            }

            Section {
                HStack {
                    Text("\(correctionPairCount) recorded edit\(correctionPairCount == 1 ? "" : "s") feeding LLM few-shot examples")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                    Spacer()
                    Button("Clear edit history", role: .destructive) {
                        manager.clearCorrections()
                        correctionPairCount = 0
                    }
                    .disabled(correctionPairCount == 0)
                }
            } header: {
                Text("Learning Data")
            }
        }
        .formStyle(.grouped)
        .onAppear { reloadCorrections(manager) }
    }

    @ViewBuilder
    private func ruleRow(_ rule: CorrectionRule, manager: CorrectionLearningManager) -> some View {
        HStack(spacing: 8) {
            Toggle("", isOn: Binding(
                get: { rule.enabled },
                set: { enabled in
                    manager.setRuleEnabled(id: rule.id, enabled: enabled)
                    reloadCorrections(manager)
                }
            ))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .labelsHidden()

            Text(rule.match)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(rule.enabled ? .primary : .tertiary)
            Image(systemName: "arrow.right")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(rule.replacement)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(rule.enabled ? .primary : .tertiary)

            Spacer()

            if rule.source == .learned {
                // Two distinct numbers, previously conflated: how often you
                // taught this, versus how often it has actually fixed anything.
                Text(rule.hitCount == 1 ? "learned · 1 edit" : "learned · \(rule.hitCount) edits")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.secondary.opacity(0.15)))

                Text(rule.fireCount == 0
                     ? "never fired"
                     : (rule.fireCount == 1 ? "fixed 1×" : "fixed \(rule.fireCount)×"))
                    .font(.caption2)
                    .foregroundStyle(rule.fireCount == 0 ? .tertiary : .secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.secondary.opacity(rule.fireCount == 0 ? 0.08 : 0.15)))
                    .help(rule.lastFiredAt.map { "Last fired \($0.formatted(date: .abbreviated, time: .shortened))" }
                          ?? "This rule has never corrected a transcript")
            } else {
                Text("manual")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.accentColor.opacity(0.15)))
            }

            Button {
                manager.removeRule(id: rule.id)
                reloadCorrections(manager)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
    }

    private func addRule(_ manager: CorrectionLearningManager) {
        let match = newRuleMatch.trimmingCharacters(in: .whitespaces)
        let replacement = newRuleReplacement.trimmingCharacters(in: .whitespaces)
        guard !match.isEmpty, !replacement.isEmpty else { return }
        manager.addRule(CorrectionRule(match: match, replacement: replacement, source: .manual))
        newRuleMatch = ""
        newRuleReplacement = ""
        withAnimation { reloadCorrections(manager) }
    }

    private func reloadCorrections(_ manager: CorrectionLearningManager) {
        correctionRules = manager.rules()
        correctionPairCount = manager.allCorrections().count
    }

    // MARK: - Model

    private var modelTab: some View {
        Form {
            Section {
                ForEach(modelOptions, id: \.id) { option in
                    modelRow(option)
                }
            } header: {
                Text("Transcription Model")
            } footer: {
                if !modelDownloadingName.isEmpty {
                    downloadFooter
                } else if cachedModels.contains(selectedModel) {
                    Text("Switching to a cached model is instant. Uncached models download on selection.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func modelRow(_ option: (id: String, label: String, detail: String)) -> some View {
        let isSelected = selectedModel == option.id
        let isCached = cachedModels.contains(option.id)
        let isDownloading = modelDownloadingName == option.id

        HStack(spacing: 10) {
            // Selection indicator
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isSelected ? .blue : .secondary)
                .font(.title3)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(option.label)
                        .fontWeight(isSelected ? .semibold : .regular)
                    if isCached {
                        Text("Cached")
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.green.opacity(0.15))
                            .foregroundStyle(.green)
                            .clipShape(Capsule())
                    }
                    if isDownloading {
                        Text("Downloading...")
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.blue.opacity(0.15))
                            .foregroundStyle(.blue)
                            .clipShape(Capsule())
                    }
                }
                Text(option.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if isDownloading {
                ProgressView()
                    .scaleEffect(0.7)
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .disabled(modelReloading)
        .opacity(modelReloading ? 0.5 : 1.0)
        .overlay {
            if modelReloading {
                HStack(spacing: 6) {
                    ProgressView()
                        .scaleEffect(0.6)
                        .controlSize(.small)
                    Text("Switching model...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8)
            }
        }
        .onTapGesture {
            guard !modelReloading, selectedModel != option.id else { return }
            selectedModel = option.id
        }
    }

    private var downloadFooter: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Downloading \(modelDownloadingName)...")
                .font(.caption)
                .foregroundStyle(.secondary)
            ProgressView(value: modelDownloadProgress)
                .progressViewStyle(.linear)
            Text("\(Int(modelDownloadProgress * 100))% complete")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.top, 4)
    }

    // MARK: - LLM

    private var llmTab: some View {
        Form {
            Section {
                Toggle("Enable LLM post-processing", isOn: $llmEnabled)
            } footer: {
                Text("Optional polish. Vocabulary corrections and learned fixes are always applied, with or without the LLM.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Section {
                Picker("Provider", selection: $llmProvider) {
                    ForEach(LLMProvider.allCases, id: \.rawValue) { provider in
                        Text(provider.displayName).tag(provider.rawValue)
                    }
                }
                .pickerStyle(.menu)
            }

            if llmProvider != LLMProvider.cloud.rawValue {
                Section {
                    TextField("Local endpoint", text: $llmLocalEndpoint)
                        .textFieldStyle(.roundedBorder)
                    TextField("Local model (blank = whatever is loaded)", text: $llmLocalModel)
                        .textFieldStyle(.roundedBorder)
                    HStack {
                        Button(localTestRunning ? "Testing…" : "Test connection") {
                            testLocalConnection()
                        }
                        .disabled(localTestRunning)
                        if let result = localTestResult {
                            Text(result)
                                .font(.caption)
                                .foregroundStyle(result.hasPrefix("OK") ? .green : .red)
                        }
                    }
                } header: {
                    Text("Local Server")
                } footer: {
                    Text("OpenAI-compatible server, e.g. LM Studio (http://localhost:1234/v1/chat/completions) or Ollama (http://localhost:11434/v1/chat/completions).")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            if llmProvider != LLMProvider.local.rawValue {
                cloudProviderSection
            }

            Section {
                VStack(alignment: .leading) {
                    Text("System Prompt")
                        .font(.headline)
                    TextEditor(text: $llmSystemPrompt)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(minHeight: 150)
                        .scrollContentBackground(.visible)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var cloudProviderSection: some View {
        Section {
            HStack {
                if showApiKey {
                    TextField("API Key", text: $apiKeyText)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: apiKeyText) { _, newValue in
                            // Save to Keychain on every keystroke
                            keychain.set(newValue, for: "llmApiKey")
                        }
                } else {
                    SecureField("API Key", text: $apiKeyText)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: apiKeyText) { _, newValue in
                            keychain.set(newValue, for: "llmApiKey")
                        }
                }
                Button(action: { showApiKey.toggle() }) {
                    Image(systemName: showApiKey ? "eye.slash" : "eye")
                }
                .buttonStyle(.plain)
            }

            TextField("Model", text: $llmModel)
                .textFieldStyle(.roundedBorder)

            TextField("Endpoint", text: $llmEndpoint)
                .textFieldStyle(.roundedBorder)
        } header: {
            Text("Cloud Provider")
        } footer: {
            Text("Anthropic-compatible endpoint. Defaults to MiniMax.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    /// Sends a tiny completion to the configured local endpoint.
    private func testLocalConnection() {
        localTestRunning = true
        localTestResult = nil
        let endpoint = llmLocalEndpoint
        let model = llmLocalModel
        Task { @MainActor in
            defer { localTestRunning = false }
            guard let url = URL(string: endpoint) else {
                localTestResult = "Invalid URL"
                return
            }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.timeoutInterval = 10
            var body: [String: Any] = [
                "messages": [["role": "user", "content": "Reply with the single word: ok"]],
                "temperature": 0,
                "max_tokens": 8
            ]
            if !model.isEmpty { body["model"] = model }
            do {
                request.httpBody = try JSONSerialization.data(withJSONObject: body)
                let start = Date()
                let (_, response) = try await URLSession.shared.data(for: request)
                let ms = Int(Date().timeIntervalSince(start) * 1000)
                if let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) {
                    localTestResult = "OK (\(ms)ms)"
                } else {
                    let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                    localTestResult = "HTTP \(code)"
                }
            } catch {
                localTestResult = "Unreachable: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Cache Check

    /// Reads the modelReloading flag from UserDefaults (written by SusurrusApp)
    /// and keeps the local state in sync. Called on .onAppear.
    private func observeModelReloading() {
        modelReloading = UserDefaults.standard.bool(forKey: "modelReloading")
    }

    private func loadCachedModels() {
        let fm = FileManager.default
        guard let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return
        }
        let modelsDir = appSupport
            .appendingPathComponent("Susurrus")
            .appendingPathComponent("models")
            .appendingPathComponent("argmaxinc")
            .appendingPathComponent("whisperkit-coreml")

        var cached = Set<String>()
        for variant in ParakeetTranscriber.Variant.allCases where ParakeetTranscriber.isCached(variant) {
            cached.insert(variant.rawValue)
        }
        if Qwen3ASRTranscriber.isCached() {
            cached.insert(Qwen3ASRTranscriber.modelID)
        }
        guard let contents = try? fm.contentsOfDirectory(at: modelsDir, includingPropertiesForKeys: nil) else {
            cachedModels = cached
            return
        }

        for url in contents {
            let name = url.lastPathComponent
            // Pattern: openai_whisper-{modelName} or openai_whisper-{modelName}_...
            // Extract the model identifier after "openai_whisper-"
            if name.hasPrefix("openai_whisper-") {
                let modelId = String(name.dropFirst("openai_whisper-".count))
                // Check it contains a known model id
                let knownModels = modelOptions.map(\.id)
                if knownModels.contains(modelId) {
                    cached.insert(modelId)
                }
            }
        }
        cachedModels = cached
    }

}
