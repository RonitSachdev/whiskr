import AppKit
import Observation
import UserNotifications
import WhiskrKit

/// macOS notifications for a Claude that needs you or has finished while you were in another app.
/// Permission is asked the first time a Claude works in one of the app's terminals, when the reason is
/// plain, not at launch; and again only from Settings › Alerts, which always says whether macOS lets
/// them through. A permission request offers Allow and Deny right in the notification (§6.4); they
/// answer only if that very request is still waiting.
final class Notifier: NSObject {
    nonisolated private static let paneKey = "pane"
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

    /// Whether permission has been asked for in this run (or would have been, in a test run that never asks).
    private(set) var askedThisRun = false

    /// A Claude is at work: if macOS has not been asked yet whether Whiskr may notify (and an alert would
    /// use it), asks now, once per run. Whatever happened to an earlier question (answered, dismissed,
    /// never seen), the system's own state decides, never a note of ours that it was asked.
    func requestPermissionIfNeeded() {
        guard !askedThisRun else { return }
        askedThisRun = true
        guard AlertEvent.allCases.contains(where: { Preferences.shared.alerts[$0].notify }) else { return }
        // A test run never shows the system's question on anyone's screen.
        guard !AppPlaces.isIsolated else { return }
        Task { @MainActor in
            await NotificationAccess.shared.refresh()
            if NotificationAccess.shared.status == .notAsked { await NotificationAccess.shared.request() }
        }
    }

    /// `request`: a permission request, offered with Allow and Deny. Silent: the alert's own sound (Settings
    /// › Alerts) plays beside it, so a sound chosen there is the one heard.
    func post(title: String, body: String, pane: UUID, request: Bool = false) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.userInfo = [Self.paneKey: pane.uuidString]
        content.threadIdentifier = pane.uuidString
        if request { content.categoryIdentifier = Self.requestCategory }
        content.interruptionLevel = .active
        // One notification per pane: a newer one replaces the older.
        let request = UNNotificationRequest(identifier: pane.uuidString, content: content, trigger: nil)
        // A test run against scratch settings (Debug) never shows anything on your screen: it notes what it
        // would have shown.
        if AppPlaces.isIsolated {
            #if DEBUG
            Self.posted.append(request)
            #endif
            return
        }
        UNUserNotificationCenter.current().add(request)
    }

    #if DEBUG
    /// Debug builds: what a test run would have shown (`post`), newest last.
    static var posted: [UNNotificationRequest] = []
    #endif

    /// Clears what is shown for a pane once you have looked at it.
    func withdraw(pane: UUID) {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [pane.uuidString])
    }
}

extension Notifier: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list]
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

/// Whether macOS lets Whiskr's notifications through, as Settings › Alerts shows it. Looked up when the
/// app comes to the front and when Settings shows it, since it is changed in System Settings.
@MainActor
@Observable
final class NotificationAccess {
    static let shared = NotificationAccess()

    enum Status: Equatable {
        /// Not looked up yet.
        case unknown
        /// macOS has not asked you yet.
        case notAsked
        /// Allowed (as banners, alerts, or only in Notification Center: your choice in System Settings).
        case allowed
        /// Turned off for Whiskr in System Settings › Notifications.
        case off
    }

    private(set) var status: Status = .unknown
    /// Why macOS would not even ask, the last time it was asked (it says why); nil once it did.
    private(set) var refusal: String?

    private init() {
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in await NotificationAccess.shared.refresh() }
        }
    }

    func refresh() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        status = switch settings.authorizationStatus {
        case .notDetermined: .notAsked
        case .denied: .off
        case .authorized, .provisional: .allowed
        @unknown default: .allowed
        }
    }

    /// Asks macOS (it shows its own question), then looks again. Never in a test run.
    func request() async {
        guard !AppPlaces.isIsolated else { return }
        // The async form: a completion handler written here would be the main actor's, and the system
        // calls it on a queue of its own (Swift 6 traps there).
        do {
            _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge])
            refusal = nil
        } catch {
            refusal = error.localizedDescription
        }
        await refresh()
    }

    /// System Settings › Notifications, at Whiskr.
    func openSystemSettings() {
        let id = Bundle.main.bundleIdentifier ?? "app.whiskr.Whiskr"
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)") { NSWorkspace.shared.open(url) }
    }

    #if DEBUG
    /// Debug builds: a status as if macOS had said it, to see Settings › Alerts in each case.
    func debugSet(_ status: Status) { self.status = status }
    #endif
}
