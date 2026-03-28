import Testing
@testable import SusurrusKit

@MainActor
@Suite("AppState Tests")
struct AppStateTests {

    /// Helper: creates an AppState with modelReady=true for recording tests.
    private func makeReadyState() -> AppState {
        let state = AppState()
        state.modelReady = true
        return state
    }

    // MARK: - Basic state transitions

    @Test("Initial state is idle")
    func initialStateIsIdle() {
        let state = AppState()
        #expect(state.recordingState == .idle)
    }

    @Test("startRecording transitions from idle to recording")
    func startRecording() {
        let state = makeReadyState()
        state.startRecording()
        #expect(state.recordingState == .recording)
    }

    @Test("startRecording is no-op when model not ready")
    func startRecordingNoOpWhenModelNotReady() {
        let state = AppState()
        state.modelReady = false
        state.startRecording()
        #expect(state.recordingState == .idle)
    }

    @Test("startRecording is no-op when not idle")
    func startRecordingNoOpWhenNotIdle() {
        let state = makeReadyState()
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
        let state = makeReadyState()
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
        let state = makeReadyState()
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
        let state = makeReadyState()

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
        let state = makeReadyState()
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
        let state = makeReadyState()
        let started = state.handleHotkeyDown()
        #expect(started == true)
        #expect(state.recordingState == .recording)
    }

    @Test("Push-to-talk: hotkey up stops recording")
    func pttHotkeyUpStops() {
        let state = makeReadyState()
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
        let state = makeReadyState()
        state.recordingMode = .toggle
        let started = state.handleHotkeyDown()
        #expect(started == true)
        #expect(state.recordingState == .recording)
    }

    @Test("Toggle mode: second press stops recording")
    func toggleStopsRecording() {
        let state = makeReadyState()
        state.recordingMode = .toggle
        state.handleHotkeyDown()
        let started = state.handleHotkeyDown()
        #expect(started == false)
        #expect(state.recordingState == .processing)
    }

    @Test("Toggle mode: hotkey up does nothing")
    func toggleHotkeyUpDoesNothing() {
        let state = makeReadyState()
        state.recordingMode = .toggle
        state.handleHotkeyDown()
        state.handleHotkeyUp()
        #expect(state.recordingState == .recording)
    }

    // MARK: - Duration cap (R9)

    @Test("enforceDurationCap stops recording when recording")
    func durationCapStopsRecording() {
        let state = makeReadyState()
        state.startRecording()
        let capped = state.enforceDurationCap()
        #expect(capped == true)
        #expect(state.recordingState == .processing)
    }

    @Test("enforceDurationCap is no-op when not recording")
    func durationCapNoOpWhenNotRecording() {
        let state = AppState()
        let capped = state.enforceDurationCap()
        #expect(capped == false)
        #expect(state.recordingState == .idle)
    }

    @Test("enforceDurationCap sets wasDurationCapped flag")
    func durationCapSetsFlag() {
        let state = makeReadyState()
        #expect(state.wasDurationCapped == false)

        state.startRecording()
        state.enforceDurationCap()
        #expect(state.wasDurationCapped == true)
    }

    @Test("wasDurationCapped resets on next recording")
    func durationCappedResetsOnNextRecording() {
        let state = makeReadyState()
        state.startRecording()
        state.enforceDurationCap()
        #expect(state.wasDurationCapped == true)

        state.finishProcessing()
        state.startRecording()
        #expect(state.wasDurationCapped == false)
    }

    @Test("Max recording duration is 60 seconds")
    func maxRecordingDuration() {
        #expect(AppState.maxRecordingDuration == 60.0)
    }

    // MARK: - Transcription progress (R14)

    @Test("Transcription progress starts at zero")
    func progressStartsAtZero() {
        let state = AppState()
        #expect(state.transcriptionProgress == 0)
    }

    @Test("Transcription progress can be updated during processing")
    func progressUpdatesDuringProcessing() {
        let state = makeReadyState()
        state.startRecording()
        state.stopRecording()
        #expect(state.recordingState == .processing)

        state.transcriptionProgress = 0.5
        #expect(state.transcriptionProgress == 0.5)

        state.transcriptionProgress = 1.0
        #expect(state.transcriptionProgress == 1.0)
    }

    @Test("finishProcessing resets transcription progress")
    func finishProcessingResetsProgress() {
        let state = makeReadyState()
        state.startRecording()
        state.stopRecording()
        state.transcriptionProgress = 0.75
        state.finishProcessing()
        #expect(state.transcriptionProgress == 0)
    }

    // MARK: - Model readiness

    @Test("Model ready defaults to false")
    func modelReadyDefaultsFalse() {
        let state = AppState()
        #expect(state.modelReady == false)
    }

    @Test("Model load progress defaults to zero")
    func modelLoadProgressDefaultsZero() {
        let state = AppState()
        #expect(state.modelLoadProgress == 0)
    }
}
