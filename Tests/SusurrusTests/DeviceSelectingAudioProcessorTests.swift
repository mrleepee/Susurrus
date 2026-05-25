import Testing
@testable import SusurrusKit
@preconcurrency import WhisperKit

/// Unit tests for `DeviceSelectingAudioProcessor` — verifies the wrapper substitutes
/// the preferred device ID before delegating to the inner `AudioProcessing`.
///
/// These tests do NOT require a WhisperKit model. They use `FakeAudioProcessor` as the
/// inner processor and read its `lastRecordingDeviceID` spy to confirm routing.
@Suite("DeviceSelectingAudioProcessor — device routing")
struct DeviceSelectingAudioProcessorTests {

    private func makeWrapper(
        preferredDeviceID: DeviceID?
    ) -> (DeviceSelectingAudioProcessor, FakeAudioProcessor) {
        let inner = FakeAudioProcessor(samples: FakeAudioProcessor.sineWave(durationSeconds: 0.1))
        let wrapper = DeviceSelectingAudioProcessor(preferredDeviceID: preferredDeviceID, inner: inner)
        return (wrapper, inner)
    }

    // MARK: - startRecordingLive routing

    @Test("startRecordingLive(nil) is replaced by preferredDeviceID when set")
    func preferredIDOverridesNilCaller() throws {
        let (wrapper, inner) = makeWrapper(preferredDeviceID: 42)

        try wrapper.startRecordingLive(inputDeviceID: nil, callback: nil)
        defer { wrapper.stopRecording() }

        #expect(inner.lastRecordingDeviceID == 42,
            "Preferred device ID should replace caller's nil (got \(inner.lastRecordingDeviceID ?? 0))")
    }

    @Test("startRecordingLive uses caller's ID when no preferredDeviceID")
    func callerIDUsedWhenNoPreferredID() throws {
        let (wrapper, inner) = makeWrapper(preferredDeviceID: nil)

        try wrapper.startRecordingLive(inputDeviceID: 99, callback: nil)
        defer { wrapper.stopRecording() }

        #expect(inner.lastRecordingDeviceID == 99,
            "With no preferred ID, caller's value should pass through (got \(inner.lastRecordingDeviceID ?? 0))")
    }

    @Test("preferredDeviceID wins over caller's explicit ID")
    func preferredIDWinsOverCallerID() throws {
        // AudioStreamTranscriber always passes nil, but if future WhisperKit versions
        // pass a non-nil ID we still want user preference to win.
        let (wrapper, inner) = makeWrapper(preferredDeviceID: 42)

        try wrapper.startRecordingLive(inputDeviceID: 99, callback: nil)
        defer { wrapper.stopRecording() }

        #expect(inner.lastRecordingDeviceID == 42,
            "User preference should override any caller-supplied device ID")
    }

    @Test("nil preferredDeviceID and nil caller ID both remain nil (system default)")
    func bothNilRemainsNil() throws {
        let (wrapper, inner) = makeWrapper(preferredDeviceID: nil)

        try wrapper.startRecordingLive(inputDeviceID: nil, callback: nil)
        defer { wrapper.stopRecording() }

        #expect(inner.lastRecordingDeviceID == nil,
            "No preferred and no caller ID must remain nil (system default)")
    }

    // MARK: - resumeRecordingLive routing

    @Test("resumeRecordingLive also substitutes preferredDeviceID")
    func resumeAppliesPreferredID() throws {
        let (wrapper, inner) = makeWrapper(preferredDeviceID: 7)

        try wrapper.resumeRecordingLive(inputDeviceID: nil, callback: nil)
        defer { wrapper.stopRecording() }

        #expect(inner.lastRecordingDeviceID == 7,
            "resume must apply the same substitution as start — otherwise pause/resume loses the device")
    }

    // MARK: - Delegation

    @Test("purgeAudioSamples forwards to inner processor")
    func purgeDelegates() {
        let (wrapper, inner) = makeWrapper(preferredDeviceID: nil)
        #expect(inner.purgeCallCount == 0)

        wrapper.purgeAudioSamples(keepingLast: 0)

        #expect(inner.purgeCallCount == 1,
            "Wrapper must forward purgeAudioSamples — otherwise session isolation breaks")
    }

    @Test("audioSamples and relativeEnergy reflect inner state")
    func gettersDelegate() {
        let (wrapper, inner) = makeWrapper(preferredDeviceID: nil)
        inner.preloadSamples([1, 2, 3, 4])

        #expect(wrapper.audioSamples.count == 4)
    }

    @Test("relativeEnergyWindow is a read/write pass-through")
    func relativeEnergyWindowSetter() {
        let (wrapper, inner) = makeWrapper(preferredDeviceID: nil)
        wrapper.relativeEnergyWindow = 50
        #expect(inner.relativeEnergyWindow == 50)
        #expect(wrapper.relativeEnergyWindow == 50)
    }
}
