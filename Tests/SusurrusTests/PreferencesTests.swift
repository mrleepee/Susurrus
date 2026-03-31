import Testing
@testable import SusurrusKit

@Suite("Preferences Tests")
struct PreferencesTests {

    private func makeManager() -> UserDefaultsPreferencesManager {
        UserDefaultsPreferencesManager.createForTesting()
    }

    // MARK: - Recording mode (R8)

    @Test("Default recording mode is push-to-talk")
    func defaultRecordingMode() {
        let manager = makeManager()
        #expect(manager.recordingMode() == .pushToTalk)
    }

    @Test("Set and get toggle mode")
    func setToggleMode() {
        let manager = makeManager()
        manager.setRecordingMode(.toggle)
        #expect(manager.recordingMode() == .toggle)
    }

    @Test("Set and get push-to-talk mode")
    func setPushToTalkMode() {
        let manager = makeManager()
        manager.setRecordingMode(.toggle)
        manager.setRecordingMode(.pushToTalk)
        #expect(manager.recordingMode() == .pushToTalk)
    }

    // MARK: - Selected model (R13)

    @Test("Default selected model is base")
    func defaultModel() {
        let manager = makeManager()
        #expect(manager.selectedModel() == "base")
    }

    @Test("Set and get selected model")
    func setModel() {
        let manager = makeManager()
        manager.setSelectedModel("base")
        #expect(manager.selectedModel() == "base")
    }

    // MARK: - Append to clipboard (R19)

    @Test("Default append-to-clipboard is disabled")
    func defaultAppendToClipboard() {
        let manager = makeManager()
        #expect(manager.appendToClipboard() == false)
    }

    @Test("Enable append-to-clipboard")
    func enableAppendToClipboard() {
        let manager = makeManager()
        manager.setAppendToClipboard(true)
        #expect(manager.appendToClipboard() == true)
    }

    @Test("Disable append-to-clipboard")
    func disableAppendToClipboard() {
        let manager = makeManager()
        manager.setAppendToClipboard(true)
        manager.setAppendToClipboard(false)
        #expect(manager.appendToClipboard() == false)
    }
}
