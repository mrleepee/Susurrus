import Foundation

/// Protocol abstracting audio capture for testability.
/// Real implementation uses AVFoundation; tests inject mocks.
public protocol AudioCapturing: Sendable {
    /// Begin capturing audio from the configured input device.
    func startCapture() async throws

    /// Stop capturing and return the recorded audio buffer (PCM Float32).
    func stopCapture() async throws -> [Float]

    /// Whether audio capture is currently active.
    func isCurrentlyCapturing() async -> Bool
}

/// Errors that can occur during audio capture.
public enum AudioCaptureError: Error, Sendable, Equatable {
    case alreadyCapturing
    case notCapturing
    case noInputDevice
    case permissionDenied
    case engineFailure(String)
}
