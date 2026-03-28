import Foundation

/// Represents the current microphone permission state.
public enum MicPermission: Sendable, Equatable {
    case granted
    case denied
    case undetermined
}

/// Protocol for checking/requesting microphone permission.
public protocol PermissionManaging: Sendable {
    /// Check the current microphone permission status.
    func checkPermission() async -> MicPermission

    /// Request microphone permission (shows system dialog if undetermined).
    /// Returns the resulting permission state.
    func requestPermission() async -> MicPermission
}
