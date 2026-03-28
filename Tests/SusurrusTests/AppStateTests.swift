import Testing
@testable import SusurrusKit

@MainActor
@Suite("AppState Tests")
struct AppStateTests {

    // MARK: - Basic state transitions

    @Test("Initial state is idle")
    func initialStateIsIdle() {
        let state = AppState()
        #expect(state.recordingState == .idle)
    }

    @Test("startRecording transitions from idle to recording")
    func startRecording() {
        let state = AppState()
        state.startRecording()
        #expect(state.recordingState == .recording)
    }

    @Test("startRecording is no-op when not idle")
    func startRecordingNoOpWhenNotIdle() {
        let state = AppState()
        state.startRecording()
        state.startRecording()
        #expect(state.recordingState == .recording)

        state.cancel()
        state.startRecording()
        state.stopRecording() // recording -> processing
        state.startRecording()
        #expect(state.recordingState == .processing)
    }

    @Test("stopRecording transitions from recording to processing")
    func stopRecording() {
        let state = AppState()
        state.startRecording()
        state.stopRecording()
        #expect(state.recordingState == .processing)
    }

    @Test("stopRecording is no-op when not recording")
    func stopRecordingNoOpWhenNotRecording() {
        let state = AppState()
        state.stopRecording()
        #expect(state.recordingState == .idle)
    }

    @Test("finishProcessing transitions from processing to idle")
    func finishProcessing() {
        let state = AppState()
        state.startRecording()
        state.stopRecording()
        state.finishProcessing()
        #expect(state.recordingState == .idle)
    }

    @Test("finishProcessing is no-op when not processing")
    func finishProcessingNoOpWhenNotProcessing() {
        let state = AppState()
        state.finishProcessing()
        #expect(state.recordingState == .idle)
    }

    @Test("Cancel resets to idle from any state")
    func cancelFromAnyState() {
        let state = AppState()

        state.startRecording()
        state.cancel()
        #expect(state.recordingState == .idle)

        state.startRecording()
        state.stopRecording()
        state.cancel()
        #expect(state.recordingState == .idle)
    }

    @Test("Full recording lifecycle")
    func fullLifecycle() {
        let state = AppState()
        #expect(state.recordingState == .idle)

        state.startRecording()
        #expect(state.recordingState == .recording)

        state.stopRecording()
        #expect(state.recordingState == .processing)

        state.finishProcessing()
        #expect(state.recordingState == .idle)
    }

    // MARK: - Recording mode

    @Test("Default recording mode is push-to-talk")
    func defaultModeIsPushToTalk() {
        let state = AppState()
        #expect(state.recordingMode == .pushToTalk)
    }

    @Test("Push-to-talk: hotkey down starts recording")
    func pttHotkeyDownStarts() {
        let state = AppState()
        let started = state.handleHotkeyDown()
        #expect(started == true)
        #expect(state.recordingState == .recording)
    }

    @Test("Push-to-talk: hotkey up stops recording")
    func pttHotkeyUpStops() {
        let state = AppState()
        state.handleHotkeyDown()
        state.handleHotkeyUp()
        #expect(state.recordingState == .processing)
    }

    @Test("Push-to-talk: hotkey up is no-op when not recording")
    func pttHotkeyUpNoOpWhenIdle() {
        let state = AppState()
        state.handleHotkeyUp()
        #expect(state.recordingState == .idle)
    }

    @Test("Toggle mode: first press starts recording")
    func toggleStartsRecording() {
        let state = AppState()
        state.recordingMode = .toggle
        let started = state.handleHotkeyDown()
        #expect(started == true)
        #expect(state.recordingState == .recording)
    }

    @Test("Toggle mode: second press stops recording")
    func toggleStopsRecording() {
        let state = AppState()
        state.recordingMode = .toggle
        state.handleHotkeyDown()
        let started = state.handleHotkeyDown()
        #expect(started == false)
        #expect(state.recordingState == .processing)
    }

    @Test("Toggle mode: hotkey up does nothing")
    func toggleHotkeyUpDoesNothing() {
        let state = AppState()
        state.recordingMode = .toggle
        state.handleHotkeyDown()
        state.handleHotkeyUp()
        #expect(state.recordingState == .recording)
    }
}
