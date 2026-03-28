import Testing
@testable import SusurrusKit

@Suite("MenuState Tests")
struct MenuStateTests {

    // MARK: - Recording action

    @Test("Idle state shows Start Recording")
    func idleShowsStartRecording() {
        #expect(MenuState.recordingAction(for: .idle) == .startRecording)
    }

    @Test("Recording state shows Stop Recording")
    func recordingShowsStopRecording() {
        #expect(MenuState.recordingAction(for: .recording) == .stopRecording)
    }

    @Test("Processing state shows Start Recording")
    func processingShowsStartRecording() {
        #expect(MenuState.recordingAction(for: .processing) == .startRecording)
    }

    // MARK: - Enabled state

    @Test("Recording action enabled in idle state")
    func enabledInIdle() {
        #expect(MenuState.isRecordingEnabled(for: .idle) == true)
    }

    @Test("Recording action enabled in recording state")
    func enabledInRecording() {
        #expect(MenuState.isRecordingEnabled(for: .recording) == true)
    }

    @Test("Recording action disabled during processing")
    func disabledDuringProcessing() {
        #expect(MenuState.isRecordingEnabled(for: .processing) == false)
    }

    // MARK: - Visible actions

    @Test("Idle state has Start Recording, Preferences, Quit")
    func idleMenuItems() {
        let actions = MenuState.visibleActions(for: .idle)
        #expect(actions == [.startRecording, .preferences, .quit])
    }

    @Test("Recording state has Stop Recording, Preferences, Quit")
    func recordingMenuItems() {
        let actions = MenuState.visibleActions(for: .recording)
        #expect(actions == [.stopRecording, .preferences, .quit])
    }

    @Test("Processing state has Start Recording, Preferences, Quit")
    func processingMenuItems() {
        let actions = MenuState.visibleActions(for: .processing)
        #expect(actions == [.startRecording, .preferences, .quit])
    }

    @Test("All states include Preferences and Quit")
    func allStatesIncludeCoreItems() {
        for state in RecordingState.allCases {
            let actions = MenuState.visibleActions(for: state)
            #expect(actions.contains(.preferences))
            #expect(actions.contains(.quit))
        }
    }
}
