import AppKit
@preconcurrency import Carbon
import Foundation

/// Concrete global hotkey manager using NSEvent global/local monitors.
/// Works for menu bar apps where the app is not typically in the foreground.
public final class GlobalHotkeyService: HotkeyManaging, @unchecked Sendable {

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var registeredFlag = false
    private var currentCombo: HotkeyCombo?

    public init() {}

    public func isRegistered() async -> Bool {
        registeredFlag
    }

    public func register(combo: HotkeyCombo, handler: @Sendable @escaping () -> Void) async throws {
        await unregister()

        currentCombo = combo
        let flags = modifierFlags(combo.modifiers)

        // Global monitor: fires when another app is focused
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            if self.matches(event: event, keyCode: combo.keyCode, flags: flags) {
                handler()
            }
        }

        // Local monitor: fires when our app is focused (e.g., preferences window)
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if self.matches(event: event, keyCode: combo.keyCode, flags: flags) {
                handler()
                return nil // consume the event
            }
            return event
        }

        registeredFlag = true
    }

    public func unregister() async {
        if let monitor = globalMonitor {
            NSEvent.removeMonitor(monitor)
            globalMonitor = nil
        }
        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
            localMonitor = nil
        }
        currentCombo = nil
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
