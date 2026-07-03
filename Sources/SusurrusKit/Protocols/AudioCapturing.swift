import Foundation

/// Protocol abstracting audio capture for testability.
/// Real implementation uses AVFoundation; tests inject mocks.
public protocol AudioCapturing: Sendable {
    /// Begin capturing audio from a specific input device.
    ///
    /// - Parameter deviceID: Core Audio input device ID, or `nil` for system default.
    func startCapture(deviceID: UInt32?) async throws

    /// Stop capturing and return the recorded audio buffer (PCM Float32).
    func stopCapture() async throws -> [Float]

    /// Whether audio capture is currently active.
    func isCurrentlyCapturing() async -> Bool
}

public extension AudioCapturing {
    /// Convenience overload — captures from the system default input device.
    func startCapture() async throws {
        try await startCapture(deviceID: nil)
    }
}

/// Errors that can occur during audio capture.
public enum AudioCaptureError: Error, Sendable, Equatable {
    case alreadyCapturing
    case notCapturing
    case noInputDevice
    case permissionDenied
    case engineFailure(String)
}
