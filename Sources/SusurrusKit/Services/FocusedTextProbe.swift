import ApplicationServices

/// Asks an app, through Accessibility, whether its focused element can take
/// typed text — so an insert can fall back to copy-only instead of sending
/// ⌘V into a file list or sidebar.
///
/// Only a clear "no" counts. Many apps can't say: Electron apps (Slack,
/// Teams) report no focused element even with their message box focused,
/// and some custom editors (Sublime Text) report only their window. All of
/// those come back `.unknown`, and the caller should paste as normal.
public enum FocusedTextProbe {
    public enum Verdict: Sendable, Equatable {
        case editable
        case notEditable
        case unknown
    }

    public static func check(pid: pid_t) -> Verdict {
        // Querying our own process from the main thread just blocks until
        // the timeout; our own windows never take dictated text anyway.
        guard AXIsProcessTrusted(), pid != getpid() else { return .unknown }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)

        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return .unknown
        }
        let element = value as! AXUIElement

        let role = string(element, kAXRoleAttribute) ?? ""
        if textRoles.contains(role) { return .editable }
        // Text inside web contenteditable regions and text views that use
        // a generic role still carry a caret.
        if has(element, "AXEditableAncestor") || has(element, kAXSelectedTextRangeAttribute) {
            return .editable
        }
        return nonTextRoles.contains(role) ? .notEditable : .unknown
    }

    private static let textRoles: Set<String> = [
        kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole, "AXSearchField",
    ]

    /// Roles that are never a place to type. Deliberately excludes the
    /// container roles (window, group, scroll area, web area) that apps
    /// without a full AX tree report for whatever actually has focus.
    private static let nonTextRoles: Set<String> = [
        kAXOutlineRole, kAXListRole, kAXTableRole, kAXBrowserRole, kAXRowRole, "AXCell",
        kAXButtonRole, kAXCheckBoxRole, kAXRadioButtonRole, kAXPopUpButtonRole,
        kAXMenuButtonRole, kAXSliderRole, kAXImageRole, kAXStaticTextRole,
        "AXLink", kAXToolbarRole, kAXTabGroupRole, kAXDisclosureTriangleRole,
    ]

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func has(_ element: AXUIElement, _ attribute: String) -> Bool {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success && value != nil
    }
}
