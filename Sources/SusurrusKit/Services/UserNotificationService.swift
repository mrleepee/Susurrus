import Foundation
import UserNotifications

/// Concrete notification service using UNUserNotificationCenter.
public final class UserNotificationService: Notifying, @unchecked Sendable {
    public init() {}

    public func showNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request) { _ in }
    }
}
