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

    // MARK: - Batch mode (Phase 7: removed after streaming is wired)

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

    @Test("stopRecording transitions from recording to processing")
    func stopRecording() {
        let state = makeReadyState()
        state.startRecording()
        state.stopRecording()
        #expect(state.recordingState == .processing)
    }

    // MARK: - Streaming mode

    @Test("startStreaming transitions from idle to streaming")
    func startStreaming() {
        let state = makeReadyState()
        state.startStreaming()
        #expect(state.recordingState == .streaming)
    }

    @Test("startStreaming is no-op when model not ready")
    func startStreamingNoOpWhenNotReady() {
        let state = AppState()
        state.modelReady = false
        state.startStreaming()
        #expect(state.recordingState == .idle)
    }

    @Test("startStreaming is no-op when not idle")
    func startStreamingNoOpWhenNotIdle() {
        let state = makeReadyState()
        state.startStreaming()
        state.startStreaming()
        #expect(state.recordingState == .streaming)
    }

    @Test("startStreaming resets interimText")
    func startStreamingResetsInterimText() {
        let state = makeReadyState()
        state.interimText = InterimTranscript(confirmed: "old", unconfirmed: "text", isFinal: false)
        state.startStreaming()
        #expect(state.interimText == nil)
    }

    @Test("stopStreaming transitions from streaming to finalizing")
    func stopStreaming() {
        let state = makeReadyState()
        state.startStreaming()
        state.stopStreaming()
        #expect(state.recordingState == .finalizing)
    }

    @Test("stopStreaming is no-op when not streaming")
    func stopStreamingNoOpWhenNotStreaming() {
        let state = makeReadyState()
        state.stopStreaming()
        #expect(state.recordingState == .idle)
    }

    @Test("finishStreaming returns to idle and clears interimText")
    func finishStreaming() {
        let state = makeReadyState()
        state.startStreaming()
        state.stopStreaming()
        state.finishStreaming()
        #expect(state.recordingState == .idle)
        #expect(state.interimText == nil)
    }

    @Test("interimText can be set during streaming")
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

    @Test("enforceDurationCap sets wasDurationCapped and stops streaming")
    func enforceDurationCapStopsStreaming() {
        let state = makeReadyState()
        state.startStreaming()
        #expect(state.wasDurationCapped == false)
        let enforced = state.enforceDurationCap()
        #expect(enforced == true)
        #expect(state.wasDurationCapped == true)
        #expect(state.recordingState == .finalizing)
    }

    @Test("enforceDurationCap is no-op when idle")
    func enforceDurationCapNoOpWhenIdle() {
        let state = makeReadyState()
        let enforced = state.enforceDurationCap()
        #expect(enforced == false)
        #expect(state.wasDurationCapped == false)
    }

    @Test("consumeDurationCapped resets flag")
    func consumeDurationCapped() {
        let state = makeReadyState()
        state.startStreaming()
        _ = state.enforceDurationCap()
        #expect(state.wasDurationCapped == true)
        state.consumeDurationCapped()
        #expect(state.wasDurationCapped == false)
    }

    // MARK: - Hotkey push-to-talk

    @Test("handleHotkeyDown starts streaming in push-to-talk mode")
    func hotkeyDownStartsStreaming() {
        let state = makeReadyState()
        state.recordingMode = .pushToTalk
        let started = state.handleHotkeyDown()
        #expect(started == true)
        #expect(state.recordingState == .streaming)
    }

    @Test("handleHotkeyUp stops streaming in push-to-talk mode")
    func hotkeyUpStopsStreaming() {
        let state = makeReadyState()
        state.recordingMode = .pushToTalk
        state.handleHotkeyDown()
        state.handleHotkeyUp()
        #expect(state.recordingState == .finalizing)
    }

    // MARK: - Hotkey toggle

    @Test("handleHotkeyDown toggles: idle -> streaming, streaming -> finalizing")
    func hotkeyDownToggle() {
        let state = makeReadyState()
        state.recordingMode = .toggle
        let first = state.handleHotkeyDown()
        #expect(first == true)
        #expect(state.recordingState == .streaming)
        let second = state.handleHotkeyDown()
        #expect(second == false)
        #expect(state.recordingState == .finalizing)
    }

    // MARK: - Cancel

    @Test("cancel returns to idle from any state")
    func cancelFromAnyState() {
        let state = makeReadyState()
        state.startStreaming()
        state.cancel()
        #expect(state.recordingState == .idle)
        #expect(state.interimText == nil)
    }
}
