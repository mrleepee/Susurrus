import AppKit
@preconcurrency import Carbon
import Foundation
import os.log

/// Errors from hotkey management.
public enum HotkeyError: Error, Sendable, Equatable {
    /// Carbon registration failed with a description.
    case registrationFailed(String)
}

/// Concrete global hotkey manager using Carbon RegisterEventHotKey.
///
/// Uses the Carbon hotkey API which registers system-level hotkeys that work
/// without any special permissions (unlike NSEvent global monitors which
/// require Input Monitoring permission on macOS 10.15+).
///
/// Carbon fires through the application event target, so a single registration
/// is sufficient regardless of which app window is focused. No local NSEvent
/// monitors are needed — that was the source of duplicate delivery in toggle mode.
public final class GlobalHotkeyService: HotkeyManaging, @unchecked Sendable {

    private nonisolated(unsafe) var carbonHotKeyRef: EventHotKeyRef?
    private nonisolated(unsafe) var carbonHandlerRef: EventHandlerRef?
    private nonisolated(unsafe) var registeredFlag = false
    private nonisolated(unsafe) var onKeyDownCallback: (@Sendable () -> Void)?
    private nonisolated(unsafe) var onKeyUpCallback: (@Sendable () -> Void)?
    private nonisolated(unsafe) var currentComboDesc: String = ""

    /// Four-character code "Susr" used as the Carbon hotkey signature.
    private static let hotKeySignature: FourCharCode =
        (FourCharCode(0x53) << 24) | (FourCharCode(0x75) << 16) |
        (FourCharCode(0x73) << 8) | FourCharCode(0x72)

    private static let logger = Logger(subsystem: "com.susurrus.app", category: "Hotkey")

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

        onKeyDownCallback = onKeyDown
        onKeyUpCallback = onKeyUp
        currentComboDesc = describeCombo(combo)

        print("[Hotkey] Registering Carbon hotkey: \(currentComboDesc) (keyCode=0x\(String(combo.keyCode, radix: 16)), carbonMods=0x\(String(combo.modifiers, radix: 16)))")
        Self.logger.info("Registering Carbon hotkey: \(self.currentComboDesc)")

        // Carbon APIs must be called on the main thread
        try await MainActor.run { [self] in
            // Remove old handler
            if let carbonHandlerRef {
                RemoveEventHandler(carbonHandlerRef)
                self.carbonHandlerRef = nil
            }

            // Install Carbon event handler for hotkey press/release
            var eventTypes = [
                EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
            ]
            let userData = Unmanaged.passUnretained(self).toOpaque()

            var handlerRef: EventHandlerRef?
            let installStatus = InstallEventHandler(
                GetApplicationEventTarget(),
                Self.carbonEventHandlerCallback,
                2,
                &eventTypes,
                userData,
                &handlerRef
            )
            guard installStatus == noErr, let handlerRef else {
                Self.logger.error("InstallEventHandler failed: \(installStatus)")
                throw HotkeyError.registrationFailed("InstallEventHandler returned \(installStatus)")
            }
            self.carbonHandlerRef = handlerRef
            print("[Hotkey] InstallEventHandler status: \(installStatus)")

            // Register the system-level hotkey
            var hotKeyID = EventHotKeyID()
            hotKeyID.signature = Self.hotKeySignature
            hotKeyID.id = 1

            var ref: EventHotKeyRef?
            let regStatus = RegisterEventHotKey(
                combo.keyCode,
                combo.modifiers,
                hotKeyID,
                GetApplicationEventTarget(),
                0,
                &ref
            )
            guard regStatus == noErr else {
                // Tear down the event handler we just installed
                RemoveEventHandler(handlerRef)
                self.carbonHandlerRef = nil
                Self.logger.error("RegisterEventHotKey failed: \(regStatus)")
                throw HotkeyError.registrationFailed("RegisterEventHotKey returned \(regStatus)")
            }
            carbonHotKeyRef = ref
            print("[Hotkey] RegisterEventHotKey status: \(regStatus)")
        }

        registeredFlag = true
        print("[Hotkey] Registration complete")
        Self.logger.info("Carbon hotkey registered successfully")
    }

    public func unregister() async {
        await MainActor.run { [self] in
            if let carbonHotKeyRef {
                UnregisterEventHotKey(carbonHotKeyRef)
                self.carbonHotKeyRef = nil
            }
            if let carbonHandlerRef {
                RemoveEventHandler(carbonHandlerRef)
                self.carbonHandlerRef = nil
            }
        }
        onKeyDownCallback = nil
        onKeyUpCallback = nil
        registeredFlag = false
    }

    // MARK: - Carbon Event Handler

    /// C function pointer callback for Carbon hotkey events.
    /// Uses userData to recover the GlobalHotkeyService instance.
    private static let carbonEventHandlerCallback: EventHandlerUPP = { _, event, userData in
        guard let userData else { return OSStatus(eventNotHandledErr) }
        let service = Unmanaged<GlobalHotkeyService>.fromOpaque(userData).takeUnretainedValue()

        let kind = GetEventKind(event)
        switch kind {
        case UInt32(kEventHotKeyPressed):
            print("[Hotkey] Carbon hotkey pressed: \(service.currentComboDesc)")
            service.onKeyDownCallback?()
        case UInt32(kEventHotKeyReleased):
            print("[Hotkey] Carbon hotkey released: \(service.currentComboDesc)")
            service.onKeyUpCallback?()
        default:
            break
        }

        return noErr
    }

    // MARK: - Description

    private func describeCombo(_ combo: HotkeyCombo) -> String {
        var parts: [String] = []
        let mods = combo.modifiers
        if mods & UInt32(controlKey) != 0 { parts.append("Ctrl") }
        if mods & UInt32(optionKey)  != 0 { parts.append("Option") }
        if mods & UInt32(shiftKey)   != 0 { parts.append("Shift") }
        if mods & UInt32(cmdKey)     != 0 { parts.append("Cmd") }
        parts.append(keyCodeToName(combo.keyCode))
        return parts.joined(separator: "+")
    }

    private func keyCodeToName(_ keyCode: UInt32) -> String {
        switch UInt16(keyCode) {
        case 0x00: return "A";       case 0x01: return "S";       case 0x02: return "D"
        case 0x03: return "F";       case 0x04: return "H";       case 0x05: return "G"
        case 0x06: return "Z";       case 0x07: return "X";       case 0x08: return "C"
        case 0x09: return "V";       case 0x0B: return "B";       case 0x0C: return "Q"
        case 0x0D: return "W";       case 0x0E: return "E";       case 0x0F: return "R"
        case 0x10: return "Y";       case 0x11: return "T";       case 0x12: return "1"
        case 0x13: return "2";       case 0x14: return "3";       case 0x15: return "4"
        case 0x16: return "6";       case 0x17: return "5";       case 0x18: return "="
        case 0x19: return "9";       case 0x1A: return "7";       case 0x1B: return "-"
        case 0x1C: return "8";       case 0x1D: return "0";       case 0x1E: return "]"
        case 0x1F: return "O";       case 0x20: return "U";       case 0x21: return "["
        case 0x22: return "I";       case 0x23: return "P";       case 0x24: return "Return"
        case 0x25: return "L";       case 0x26: return "J";       case 0x27: return "'"
        case 0x28: return "K";       case 0x29: return ";";       case 0x2A: return "\\"
        case 0x2B: return ",";       case 0x2C: return "/";       case 0x2D: return "N"
        case 0x2E: return "M";       case 0x2F: return ".";       case 0x30: return "Tab"
        case 0x32: return "`";       case 0x35: return "Esc";     case 0x37: return "Cmd"
        case 0x38: return "Shift";   case 0x39: return "CapsLock"; case 0x3A: return "Option"
        case 0x3B: return "Ctrl";    case 0x3C: return "Shift";   case 0x3D: return "Option"
        case 0x3E: return "Ctrl";    case 0x40: return "F17";     case 0x41: return "."
        case 0x43: return ",";       case 0x4C: return "Enter";    case 0x4F: return "F5"
        case 0x50: return "F6";      case 0x51: return "F7";       case 0x52: return "F3"
        case 0x53: return "F8";      case 0x55: return "F11";      case 0x57: return "F13"
        case 0x58: return "F16";      case 0x59: return "F14";      case 0x5A: return "F10"
        case 0x5B: return "F12";      case 0x5C: return "F15";      case 0x5D: return "Help"
        case 0x5E: return "Home";     case 0x5F: return "PgUp";     case 0x60: return "Delete"
        case 0x61: return "F4";       case 0x62: return "End";       case 0x63: return "F2"
        case 0x64: return "PgDn";    case 0x65: return "F1";        case 0x66: return "Left"
        case 0x67: return "Right";    case 0x68: return "Down";     case 0x69: return "Up"
        case 0x7E: return "Up";      case 0x7D: return "Down";     case 0x7B: return "Left"
        case 0x7C: return "Right"
        default: return "0x\(String(keyCode, radix: 16))"
        }
    }
}
