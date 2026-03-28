import AppKit
@preconcurrency import Carbon
import Foundation

/// Concrete global hotkey manager using NSEvent global/local monitors.
/// Works for menu bar apps where the app is not typically in the foreground.
public final class GlobalHotkeyService: HotkeyManaging, @unchecked Sendable {

    private var globalKeyDownMonitor: Any?
    private var globalKeyUpMonitor: Any?
    private var localKeyDownMonitor: Any?
    private var localKeyUpMonitor: Any?
    private var registeredFlag = false

    public init() {}

    public func isRegistered() async -> Bool {
        registeredFlag
    }

    public func register(
        combo: HotkeyCombo,
        onKeyDown: @Sendable @escaping () -> Void,
        onKeyUp: @Sendable @escaping () -> Void = {}
    ) async throws {
        await unregister()

        let flags = modifierFlags(combo.modifiers)
        let keyCode = combo.keyCode

        // Global monitors: fire when another app is focused
        globalKeyDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            if self.matches(event: event, keyCode: keyCode, flags: flags) {
                onKeyDown()
            }
        }
        globalKeyUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyUp) { event in
            if self.matches(event: event, keyCode: keyCode, flags: flags) {
                onKeyUp()
            }
        }

        // Local monitors: fire when our app is focused (e.g., preferences window)
        localKeyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if self.matches(event: event, keyCode: keyCode, flags: flags) {
                onKeyDown()
                return nil
            }
            return event
        }
        localKeyUpMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyUp) { event in
            if self.matches(event: event, keyCode: keyCode, flags: flags) {
                onKeyUp()
                return nil
            }
            return event
        }

        registeredFlag = true
    }

    public func unregister() async {
        for monitor in [globalKeyDownMonitor, globalKeyUpMonitor, localKeyDownMonitor, localKeyUpMonitor] {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
        }
        globalKeyDownMonitor = nil
        globalKeyUpMonitor = nil
        localKeyDownMonitor = nil
        localKeyUpMonitor = nil
        registeredFlag = false
    }

    private func matches(event: NSEvent, keyCode: UInt32, flags: NSEvent.ModifierFlags) -> Bool {
        return event.keyCode == UInt16(keyCode) && event.modifierFlags.contains(flags)
    }

    private func modifierFlags(_ raw: UInt32) -> NSEvent.ModifierFlags {
        var flags = NSEvent.ModifierFlags()
        if raw & UInt32(cmdKey) != 0 { flags.insert(.command) }
        if raw & UInt32(shiftKey) != 0 { flags.insert(.shift) }
        if raw & UInt32(optionKey) != 0 { flags.insert(.option) }
        if raw & UInt32(controlKey) != 0 { flags.insert(.control) }
        return flags
    }
}

/// Errors from hotkey management.
public enum HotkeyError: Error, Sendable, Equatable {
    case registrationFailed(String)
}
