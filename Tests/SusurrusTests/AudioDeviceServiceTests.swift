import Foundation
import Testing
@testable import SusurrusKit

@Suite("AudioDeviceService — name resolution")
struct AudioDeviceServiceTests {

    private let fixtureDevices: [AudioInputDevice] = [
        AudioInputDevice(id: 42, name: "Studio Display Microphone"),
        AudioInputDevice(id: 91, name: "MacBook Pro Microphone"),
        AudioInputDevice(id: 73, name: "AirPods Pro"),
    ]

    private func makeService(devices: [AudioInputDevice]? = nil) -> AudioDeviceService {
        let list = devices ?? fixtureDevices
        return AudioDeviceService(devicesProvider: { list })
    }

    // MARK: - availableInputs

    @Test("availableInputs returns the provider's list verbatim")
    func availableInputsMirrorsProvider() {
        let service = makeService()
        let devices = service.availableInputs()
        #expect(devices.count == 3)
        #expect(devices.map(\.name) == ["Studio Display Microphone", "MacBook Pro Microphone", "AirPods Pro"])
    }

    @Test("availableInputs reflects provider updates on each call")
    func providerIsCalledEachTime() {
        var current = [AudioInputDevice(id: 1, name: "A")]
        let service = AudioDeviceService(devicesProvider: { current })
        #expect(service.availableInputs().map(\.name) == ["A"])

        current = [AudioInputDevice(id: 1, name: "A"), AudioInputDevice(id: 2, name: "B")]
        #expect(service.availableInputs().map(\.name) == ["A", "B"])
    }

    // MARK: - resolve

    @Test("resolve(nil) returns .systemDefault")
    func resolveNilIsSystemDefault() {
        let service = makeService()
        #expect(service.resolve(preferredName: nil) == .systemDefault)
    }

    @Test("resolve(emptyString) returns .systemDefault")
    func resolveEmptyStringIsSystemDefault() {
        let service = makeService()
        #expect(service.resolve(preferredName: "") == .systemDefault)
    }

    @Test("resolve returns .specific when name matches an available device")
    func resolveMatchingName() {
        let service = makeService()
        let result = service.resolve(preferredName: "AirPods Pro")
        #expect(result == .specific(id: 73, name: "AirPods Pro"))
    }

    @Test("resolve matches are case-sensitive (Core Audio names are stable strings)")
    func resolveIsCaseSensitive() {
        let service = makeService()
        let result = service.resolve(preferredName: "airpods pro")
        #expect(result == .unavailable(requestedName: "airpods pro"))
    }

    @Test("resolve returns .unavailable when preferred device is disconnected")
    func resolveMissingDevice() {
        let service = makeService()
        let result = service.resolve(preferredName: "USB Microphone")
        #expect(result == .unavailable(requestedName: "USB Microphone"))
    }

    @Test("resolve re-enumerates devices on every call (device hot-plug)")
    func resolveRespectsLiveDeviceList() {
        var current = fixtureDevices
        let service = AudioDeviceService(devicesProvider: { current })

        // Initially present
        #expect(service.resolve(preferredName: "AirPods Pro") == .specific(id: 73, name: "AirPods Pro"))

        // User unplugs the headset — subsequent resolve must report unavailable
        current.removeAll { $0.name == "AirPods Pro" }
        #expect(service.resolve(preferredName: "AirPods Pro") == .unavailable(requestedName: "AirPods Pro"))
    }

    @Test("resolve returns first match when device names collide")
    func resolveFirstOnNameCollision() {
        // Core Audio can (rarely) report duplicate names after reconnection.
        // Service must not crash; it returns the first match.
        let duplicates = [
            AudioInputDevice(id: 10, name: "Shared Mic"),
            AudioInputDevice(id: 11, name: "Shared Mic"),
        ]
        let service = makeService(devices: duplicates)
        let result = service.resolve(preferredName: "Shared Mic")
        #expect(result == .specific(id: 10, name: "Shared Mic"))
    }

    // MARK: - AudioDeviceResolution equality

    @Test("AudioDeviceResolution equality distinguishes case variants")
    func resolutionEquality() {
        #expect(AudioDeviceResolution.systemDefault == .systemDefault)
        #expect(AudioDeviceResolution.specific(id: 1, name: "A") == .specific(id: 1, name: "A"))
        #expect(AudioDeviceResolution.specific(id: 1, name: "A") != .specific(id: 2, name: "A"))
        #expect(AudioDeviceResolution.unavailable(requestedName: "X") == .unavailable(requestedName: "X"))
        #expect(AudioDeviceResolution.systemDefault != .unavailable(requestedName: "X"))
    }
}
