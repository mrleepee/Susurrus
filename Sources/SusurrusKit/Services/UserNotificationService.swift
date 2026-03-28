import Foundation
import UserNotifications

/// Concrete notification service using UNUserNotificationCenter.
/// Falls back to print() when running outside a proper app bundle.
public final class UserNotificationService: Notifying, @unchecked Sendable {

    /// Whether we're running inside a proper .app bundle.
    private static let isInAppBundle: Bool = {
        Bundle.main.bundlePath.hasSuffix(".app")
    }()

    public init() {}

    public func showNotification(title: String, body: String) {
        guard Self.isInAppBundle else {
            print("[\(title)] \(body)")
            return
        }

        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: .alert) { _, _ in }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )

        center.add(request) { _ in }
    }
}
