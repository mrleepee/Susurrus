import Testing
@testable import SusurrusKit

/// Mock notification service for testing without UNUserNotificationCenter.
final class MockNotificationService: Notifying, @unchecked Sendable {
    var notifications: [(title: String, body: String)] = []
    var callCount: Int { notifications.count }

    func showNotification(title: String, body: String) {
        notifications.append((title, body))
    }
}

@Suite("Notification Tests")
struct NotificationTests {

    @Test("Show notification records title and body")
    func showNotification() {
        let service = MockNotificationService()
        service.showNotification(title: "Copied to clipboard", body: "Your text is ready to paste")
        #expect(service.notifications.count == 1)
        #expect(service.notifications[0].title == "Copied to clipboard")
        #expect(service.notifications[0].body == "Your text is ready to paste")
    }

    @Test("Multiple notifications tracked")
    func multipleNotifications() {
        let service = MockNotificationService()
        service.showNotification(title: "First", body: "Body 1")
        service.showNotification(title: "Second", body: "Body 2")
        #expect(service.callCount == 2)
    }

    @Test("Success notification content")
    func successNotification() {
        let service = MockNotificationService()
        // Simulate: transcription succeeded, clipboard updated
        service.showNotification(title: "Susurrus", body: "Copied to clipboard")
        #expect(service.notifications[0].title == "Susurrus")
        #expect(service.notifications[0].body == "Copied to clipboard")
    }

    @Test("Error notification for empty transcription")
    func errorNotification() {
        let service = MockNotificationService()
        service.showNotification(title: "Susurrus", body: "No speech detected")
        #expect(service.notifications[0].body == "No speech detected")
    }

    @Test("NotificationError equality")
    func errorEquality() {
        #expect(NotificationError.deliveryFailed("a") == NotificationError.deliveryFailed("a"))
        #expect(NotificationError.deliveryFailed("a") != NotificationError.deliveryFailed("b"))
    }
}
