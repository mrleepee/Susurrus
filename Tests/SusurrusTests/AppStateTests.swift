import Testing
@testable import SusurrusKit

@Suite("AppState Tests")
@MainActor
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

    // MARK: - Batch mode

    @Test("Start recording transitions from idle to recording")
    func startRecordingTransitions() {
        let state = makeReadyState()
        state.startRecording()
        #expect(state.recordingState == .recording)
    }

    @Test("Start recording no-op when model not ready")
    func startRecordingNoOpWhenNotReady() {
        let state = AppState()
        state.modelReady = false
        state.startRecording()
        #expect(state.recordingState == .idle)
    }

    @Test("Stop recording transitions from recording to processing")
    func stopRecordingTransitions() {
        let state = makeReadyState()
        state.startRecording()
        state.stopRecording()
        #expect(state.recordingState == .processing)
    }

    // MARK: - Streaming mode

    @Test("Start streaming transitions from idle to streaming")
    func startStreamingTransitions() {
        let state = makeReadyState()
        state.startStreaming()
        #expect(state.recordingState == .streaming)
    }

    @Test("Start streaming no-op when not ready")
    func startStreamingNoOpWhenNotReady() {
        let state = AppState()
        state.modelReady = false
        state.startStreaming()
        #expect(state.recordingState == .idle)
    }

    @Test("Start streaming no-op when not idle")
    func startStreamingNoOpWhenNotIdle() {
        let state = makeReadyState()
        state.startStreaming()
        state.startStreaming()
        #expect(state.recordingState == .streaming)
    }

    @Test("Start streaming resets interim text")
    func startStreamingResetsInterimText() {
        let state = makeReadyState()
        state.interimText = InterimTranscript(confirmed: "old", unconfirmed: "text", isFinal: false)
        state.startStreaming()
        #expect(state.interimText == nil)
    }

    @Test("Stop streaming transitions from streaming to finalizing")
    func stopStreamingTransitions() {
        let state = makeReadyState()
        state.startStreaming()
        state.stopStreaming()
        #expect(state.recordingState == .finalizing)
    }

    @Test("Stop streaming no-op when not streaming")
    func stopStreamingNoOpWhenNotStreaming() {
        let state = makeReadyState()
        state.stopStreaming()
        #expect(state.recordingState == .idle)
    }

    @Test("Finish streaming returns to idle and clears interim text")
    func finishStreamingReturnsToIdle() {
        let state = makeReadyState()
        state.startStreaming()
        state.stopStreaming()
        state.finishStreaming()
        #expect(state.recordingState == .idle)
        #expect(state.interimText == nil)
    }

    @Test("Interim text settable")
    func interimTextSettable() {
        let state = makeReadyState()
        state.startStreaming()
        let transcript = InterimTranscript(confirmed: "Hello ", unconfirmed: "world", isFinal: false)
        state.interimText = transcript
        #expect(state.interimText?.confirmed == "Hello ")
        #expect(state.interimText?.unconfirmed == "world")
        #expect(state.interimText?.isFinal == false)
    }

    // MARK: - Duration cap

    @Test("Enforce duration cap stops streaming")
    func enforceDurationCapStopsStreaming() {
        let state = makeReadyState()
        state.startStreaming()
        #expect(!state.wasDurationCapped)
        let enforced = state.enforceDurationCap()
        #expect(enforced)
        #expect(state.wasDurationCapped)
        #expect(state.recordingState == .finalizing)
    }

    @Test("Enforce duration cap no-op when idle")
    func enforceDurationCapNoOpWhenIdle() {
        let state = makeReadyState()
        let enforced = state.enforceDurationCap()
        #expect(!enforced)
        #expect(!state.wasDurationCapped)
    }

    @Test("Consume duration capped resets flag")
    func consumeDurationCappedResetsFlag() {
        let state = makeReadyState()
        state.startStreaming()
        _ = state.enforceDurationCap()
        #expect(state.wasDurationCapped)
        state.consumeDurationCapped()
        #expect(!state.wasDurationCapped)
    }

    // MARK: - Hotkey push-to-talk

    @Test("Hotkey down starts streaming in push-to-talk")
    func hotkeyDownStartsStreaming() {
        let state = makeReadyState()
        state.recordingMode = .pushToTalk
        let started = state.handleHotkeyDown()
        #expect(started)
        #expect(state.recordingState == .streaming)
    }

    @Test("Hotkey up stops streaming in push-to-talk")
    func hotkeyUpStopsStreaming() {
        let state = makeReadyState()
        state.recordingMode = .pushToTalk
        state.handleHotkeyDown()
        state.handleHotkeyUp()
        #expect(state.recordingState == .finalizing)
    }

    // MARK: - Hotkey toggle

    @Test("Hotkey toggle starts then stops")
    func hotkeyDownToggle() {
        let state = makeReadyState()
        state.recordingMode = .toggle
        let first = state.handleHotkeyDown()
        #expect(first)
        #expect(state.recordingState == .streaming)
        let second = state.handleHotkeyDown()
        #expect(!second)
        #expect(state.recordingState == .finalizing)
    }

    // MARK: - Cancel

    @Test("Cancel returns to idle from any state")
    func cancelReturnsToIdle() {
        let state = makeReadyState()
        state.startStreaming()
        state.cancel()
        #expect(state.recordingState == .idle)
        #expect(state.interimText == nil)
    }
}
