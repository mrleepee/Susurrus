import Foundation
import Testing
@testable import SusurrusKit

@Suite("UserDefaults Preferences Manager Tests")
struct UserDefaultsPreferencesManagerTests {

    private func makeManager() -> UserDefaultsPreferencesManager {
        UserDefaultsPreferencesManager.createForTesting()
    }

    // MARK: - recordingMode

    @Test("recordingMode defaults to pushToTalk")
    func recordingModeDefault() {
        let manager = makeManager()
        #expect(manager.recordingMode() == .pushToTalk)
    }

    @Test("setRecordingMode persists value")
    func setRecordingMode() {
        let manager = makeManager()
        manager.setRecordingMode(.toggle)
        #expect(manager.recordingMode() == .toggle)
        manager.setRecordingMode(.pushToTalk)
        #expect(manager.recordingMode() == .pushToTalk)
    }

    // MARK: - selectedModel

    @Test("selectedModel defaults to base")
    func selectedModelDefault() {
        let manager = makeManager()
        #expect(manager.selectedModel() == "base")
    }

    @Test("setSelectedModel persists value")
    func setSelectedModel() {
        let manager = makeManager()
        manager.setSelectedModel("large-v3")
        #expect(manager.selectedModel() == "large-v3")
    }

    // MARK: - appendToClipboard

    @Test("appendToClipboard defaults to false")
    func appendToClipboardDefault() {
        let manager = makeManager()
        // UserDefaults bool defaults to false when key absent
        #expect(manager.appendToClipboard() == false)
    }

    @Test("setAppendToClipboard persists value")
    func setAppendToClipboard() {
        let manager = makeManager()
        manager.setAppendToClipboard(true)
        #expect(manager.appendToClipboard() == true)
        manager.setAppendToClipboard(false)
        #expect(manager.appendToClipboard() == false)
    }

    // MARK: - llmEnabled

    @Test("llmEnabled defaults to false")
    func llmEnabledDefault() {
        let manager = makeManager()
        #expect(manager.llmEnabled() == false)
    }

    @Test("setLLMEnabled persists value")
    func setLLMEnabled() {
        let manager = makeManager()
        manager.setLLMEnabled(true)
        #expect(manager.llmEnabled() == true)
        manager.setLLMEnabled(false)
        #expect(manager.llmEnabled() == false)
    }

    // MARK: - llmSystemPrompt

    @Test("llmSystemPrompt defaults to built-in prompt")
    func llmSystemPromptDefault() {
        let manager = makeManager()
        #expect(manager.llmSystemPrompt() == UserDefaultsPreferencesManager.defaultLLMPrompt)
    }

    @Test("setLLMSystemPrompt persists value")
    func setLLMSystemPrompt() {
        let manager = makeManager()
        let custom = "Custom prompt for testing"
        manager.setLLMSystemPrompt(custom)
        #expect(manager.llmSystemPrompt() == custom)
    }

    @Test("setLLMSystemPrompt with blank string falls back to default")
    func llmSystemPromptBlankFallsBack() {
        let manager = makeManager()
        manager.setLLMSystemPrompt("   ")
        #expect(manager.llmSystemPrompt() == UserDefaultsPreferencesManager.defaultLLMPrompt)
    }

    // MARK: - autoPasteEnabled

    @Test("autoPasteEnabled defaults to true")
    func autoPasteEnabledDefault() {
        let manager = makeManager()
        #expect(manager.autoPasteEnabled() == true)
    }

    @Test("setAutoPasteEnabled persists value")
    func setAutoPasteEnabled() {
        let manager = makeManager()
        manager.setAutoPasteEnabled(false)
        #expect(manager.autoPasteEnabled() == false)
        manager.setAutoPasteEnabled(true)
        #expect(manager.autoPasteEnabled() == true)
    }

    // MARK: - llmModelName

    @Test("llmModelName defaults to MiniMax-M2.5")
    func llmModelNameDefault() {
        let manager = makeManager()
        #expect(manager.llmModelName() == "MiniMax-M2.5")
    }

    @Test("setLLMModelName persists value")
    func setLLMModelName() {
        let manager = makeManager()
        manager.setLLMModelName("gpt-4o")
        #expect(manager.llmModelName() == "gpt-4o")
    }

    // MARK: - llmEndpointURL

    @Test("llmEndpointURL defaults to MiniMax Anthropic proxy")
    func llmEndpointURLDefault() {
        let manager = makeManager()
        #expect(manager.llmEndpointURL() == "https://api.minimax.io/anthropic/v1/messages")
    }

    @Test("setLLMEndpointURL persists value")
    func setLLMEndpointURL() {
        let manager = makeManager()
        manager.setLLMEndpointURL("https://api.openai.com/v1/chat/completions")
        #expect(manager.llmEndpointURL() == "https://api.openai.com/v1/chat/completions")
    }

    // MARK: - Cross-instance persistence

    @Test("Values persist across separate manager instances")
    func crossInstancePersistence() {
        let suite = "com.susurrus.test.prefs.cross.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        let writer = UserDefaultsPreferencesManager(defaults: defaults)
        writer.setRecordingMode(.toggle)
        writer.setSelectedModel("large-v3")
        writer.setLLMEnabled(true)

        // Fresh instance reading same defaults
        let reader = UserDefaultsPreferencesManager(defaults: defaults)
        #expect(reader.recordingMode() == .toggle)
        #expect(reader.selectedModel() == "large-v3")
        #expect(reader.llmEnabled() == true)
    }

    // MARK: - Invalid recording mode fallback

    @Test("Invalid recording mode string falls back to pushToTalk")
    func invalidRecordingModeFallback() {
        let suite = "com.susurrus.test.prefs.invalid.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set("invalid-mode", forKey: "recordingMode")
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        let manager = UserDefaultsPreferencesManager(defaults: defaults)
        #expect(manager.recordingMode() == .pushToTalk)
    }
}
