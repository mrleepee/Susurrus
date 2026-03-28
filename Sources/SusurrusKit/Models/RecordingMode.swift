/// Recording mode determines how recording is triggered.
public enum RecordingMode: String, Sendable, Equatable, CaseIterable, Codable {
    /// Hold the hotkey to record, release to stop (default).
    case pushToTalk = "push-to-talk"
    /// Press once to start, press again to stop.
    case toggle = "toggle"
}
