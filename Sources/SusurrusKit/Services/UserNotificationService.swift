import Foundation
import UserNotifications

/// Concrete notification service using UNUserNotificationCenter.
/// Falls back to print() when running outside a proper app bundle.
///
/// Acts as its own UNUserNotificationCenterDelegate so that notifications
/// always display as banners, even when the app is considered foreground
/// (common for menu-bar-only apps).
public final class UserNotificationService: NSObject, Notifying, UNUserNotificationCenterDelegate, @unchecked Sendable {

    /// Whether we're running inside a proper .app bundle.
    private static let isInAppBundle: Bool = {
        Bundle.main.bundlePath.hasSuffix(".app")
    }()

    private var authorized = false

    public override init() {
        super.init()
        guard Self.isInAppBundle else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            self.authorized = granted
        }
    }

    public func showNotification(title: String, body: String) {
        guard Self.isInAppBundle else {
            print("[\(title)] \(body)")
            return
        }

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

    // MARK: - UNUserNotificationCenterDelegate

    /// Ensure notifications always display as banners even when the app is foreground.
    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list])
    }
}
