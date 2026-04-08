import SwiftUI
import SusurrusKit

private let keychain = KeychainService()

struct PreferencesView: View {
    @AppStorage("recordingMode") private var recordingMode = "push-to-talk"
    @AppStorage("appendToClipboard") private var appendToClipboard = false
    @AppStorage("selectedModel") private var selectedModel = "base"
    @AppStorage("llmEnabled") private var llmEnabled = false
    @AppStorage("autoPasteEnabled") private var autoPasteEnabled = true
    @AppStorage("pauseMediaOnRecord") private var pauseMediaOnRecord = true
    @State private var axTrusted = false
    @AppStorage("llmModel") private var llmModel: String = "MiniMax-M2.5"
    @AppStorage("llmEndpoint") private var llmEndpoint: String = "https://api.minimax.io/anthropic/v1/messages"
    @AppStorage("llmSystemPrompt") private var llmSystemPrompt = UserDefaultsPreferencesManager.defaultLLMPrompt
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

    private let modelOptions: [(id: String, label: String, detail: String)] = [
        ("base", "Base", "Fastest • ~140MB"),
        ("small", "Small", "Good balance • ~464MB"),
        ("medium", "Medium", "More accurate • ~770MB"),
        ("large-v3", "Large v3", "Most accurate • ~2.9GB"),
        ("large-v3_turbo", "Large v3 Turbo", "Fast & accurate • ~3.0GB"),
        ("distil-large-v3", "Distil Large v3", "Compact & fast • ~594MB"),
    ]

    var body: some View {
        TabView {
            generalTab
                .tabItem { Label("General", systemImage: "gearshape") }
            vocabularyTab
                .tabItem { Label("Vocabulary", systemImage: "text.book.closed") }
            modelTab
                .tabItem { Label("Model", systemImage: "waveform") }
            llmTab
                .tabItem { Label("LLM", systemImage: "sparkles") }
            notebooksTab
                .tabItem { Label("Notebooks", systemImage: "book") }
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

        }
        .formStyle(.grouped)
    }

    // MARK: - Vocabulary

    private var vocabularyTab: some View {
        let vocabManager = VocabularyManager()
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
                                        Text(category.displayName)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
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
                HStack {
                    TextField("Term", text: $newTerm)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { addEntry(vocabManager) }
                    Picker("Category", selection: $newCategory) {
                        ForEach(VocabularyCategory.allCases, id: \.self) { cat in
                            Label(cat.displayName, systemImage: cat.systemImage)
                                .tag(cat)
                        }
                    }
                    .frame(width: 140)
                    Button("Add") { addEntry(vocabManager) }
                        .disabled(newTerm.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } header: {
                Text("Add Term")
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
        let manager = VocabularyManager()
        manager.removeEntry(id: id)
        entries = manager.entries()
    }

    // MARK: - Model

    private var modelTab: some View {
        Form {
            Section {
                ForEach(modelOptions, id: \.id) { option in
                    modelRow(option)
                }
            } header: {
                Text("Whisper Model")
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
            }

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
                Text("Provider Configuration")
            } footer: {
                Text("Anthropic-compatible endpoint. Defaults to MiniMax.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
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

        guard let contents = try? fm.contentsOfDirectory(at: modelsDir, includingPropertiesForKeys: nil) else {
            return
        }

        var cached = Set<String>()
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

    // MARK: - Notebooks

    @State private var notebookList: [Notebook] = []
    @State private var newNotebookName: String = ""
    @State private var selectedNotebookId: UUID?
    @State private var currentEntries: [NotebookEntry] = []
    @State private var editingEntryId: UUID?
    @State private var editingEntryText: String = ""
    @State private var renamingNotebookId: UUID?
    @State private var renameText: String = ""

    private var notebooksTab: some View {
        let manager = NotebookManager()
        return HSplitView {
            // Left pane: notebook list
            VStack(alignment: .leading, spacing: 0) {
                Text("Notebooks")
                    .font(.headline)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)

                if notebookList.isEmpty {
                    Text("No notebooks yet.\nCreate one below.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .multilineTextAlignment(.center)
                        .padding()
                } else {
                    List(notebookList, selection: $selectedNotebookId) { notebook in
                        notebookRow(notebook, manager: manager)
                    }
                    .listStyle(.sidebar)
                }

                Divider()

                // Create new notebook
                HStack {
                    TextField("New notebook", text: $newNotebookName)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { createNotebook(manager) }
                    Button(action: { createNotebook(manager) }) {
                        Image(systemName: "plus")
                    }
                    .disabled(newNotebookName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(8)
            }
            .frame(minWidth: 200, idealWidth: 250, maxWidth: 350)

            // Right pane: entries for selected notebook
            entryDetailPane(manager: manager)
                .frame(minWidth: 300, idealWidth: 400)
        }
        .frame(minWidth: 550, idealWidth: 700, minHeight: 350, idealHeight: 450)
        .onAppear {
            loadNotebooks(manager)
        }
        .onChange(of: selectedNotebookId) { _, newId in
            loadEntries(manager)
            editingEntryId = nil
        }
    }

    @ViewBuilder
    private func notebookRow(_ notebook: Notebook, manager: NotebookManager) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                if renamingNotebookId == notebook.id {
                    TextField("Notebook name", text: $renameText)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit {
                            let trimmed = renameText.trimmingCharacters(in: .whitespaces)
                            if !trimmed.isEmpty {
                                manager.renameNotebook(id: notebook.id, newName: trimmed)
                                loadNotebooks(manager)
                            }
                            renamingNotebookId = nil
                        }
                        .onExitCommand {
                            renamingNotebookId = nil
                        }
                } else {
                    Text(notebook.name)
                        .fontWeight(.medium)
                    Text("\(notebook.entries.count) entries • \(notebook.updatedAt, style: .relative)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if manager.activeNotebookId() == notebook.id {
                Text("Active")
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.blue.opacity(0.15))
                    .foregroundStyle(.blue)
                    .clipShape(Capsule())
            }
            Button {
                manager.setActiveNotebookId(notebook.id)
                loadNotebooks(manager)
            } label: {
                Image(systemName: manager.activeNotebookId() == notebook.id ? "bookmark.fill" : "bookmark")
                    .foregroundStyle(.blue)
            }
            .buttonStyle(.plain)
            .help("Set as active notebook")

            Button {
                renameText = notebook.name
                renamingNotebookId = notebook.id
            } label: {
                Image(systemName: "pencil")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Rename notebook")

            Button {
                manager.deleteNotebook(id: notebook.id)
                if selectedNotebookId == notebook.id {
                    selectedNotebookId = nil
                    currentEntries = []
                }
                loadNotebooks(manager)
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(.red.opacity(0.7))
            }
            .buttonStyle(.plain)
            .help("Delete notebook")
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func entryDetailPane(manager: NotebookManager) -> some View {
        if let selectedId = selectedNotebookId,
           let notebook = notebookList.first(where: { $0.id == selectedId }) {
            VStack(alignment: .leading, spacing: 0) {
                // Header
                HStack {
                    Text(notebook.name)
                        .font(.title3)
                        .fontWeight(.semibold)
                    Text("\(currentEntries.count) entries")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("Active notebook context: last entries used for LLM prompt")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

                Divider()

                if currentEntries.isEmpty {
                    Text("No entries yet.\nTranscriptions will appear here when this notebook is active.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .multilineTextAlignment(.center)
                        .padding()
                } else {
                    List {
                        ForEach(currentEntries) { entry in
                            entryRow(entry, notebookId: notebook.id, manager: manager)
                        }
                    }
                    .listStyle(.inset)
                }
            }
        } else {
            VStack {
                Image(systemName: "book")
                    .font(.system(size: 40))
                    .foregroundStyle(.quaternary)
                Text("Select a notebook to view entries")
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func entryRow(_ entry: NotebookEntry, notebookId: UUID, manager: NotebookManager) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(entry.date, style: .date)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(entry.date, style: .time)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                if entry.isEdited {
                    Text("edited")
                        .font(.caption2)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(.orange.opacity(0.15))
                        .foregroundStyle(.orange)
                        .clipShape(Capsule())
                }
                Spacer()

                if editingEntryId != entry.id {
                    Button {
                        editingEntryId = entry.id
                        editingEntryText = entry.text
                    } label: {
                        Image(systemName: "pencil")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Edit entry")
                }

                Button {
                    manager.deleteEntry(notebookId: notebookId, entryId: entry.id)
                    loadEntries(manager)
                } label: {
                    Image(systemName: "trash")
                        .foregroundStyle(.red.opacity(0.5))
                }
                .buttonStyle(.plain)
                .help("Delete entry")
            }

            if editingEntryId == entry.id {
                VStack(alignment: .trailing, spacing: 6) {
                    TextEditor(text: $editingEntryText)
                        .font(.system(size: 13))
                        .frame(minHeight: 80)
                        .border(Color(nsColor: .separatorColor), width: 1)

                    HStack(spacing: 8) {
                        Button("Cancel") {
                            editingEntryId = nil
                        }
                        Button("Save") {
                            manager.updateEntry(
                                notebookId: notebookId,
                                entryId: entry.id,
                                newText: editingEntryText
                            )
                            editingEntryId = nil
                            loadEntries(manager)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(editingEntryText.isEmpty)
                    }
                }
            } else {
                Text(entry.text)
                    .font(.system(size: 13))
                    .textSelection(.enabled)
                if let diff = entry.diffDescription {
                    Text(diff)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.orange.opacity(0.8))
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func createNotebook(_ manager: NotebookManager) {
        let name = newNotebookName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let nb = manager.createNotebook(name: name)
        newNotebookName = ""
        loadNotebooks(manager)
        selectedNotebookId = nb.id
    }

    private func loadNotebooks(_ manager: NotebookManager) {
        notebookList = manager.notebooks()
        loadEntries(manager)
    }

    private func loadEntries(_ manager: NotebookManager) {
        guard let id = selectedNotebookId else {
            currentEntries = []
            return
        }
        currentEntries = NotebookEntry.sortedDescending(manager.notebookEntries(id: id))
    }
}
