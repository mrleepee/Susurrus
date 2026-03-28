import Testing
@testable import SusurrusKit

@MainActor
@Suite("AppState Tests")
struct AppStateTests {

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
        // Already recording — startRecording should be no-op
        state.startRecording()
        state.startRecording()
        #expect(state.recordingState == .recording)

        // In processing state — startRecording should be no-op
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
}
