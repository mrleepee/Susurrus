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

    @Test("Streaming state shows Stop Recording")
    func streamingShowsStopRecording() {
        #expect(MenuState.recordingAction(for: .streaming) == .stopRecording)
    }

    @Test("Finalizing state shows Start Recording")
    func finalizingShowsStartRecording() {
        #expect(MenuState.recordingAction(for: .finalizing) == .startRecording)
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

    @Test("Recording action enabled in streaming state")
    func enabledInStreaming() {
        #expect(MenuState.isRecordingEnabled(for: .streaming) == true)
    }

    @Test("Recording action disabled during finalizing")
    func disabledDuringFinalizing() {
        #expect(MenuState.isRecordingEnabled(for: .finalizing) == false)
    }

    // MARK: - Visible actions

    @Test("Idle state has Start Recording, Preferences, Quit")
    func idleMenuItems() {
        let actions = MenuState.visibleActions(for: .idle)
        #expect(actions == [.startRecording, .preferences, .quit])
    }

    @Test("Streaming state has Stop Recording, Preferences, Quit")
    func streamingMenuItems() {
        let actions = MenuState.visibleActions(for: .streaming)
        #expect(actions == [.stopRecording, .preferences, .quit])
    }

    @Test("Finalizing state has Start Recording, Preferences, Quit (disabled)")
    func finalizingMenuItems() {
        let actions = MenuState.visibleActions(for: .finalizing)
        #expect(actions == [.startRecording, .preferences, .quit])
    }
}
