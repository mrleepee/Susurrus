/// Protocol abstracting user notifications for testability.
public protocol Notifying: Sendable {
    /// Show a brief notification with a title and optional body.
    func showNotification(title: String, body: String)
}

/// Errors during notification display.
public enum NotificationError: Error, Sendable, Equatable {
    case deliveryFailed(String)
}
