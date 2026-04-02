import AppKit

/// Maps recording state to the appropriate menu bar icon (SF Symbol name).
/// Uses waveform icons to avoid collision with the macOS system microphone indicator.
public enum MenuBarIcon {
    /// SF Symbol names for the recording pulse animation cycle.
    public static let recordingFrameA = "waveform.circle.fill"
    public static let recordingFrameB = "waveform.circle"

    /// SF Symbol names for the processing spinner animation cycle.
    public static let processingFrameA = "ellipsis.circle.fill"
    public static let processingFrameB = "ellipsis.circle"

    /// SF Symbol for model loading / not-ready state.
    public static let loadingFrameA = "arrow.down.circle.fill"
    public static let loadingFrameB = "arrow.down.circle"

    /// SF Symbol for streaming state (live waveform).
    public static let streamingFrameA = "waveform.circle.fill"
    public static let streamingFrameB = "waveform.circle"

    /// SF Symbol for finalizing state.
    public static let finalizingFrameA = "ellipsis.circle.fill"
    public static let finalizingFrameB = "ellipsis.circle"

    /// Convenience accessors for streaming/finalizing states.
    public static let streamingSymbolName = "waveform.circle.fill"
    public static let finalizingSymbolName = "ellipsis.circle.fill"

    /// Returns the SF Symbol name for the given recording state.
    public static func symbolName(for state: RecordingState) -> String {
        switch state {
        case .idle:
            "waveform"
        case .recording:
            recordingFrameA
        case .processing:
            processingFrameA
        case .streaming:
            streamingFrameA
        case .finalizing:
            finalizingFrameA
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
        case .streaming:
            "Susurrus — Streaming"
        case .finalizing:
            "Susurrus — Finalizing"
        }
    }
}
