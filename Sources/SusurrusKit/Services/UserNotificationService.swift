import Foundation
import UserNotifications

/// Writes to ~/susurrus_debug.log — same sink as traceApp() in the app layer.
private func traceNotify(_ message: String) {
    let path = NSHomeDirectory() + "/susurrus_debug.log"
    let line = "\(Date()) [notify] \(message)\n"
    if let handle = FileHandle(forWritingAtPath: path) {
        handle.seekToEndOfFile()
        handle.write(Data(line.utf8))
        handle.closeFile()
    } else {
        FileManager.default.createFile(atPath: path, contents: Data(line.utf8))
    }
}

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
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            self.authorized = granted
            traceNotify("authorization granted=\(granted) error=\(error?.localizedDescription ?? "none")")
        }
    }

    public func showNotification(title: String, body: String) {
        guard Self.isInAppBundle else {
            print("[\(title)] \(body)")
            return
        }

        traceNotify("posting title='\(title)' body='\(body)' authorized=\(authorized)")

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                traceNotify("post FAILED: \(error.localizedDescription)")
            }
        }
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
