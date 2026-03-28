import AppKit

/// Maps recording state to the appropriate menu bar icon (SF Symbol name).
public enum MenuBarIcon {
    /// SF Symbol names for the recording pulse animation cycle.
    public static let recordingFrameA = "mic.fill"
    public static let recordingFrameB = "mic"

    /// Returns the SF Symbol name for the given recording state.
    /// For recording state, returns frame A (filled mic) as the base icon.
    public static func symbolName(for state: RecordingState) -> String {
        switch state {
        case .idle:
            "mic"
        case .recording:
            recordingFrameA
        case .processing:
            "mic.badge.xmark"
        }
    }

    /// Returns a human-readable tooltip for the given recording state.
    public static func tooltip(for state: RecordingState) -> String {
        switch state {
        case .idle:
            "Susurrus — Ready"
        case .recording:
            "Susurrus — Recording"
        case .processing:
            "Susurrus — Processing"
        }
    }
}
