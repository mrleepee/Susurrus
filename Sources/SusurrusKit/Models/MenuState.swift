/// Represents a menu action in the app.
public enum MenuAction: String, Sendable, Equatable, CaseIterable {
    case startRecording = "Start Recording"
    case stopRecording = "Stop Recording"
    case preferences = "Preferences..."
    case quit = "Quit Susurrus"
}

/// Determines menu content based on app state.
public enum MenuState {
    /// Returns the primary recording action for the current state.
    public static func recordingAction(for state: RecordingState) -> MenuAction {
        switch state {
        case .idle, .processing:
            return .startRecording
        case .recording:
            return .stopRecording
        }
    }

    /// Whether the recording action is enabled in the current state.
    public static func isRecordingEnabled(for state: RecordingState) -> Bool {
        switch state {
        case .idle, .recording:
            return true
        case .processing:
            return false
        }
    }

    /// All visible menu actions for the current state.
    public static func visibleActions(for state: RecordingState) -> [MenuAction] {
        let action = recordingAction(for: state)
        return [action, .preferences, .quit]
    }
}
