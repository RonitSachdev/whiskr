import Foundation
import UserNotifications

/// macOS notifications for an agent that needs you or has finished while you were not looking at it.
/// Permission is asked the first time you start a Claude session from the app, when the reason is
/// plain, not at launch. A permission request offers Allow and Deny right in the notification (§6.4);
/// they answer only if that very request is still waiting.
final class Notifier: NSObject {
    nonisolated private static let paneKey = "pane"
    nonisolated private static let askedKey = "notificationsRequested"
    nonisolated private static let requestCategory = "request"
    nonisolated private static let allowAction = "allow"
    nonisolated private static let denyAction = "deny"

    /// Called with the pane a clicked notification was about.
    var onOpen: ((UUID) -> Void)?
    /// Called with the pane and true for Allow, false for Deny, from a request's notification.
    var onAnswer: ((UUID, Bool) -> Void)?

    override init() {
        super.init()
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let allow = UNNotificationAction(identifier: Self.allowAction, title: String(localized: "Allow", comment: "Notification button: answers Claude's permission request with Yes"))
        let deny = UNNotificationAction(identifier: Self.denyAction, title: String(localized: "Deny", comment: "Notification button: refuses Claude's permission request"),
                                        options: [.destructive])
        center.setNotificationCategories([UNNotificationCategory(identifier: Self.requestCategory, actions: [allow, deny], intentIdentifiers: [])])
    }

    func requestPermissionIfNeeded() {
        guard !AppPlaces.isIsolated else { return }
        guard !AppPlaces.defaults.bool(forKey: Self.askedKey) else { return }
        AppPlaces.defaults.set(true, forKey: Self.askedKey)
        // The async form: a completion handler written here would be the main actor's, and the system
        // calls it on a queue of its own (Swift 6 traps there).
        Task { _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) }
    }

    /// `request`: a permission request, offered with Allow and Deny.
    func post(title: String, body: String, pane: UUID, sound: Bool, request: Bool = false) {
        // A test run against scratch settings (Debug) never shows anything on your screen.
        guard !AppPlaces.isIsolated else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.userInfo = [Self.paneKey: pane.uuidString]
        content.threadIdentifier = pane.uuidString
        if sound { content.sound = .default }
        if request { content.categoryIdentifier = Self.requestCategory }
        content.interruptionLevel = .active
        // One notification per pane: a newer one replaces the older.
        let request = UNNotificationRequest(identifier: pane.uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    /// Clears what is shown for a pane once you have looked at it.
    func withdraw(pane: UUID) {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [pane.uuidString])
    }
}

extension Notifier: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let text = response.notification.request.content.userInfo[Self.paneKey] as? String, let pane = UUID(uuidString: text) else { return }
        let action = response.actionIdentifier
        await MainActor.run {
            switch action {
            case Self.allowAction: onAnswer?(pane, true)
            case Self.denyAction: onAnswer?(pane, false)
            default: onOpen?(pane)
            }
        }
    }
}
