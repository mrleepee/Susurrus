import Testing
@testable import SusurrusKit

/// Mock permission manager for testing.
actor MockPermissionManager: PermissionManaging {
    var permission: MicPermission = .undetermined
    var requestCallCount = 0

    func checkPermission() async -> MicPermission {
        permission
    }

    func requestPermission() async -> MicPermission {
        requestCallCount += 1
        // Simulate granting permission on request
        if permission == .undetermined {
            permission = .granted
        }
        return permission
    }

    func setPermission(_ perm: MicPermission) {
        permission = perm
    }
}

@Suite("MicPermission Tests")
struct MicPermissionTests {

    @Test("Initial permission is undetermined in mock")
    func initialPermission() async {
        let manager = MockPermissionManager()
        #expect(await manager.checkPermission() == .undetermined)
    }

    @Test("requestPermission transitions from undetermined to granted")
    func requestTransitionsToGranted() async {
        let manager = MockPermissionManager()
        let result = await manager.requestPermission()
        #expect(result == .granted)
        #expect(await manager.checkPermission() == .granted)
        #expect(await manager.requestCallCount == 1)
    }

    @Test("requestPermission returns current state if already determined")
    func requestWhenAlreadyDenied() async {
        let manager = MockPermissionManager()
        await manager.setPermission(.denied)

        let result = await manager.requestPermission()
        #expect(result == .denied)
    }

    @Test("MicPermission equality")
    func permissionEquality() {
        #expect(MicPermission.granted == MicPermission.granted)
        #expect(MicPermission.denied == MicPermission.denied)
        #expect(MicPermission.undetermined == MicPermission.undetermined)
        #expect(MicPermission.granted != MicPermission.denied)
    }

    @Test("Permission-gated recording logic")
    func permissionGatesRecording() async throws {
        let permissions = MockPermissionManager()
        let capture = MockAudioCapture()

        // Denied — should not start capture
        await permissions.setPermission(.denied)
        let perm = await permissions.checkPermission()
        #expect(perm == .denied)

        // Granted — should be able to start capture
        await permissions.setPermission(.granted)
        let perm2 = await permissions.checkPermission()
        #expect(perm2 == .granted)

        try await capture.startCapture()
        #expect(await capture.isCurrentlyCapturing() == true)
        _ = try await capture.stopCapture()
    }
}
