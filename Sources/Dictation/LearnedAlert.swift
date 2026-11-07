import Foundation
import UserNotifications

/// A macOS notification for a word learned from the user's fix. The bar's notice is easy to miss, and this one also
/// lands in Notification Center.
@MainActor final class LearnedAlert: NSObject, UNUserNotificationCenterDelegate {
    nonisolated private static let category = "learned"
    nonisolated private static let undo = "undo"
    private let center = UNUserNotificationCenter.current()
    var onUndo: () -> Void = {}

    func start() {
        center.delegate = self
        center.setNotificationCategories([UNNotificationCategory(
            identifier: Self.category, actions: [UNNotificationAction(identifier: Self.undo, title: "Undo")],
            intentIdentifiers: [])])
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func show(_ word: String) {
        let content = UNMutableNotificationContent()
        content.title = "Learned \(word)"
        content.body = "Added to your dictionary from your fix."
        content.categoryIdentifier = Self.category
        center.add(UNNotificationRequest(identifier: "learned", content: content, trigger: nil))
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification)
        async -> UNNotificationPresentationOptions { [.banner, .list] }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard response.actionIdentifier == Self.undo else { return }
        await MainActor.run { onUndo() }
    }
}
