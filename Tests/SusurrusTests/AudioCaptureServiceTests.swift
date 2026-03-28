import Testing
@testable import SusurrusKit

/// Mock audio capture for testing without hardware.
actor MockAudioCapture: AudioCapturing {
    var capturing = false
    var mockBuffer: [Float] = []
    var startCallCount = 0
    var stopCallCount = 0

    func isCurrentlyCapturing() async -> Bool {
        capturing
    }

    func startCapture() async throws {
        if capturing {
            throw AudioCaptureError.alreadyCapturing
        }
        capturing = true
        startCallCount += 1
    }

    func stopCapture() async throws -> [Float] {
        if !capturing {
            throw AudioCaptureError.notCapturing
        }
        capturing = false
        stopCallCount += 1
        return mockBuffer
    }

    func setMockBuffer(_ buffer: [Float]) {
        mockBuffer = buffer
    }
}

@Suite("AudioCapture Tests")
struct AudioCaptureTests {

    @Test("Start and stop capture lifecycle via mock")
    func startStopLifecycle() async throws {
        let capture = MockAudioCapture()
        #expect(await capture.isCurrentlyCapturing() == false)

        try await capture.startCapture()
        #expect(await capture.isCurrentlyCapturing() == true)
        #expect(await capture.startCallCount == 1)

        let buffer = try await capture.stopCapture()
        #expect(await capture.isCurrentlyCapturing() == false)
        #expect(await capture.stopCallCount == 1)
        #expect(buffer.isEmpty)
    }

    @Test("startCapture throws when already capturing")
    func doubleStartThrows() async throws {
        let capture = MockAudioCapture()
        try await capture.startCapture()

        do {
            try await capture.startCapture()
            #expect(Bool(false), "Should have thrown")
        } catch let error as AudioCaptureError {
            #expect(error == .alreadyCapturing)
        }
    }

    @Test("stopCapture throws when not capturing")
    func stopWithoutStartThrows() async throws {
        let capture = MockAudioCapture()

        do {
            _ = try await capture.stopCapture()
            #expect(Bool(false), "Should have thrown")
        } catch let error as AudioCaptureError {
            #expect(error == .notCapturing)
        }
    }

    @Test("stopCapture returns configured mock buffer")
    func returnsMockBuffer() async throws {
        let capture = MockAudioCapture()
        await capture.setMockBuffer([0.1, 0.2, 0.3, 0.4, 0.5])

        try await capture.startCapture()
        let buffer = try await capture.stopCapture()

        #expect(buffer == [0.1, 0.2, 0.3, 0.4, 0.5])
    }

    @Test("Multiple start/stop cycles work correctly")
    func multipleCycles() async throws {
        let capture = MockAudioCapture()

        for i in 0..<3 {
            await capture.setMockBuffer([Float(i)])
            try await capture.startCapture()
            let buffer = try await capture.stopCapture()
            #expect(buffer == [Float(i)])
        }

        #expect(await capture.startCallCount == 3)
        #expect(await capture.stopCallCount == 3)
    }

    @Test("AudioCaptureError equality")
    func errorEquality() {
        #expect(AudioCaptureError.alreadyCapturing == AudioCaptureError.alreadyCapturing)
        #expect(AudioCaptureError.notCapturing == AudioCaptureError.notCapturing)
        #expect(AudioCaptureError.alreadyCapturing != AudioCaptureError.notCapturing)
        #expect(AudioCaptureError.engineFailure("x") == AudioCaptureError.engineFailure("x"))
    }
}
