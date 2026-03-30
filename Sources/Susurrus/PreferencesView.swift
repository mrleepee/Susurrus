import SwiftUI
import SusurrusKit
import AVFoundation

struct PreferencesView: View {
    @AppStorage("recordingMode") private var recordingMode = "push-to-talk"
    @AppStorage("appendToClipboard") private var appendToClipboard = false
    @AppStorage("selectedModel") private var selectedModel = "base"
    @AppStorage("inputDeviceID") private var inputDeviceID: String = ""
    @AppStorage("llmEnabled") private var llmEnabled = false
    @AppStorage("autoPasteEnabled") private var autoPasteEnabled = false
    @State private var axTrusted = false
    @AppStorage("llmApiKey") private var llmApiKey: String = ""
    @AppStorage("llmModel") private var llmModel: String = "MiniMax-M2.5"
    @AppStorage("llmEndpoint") private var llmEndpoint: String = "https://api.minimax.io/anthropic/v1/messages"
    @AppStorage("llmSystemPrompt") private var llmSystemPrompt = UserDefaultsPreferencesManager.defaultLLMPrompt
    @State private var vocabularyText: String = ""
    @State private var showApiKey: Bool = false

    // Download state bridged from SusurrusApp via UserDefaults
    @AppStorage("modelDownloadProgress") private var modelDownloadProgress: Double = 0
    @AppStorage("modelDownloadingName") private var modelDownloadingName: String = ""

    @State private var inputDevices: [(id: String, name: String)] = []
    @State private var cachedModels: Set<String> = []
    @State private var escapeMonitor: Any?

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
        }
        .frame(minWidth: 500, idealWidth: 550, minHeight: 350, idealHeight: 400)
        .onAppear {
            loadInputDevices()
            loadCachedModels()
            axTrusted = PasteboardClipboardService.isAccessibilityTrusted()
            escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                if event.keyCode == 53 { // Escape
                    NSApp.keyWindow?.close()
                    return nil
                }
                return event
            }
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

            Picker("Input Device", selection: $inputDeviceID) {
                Text("System Default").tag("")
                ForEach(inputDevices, id: \.id) { device in
                    Text(device.name).tag(device.id)
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Vocabulary

    private var vocabularyTab: some View {
        let vocabManager = VocabularyManager()
        return Form {
            Section {
                TextEditor(text: $vocabularyText)
                    .font(.system(size: 13, design: .monospaced))
                    .frame(minHeight: 180)
                    .scrollContentBackground(.visible)
            } header: {
                Text("Custom Vocabulary")
            } footer: {
                Text("One word or phrase per line. These bias WhisperKit toward recognising domain-specific terms (e.g. product names, technical jargon, proper nouns).")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            vocabularyText = vocabManager.vocabularyWords().joined(separator: "\n")
        }
        .onChange(of: vocabularyText) { _, newValue in
            let words = newValue
                .split(separator: "\n", omittingEmptySubsequences: true)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            vocabManager.setVocabularyWords(words)
        }
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
        .onTapGesture {
            guard selectedModel != option.id else { return }
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
                        TextField("API Key", text: $llmApiKey)
                            .textFieldStyle(.roundedBorder)
                    } else {
                        SecureField("API Key", text: $llmApiKey)
                            .textFieldStyle(.roundedBorder)
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

    // MARK: - Device Discovery

    private func loadInputDevices() {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInMicrophone, .externalUnknown],
            mediaType: .audio,
            position: .unspecified
        )
        inputDevices = discovery.devices.compactMap { device in
            guard let uniqueID = device.value(forKey: "uniqueID") as? String else { return nil }
            return (id: uniqueID, name: device.localizedName)
        }
    }

    // MARK: - Cache Check

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
}
