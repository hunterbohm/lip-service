import Foundation
import DictationCore
import UserNotifications

/// A macOS notification for a word learned from the user's fix. The bar's notice is easy to miss, and this one also
/// lands in Notification Center.
@MainActor final class LearnedAlert: NSObject, UNUserNotificationCenterDelegate {
    nonisolated private static let category = "learned"
    nonisolated private static let undo = "undo"
    private let center = UNUserNotificationCenter.current()
    var onUndo: (Vocabulary.Term) -> Void = { _ in }

    func start() {
        center.delegate = self
        center.setNotificationCategories([UNNotificationCategory(
            identifier: Self.category, actions: [UNNotificationAction(identifier: Self.undo, title: "Undo")],
            intentIdentifiers: [])])
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// The term rides in the notification, so its Undo still works after the app restarts.
    func show(_ term: Vocabulary.Term) {
        let content = UNMutableNotificationContent()
        content.title = "Learned \(term.text)"
        content.userInfo = ["text": term.text, "aliases": term.aliases]
        content.body = "Added to your dictionary from your fix."
        content.categoryIdentifier = Self.category
        center.add(UNNotificationRequest(identifier: "learned", content: content, trigger: nil))
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification)
        async -> UNNotificationPresentationOptions { [.banner, .list] }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        guard response.actionIdentifier == Self.undo, let text = info["text"] as? String else { return }
        let term = Vocabulary.Term(text: text, aliases: info["aliases"] as? [String] ?? [])
        await MainActor.run { onUndo(term) }
    }
}
