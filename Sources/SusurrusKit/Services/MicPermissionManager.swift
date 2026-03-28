import AVFoundation

/// Concrete microphone permission manager using AVFoundation.
public actor MicPermissionManager: PermissionManaging {

    public init() {}

    public func checkPermission() async -> MicPermission {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        return mapStatus(status)
    }

    public func requestPermission() async -> MicPermission {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)

        // Already determined — return current state
        if status != .notDetermined {
            return mapStatus(status)
        }

        // Request permission
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        return granted ? .granted : .denied
    }

    private func mapStatus(_ status: AVAuthorizationStatus) -> MicPermission {
        switch status {
        case .authorized:
            return .granted
        case .denied, .restricted:
            return .denied
        case .notDetermined:
            return .undetermined
        @unknown default:
            return .denied
        }
    }
}
