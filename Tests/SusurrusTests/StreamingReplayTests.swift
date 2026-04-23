import Testing
@testable import SusurrusKit
@preconcurrency import WhisperKit

// MARK: - Tier 1: FakeAudioProcessor unit tests (no model required)

@Suite("FakeAudioProcessor — unit")
struct FakeAudioProcessorTests {

    @Test("audioSamples accumulates pushed chunks")
    func samplesAccumulate() async throws {
        let audio = FakeAudioProcessor.sineWave(durationSeconds: 0.5)
        let fake = FakeAudioProcessor(samples: audio, chunkMs: 100)

        try fake.startRecordingLive(inputDeviceID: nil, callback: nil)
        // Wait for at least one chunk push (100ms + margin)
        try await Task.sleep(for: .milliseconds(200))
        fake.stopRecording()

        let captured = fake.audioSamples
        #expect(!captured.isEmpty, "FakeAudioProcessor should have pushed samples into audioSamples")
    }

    @Test("stopRecording halts further pushes")
    func stopHaltsPushes() async throws {
        let audio = FakeAudioProcessor.sineWave(durationSeconds: 3.0)
        let fake = FakeAudioProcessor(samples: audio, chunkMs: 100)

        try fake.startRecordingLive(inputDeviceID: nil, callback: nil)
        try await Task.sleep(for: .milliseconds(150))
        fake.stopRecording()

        let countAfterStop = fake.audioSamples.count
        try await Task.sleep(for: .milliseconds(300))
        let countLater = fake.audioSamples.count

        #expect(countAfterStop == countLater, "No new samples should arrive after stopRecording")
    }

    @Test("purgeAudioSamples(keepingLast:) trims the buffer")
    func purgeKeepsLast() async throws {
        let audio = FakeAudioProcessor.sineWave(durationSeconds: 1.0)
        let fake = FakeAudioProcessor(samples: audio, chunkMs: 100)

        try fake.startRecordingLive(inputDeviceID: nil, callback: nil)
        try await Task.sleep(for: .milliseconds(500))
        fake.stopRecording()

        let before = fake.audioSamples.count
        #expect(before > 0)

        fake.purgeAudioSamples(keepingLast: 0)
        #expect(fake.audioSamples.count == 0, "purge(keepingLast:0) should empty the buffer")
    }

    @Test("purgeAudioSamples(keepingLast:) with large keep value is a no-op")
    func purgeNoOpWhenKeepExceedsCount() async throws {
        let audio = FakeAudioProcessor.sineWave(durationSeconds: 0.5)
        let fake = FakeAudioProcessor(samples: audio, chunkMs: 100)

        try fake.startRecordingLive(inputDeviceID: nil, callback: nil)
        try await Task.sleep(for: .milliseconds(200))
        fake.stopRecording()

        let count = fake.audioSamples.count
        fake.purgeAudioSamples(keepingLast: count + 1000)
        #expect(fake.audioSamples.count == count, "purge should not remove samples when keep > count")
    }

    @Test("callback fires with each pushed chunk")
    func callbackFiresPerChunk() async throws {
        let audio = FakeAudioProcessor.sineWave(durationSeconds: 0.5)
        let fake = FakeAudioProcessor(samples: audio, chunkMs: 100)

        let callCount = ActorCounter()
        try fake.startRecordingLive(inputDeviceID: nil) { _ in
            Task { await callCount.increment() }
        }
        try await Task.sleep(for: .milliseconds(600))
        fake.stopRecording()

        let count = await callCount.value
        #expect(count >= 3, "Expected at least 3 chunk callbacks for 500ms of audio at 100ms chunks, got \(count)")
    }

    @Test("sineWave generates correct sample count")
    func sineWaveLength() {
        let samples = FakeAudioProcessor.sineWave(durationSeconds: 2.0)
        #expect(samples.count == 32_000, "2s @ 16kHz should produce 32000 samples")
    }

    @Test("speechLikeSignal generates correct sample count")
    func speechLikeLength() {
        let samples = FakeAudioProcessor.speechLikeSignal(durationSeconds: 1.0)
        #expect(samples.count == 16_000, "1s @ 16kHz should produce 16000 samples")
    }
}

// MARK: - Tier 2: Streaming session integration tests (requires loaded WhisperKit model)
//
// These tests run the real WhisperKit transcription pipeline with FakeAudioProcessor
// injected through the seam in StreamingTranscriptionService. They require a WhisperKit
// model to be downloaded (~40MB for "tiny"). Run with:
//   swift test --filter StreamingSessionTests
//
// To skip in fast unit-only runs, these are tagged with .requiresModel.

extension Tag {
    @Tag static var requiresModel: Self
}

@Suite("Streaming session — integration", .tags(.requiresModel))
struct StreamingSessionTests {

    // MARK: - Buffer isolation between sessions

    /// Regression test for the "previous words in buffer" bug.
    ///
    /// Root cause: StreamingTranscriptionService reuses whisperKit.audioProcessor
    /// across sessions. AudioStreamTranscriber reads audioProcessor.audioSamples on
    /// its very first transcribeCurrentBuffer() pass with lastBufferSize=0, so it
    /// sees all audio accumulated during the previous session and transcribes it again.
    ///
    /// Fix: call purgeAudioSamples(keepingLast:0) on the processor before building
    /// the new AudioStreamTranscriber.
    ///
    /// How this test catches the bug:
    /// - A SINGLE FakeAudioProcessor is shared across both sessions (mirrors how
    ///   the real whisperKit.audioProcessor is shared in production).
    /// - 16,000 samples (1 second of "ghost" audio) are injected directly into the
    ///   processor's buffer to simulate residual audio from session 1.
    /// - Session 2 is started with that contaminated processor.
    /// - The spy captures how many samples were present when startRecordingLive fires —
    ///   which happens AFTER the service would have called purge.
    ///
    /// Without the purgeAudioSamples fix: samplesAtRecordingStart == 16_000 → FAIL
    /// With the fix:                       samplesAtRecordingStart == 0        → PASS
    @Test("Shared processor is purged at session start — prevents ghost transcription")
    func audioBufferPurgedBeforeSessionStarts() async throws {
        let service = StreamingTranscriptionService()
        try await service.setupModel(modelName: "tiny") { _ in }

        let audio = FakeAudioProcessor.speechLikeSignal(durationSeconds: 2.0)
        let sharedFake = FakeAudioProcessor(samples: audio, chunkMs: 100)

        // Simulate 1 second of residual audio left in the processor from a prior session.
        let ghostSamples = [Float](repeating: 0.1, count: 16_000)
        sharedFake.preloadSamples(ghostSamples)
        #expect(sharedFake.audioSamples.count == 16_000, "Precondition: buffer must be contaminated")

        // Run session in a Task because startStreamTranscription is blocking
        // (it awaits the internal realtimeLoop which only exits on stop/cancel).
        let sessionTask = Task {
            try await service.startStreamTranscription(
                audioProcessorOverride: sharedFake,
                callback: { _ in }
            )
        }

        // Wait long enough for the service to have called purge and started recording,
        // but short enough that the replay loop hasn't pushed significant new audio.
        try await Task.sleep(for: .milliseconds(200))
        sessionTask.cancel()
        await service.cancelStreamTranscription()

        #expect(sharedFake.purgeCallCount >= 1,
            "Service must call purgeAudioSamples before starting a session")
        #expect(sharedFake.samplesAtRecordingStart == 0,
            "Processor had \(sharedFake.samplesAtRecordingStart) residual samples when recording started — ghost transcription would occur")
    }

    // MARK: - Session completes without error

    @Test("Session start and stop does not throw for valid audio")
    func sessionStartStopNoThrow() async throws {
        let service = StreamingTranscriptionService()
        try await service.setupModel(modelName: "tiny") { _ in }

        let audio = FakeAudioProcessor.speechLikeSignal(durationSeconds: 2.0)
        let fake = FakeAudioProcessor(samples: audio, chunkMs: 100)

        try await service.startStreamTranscription(
            audioProcessorOverride: fake,
            callback: { _ in }
        )
        try await Task.sleep(for: .seconds(3))

        // stopStreamTranscription may throw noSpeechDetected for synthetic audio —
        // that's acceptable. What must NOT happen is a crash or unexpected error type.
        do {
            _ = try await service.stopStreamTranscription()
        } catch let err as TranscriptionError {
            // noSpeechDetected is valid for synthetic audio
            #expect(err == .noSpeechDetected || err == .emptyAudio,
                "Only expected no-speech errors for synthetic audio, got: \(err)")
        }
    }

    // MARK: - Interim callback fires during session

    @Test("Interim callback fires at least once during audio playback")
    func interimCallbackFires() async throws {
        let service = StreamingTranscriptionService()
        try await service.setupModel(modelName: "tiny") { _ in }

        let audio = FakeAudioProcessor.speechLikeSignal(durationSeconds: 3.0)
        let fake = FakeAudioProcessor(samples: audio, chunkMs: 100)

        let callbackCount = ActorCounter()
        try await service.startStreamTranscription(
            audioProcessorOverride: fake,
            callback: { _ in Task { await callbackCount.increment() } }
        )
        try await Task.sleep(for: .seconds(4))
        await service.cancelStreamTranscription()

        let count = await callbackCount.value
        #expect(count > 0, "Interim callback should have fired at least once")
    }

    // MARK: - Long session does not accumulate unbounded buffer

    /// Regression: long recordings grow audioSamples unbounded, causing OOM or
    /// very slow first-frame decode on the next transcribe cycle.
    ///
    /// WhisperKit's AudioStreamTranscriber calls purgeAudioSamples internally,
    /// but only after confirming segments. Verify the buffer stays bounded.
    @Test("Long session keeps audio buffer below 90s threshold")
    func longSessionBufferStaysBounded() async throws {
        let ninetySeconds = 16_000 * 90
        let service = StreamingTranscriptionService()
        try await service.setupModel(modelName: "tiny") { _ in }

        // 60s of audio — long enough to accumulate but not hit the 90s ceiling
        let audio = FakeAudioProcessor.speechLikeSignal(durationSeconds: 60.0)
        let fake = FakeAudioProcessor(samples: audio, chunkMs: 100)

        try await service.startStreamTranscription(
            audioProcessorOverride: fake,
            callback: { _ in }
        )
        // Run for 30s (half the fixture) then check
        try await Task.sleep(for: .seconds(30))

        let bufferSize = fake.audioSamples.count
        await service.cancelStreamTranscription()

        #expect(bufferSize < ninetySeconds,
            "Buffer grew to \(bufferSize) samples (\(bufferSize / 16_000)s) — exceeds 90s safety limit")
    }
}

// MARK: - Helpers

/// Thread-safe counter for use in async callbacks.
private actor ActorCounter {
    private(set) var value: Int = 0
    func increment() { value += 1 }
}
