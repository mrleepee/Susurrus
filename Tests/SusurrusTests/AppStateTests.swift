import XCTest
@testable import SusurrusKit

@MainActor
final class AppStateTests: XCTestCase {

    /// Helper: creates an AppState with modelReady=true for recording tests.
    private func makeReadyState() -> AppState {
        let state = AppState()
        state.modelReady = true
        return state
    }

    // MARK: - Basic state transitions

    func testInitialStateIsIdle() {
        let state = AppState()
        XCTAssertEqual(state.recordingState, .idle)
    }

    // MARK: - Batch mode

    func testStartRecordingTransitionsFromIdleToRecording() {
        let state = makeReadyState()
        state.startRecording()
        XCTAssertEqual(state.recordingState, .recording)
    }

    func testStartRecordingNoOpWhenModelNotReady() {
        let state = AppState()
        state.modelReady = false
        state.startRecording()
        XCTAssertEqual(state.recordingState, .idle)
    }

    func testStopRecordingTransitionsFromRecordingToProcessing() {
        let state = makeReadyState()
        state.startRecording()
        state.stopRecording()
        XCTAssertEqual(state.recordingState, .processing)
    }

    // MARK: - Streaming mode

    func testStartStreamingTransitionsFromIdleToStreaming() {
        let state = makeReadyState()
        state.startStreaming()
        XCTAssertEqual(state.recordingState, .streaming)
    }

    func testStartStreamingNoOpWhenNotReady() {
        let state = AppState()
        state.modelReady = false
        state.startStreaming()
        XCTAssertEqual(state.recordingState, .idle)
    }

    func testStartStreamingNoOpWhenNotIdle() {
        let state = makeReadyState()
        state.startStreaming()
        state.startStreaming()
        XCTAssertEqual(state.recordingState, .streaming)
    }

    func testStartStreamingResetsInterimText() {
        let state = makeReadyState()
        state.interimText = InterimTranscript(confirmed: "old", unconfirmed: "text", isFinal: false)
        state.startStreaming()
        XCTAssertNil(state.interimText)
    }

    func testStopStreamingTransitionsFromStreamingToFinalizing() {
        let state = makeReadyState()
        state.startStreaming()
        state.stopStreaming()
        XCTAssertEqual(state.recordingState, .finalizing)
    }

    func testStopStreamingNoOpWhenNotStreaming() {
        let state = makeReadyState()
        state.stopStreaming()
        XCTAssertEqual(state.recordingState, .idle)
    }

    func testFinishStreamingReturnsToIdleAndClearsInterimText() {
        let state = makeReadyState()
        state.startStreaming()
        state.stopStreaming()
        state.finishStreaming()
        XCTAssertEqual(state.recordingState, .idle)
        XCTAssertNil(state.interimText)
    }

    func testInterimTextSettable() {
        let state = makeReadyState()
        state.startStreaming()
        let transcript = InterimTranscript(confirmed: "Hello ", unconfirmed: "world", isFinal: false)
        state.interimText = transcript
        XCTAssertEqual(state.interimText?.confirmed, "Hello ")
        XCTAssertEqual(state.interimText?.unconfirmed, "world")
        XCTAssertEqual(state.interimText?.isFinal, false)
    }

    // MARK: - Duration cap

    func testEnforceDurationCapStopsStreaming() {
        let state = makeReadyState()
        state.startStreaming()
        XCTAssertFalse(state.wasDurationCapped)
        let enforced = state.enforceDurationCap()
        XCTAssertTrue(enforced)
        XCTAssertTrue(state.wasDurationCapped)
        XCTAssertEqual(state.recordingState, .finalizing)
    }

    func testEnforceDurationCapNoOpWhenIdle() {
        let state = makeReadyState()
        let enforced = state.enforceDurationCap()
        XCTAssertFalse(enforced)
        XCTAssertFalse(state.wasDurationCapped)
    }

    func testConsumeDurationCappedResetsFlag() {
        let state = makeReadyState()
        state.startStreaming()
        _ = state.enforceDurationCap()
        XCTAssertTrue(state.wasDurationCapped)
        state.consumeDurationCapped()
        XCTAssertFalse(state.wasDurationCapped)
    }

    // MARK: - Hotkey push-to-talk

    func testHotkeyDownStartsStreaming() {
        let state = makeReadyState()
        state.recordingMode = .pushToTalk
        let started = state.handleHotkeyDown()
        XCTAssertTrue(started)
        XCTAssertEqual(state.recordingState, .streaming)
    }

    func testHotkeyUpStopsStreaming() {
        let state = makeReadyState()
        state.recordingMode = .pushToTalk
        state.handleHotkeyDown()
        state.handleHotkeyUp()
        XCTAssertEqual(state.recordingState, .finalizing)
    }

    // MARK: - Hotkey toggle

    func testHotkeyDownToggle() {
        let state = makeReadyState()
        state.recordingMode = .toggle
        let first = state.handleHotkeyDown()
        XCTAssertTrue(first)
        XCTAssertEqual(state.recordingState, .streaming)
        let second = state.handleHotkeyDown()
        XCTAssertFalse(second)
        XCTAssertEqual(state.recordingState, .finalizing)
    }

    // MARK: - Cancel

    func testCancelReturnsToIdleFromAnyState() {
        let state = makeReadyState()
        state.startStreaming()
        state.cancel()
        XCTAssertEqual(state.recordingState, .idle)
        XCTAssertNil(state.interimText)
    }
}
