import AppKit
import UserNotifications

/// What the app asks of the notification center at launch. `UNUserNotificationCenter` raises in a process without
/// a bundle (`swift run`, the tests), so the responder takes the center through this and the tests hand it a fake.
protocol NotificationCenterRegistering: AnyObject {
    var delegate: UNUserNotificationCenterDelegate? { get set }
    func setNotificationCategories(_ categories: Set<UNNotificationCategory>)
}

extension UNUserNotificationCenter: NotificationCenterRegistering {}

/// Answers new-mail notifications (spec §5.41): a click opens and selects the conversation, Reply opens a reply
/// composer, and Archive and Mark as Read change the conversation without bringing the app forward. It is the
/// center's delegate from before launch ends, because macOS launches the app to deliver an action and hands the
/// response only to a delegate set by then. A response that comes before there is a main window (one that launched
/// the app) waits here, as mail links wait in `MailLinkInbox`, until the app delegate sets the receiver once a main
/// window has read its accounts.
@MainActor
final class NewMailNotificationResponder: NSObject, UNUserNotificationCenterDelegate {
    /// Responses received while there was no receiver, oldest first.
    private(set) var pending: [NewMailNotificationResponse] = []

    /// Applies one response. Setting it hands over every response that was waiting.
    var receiver: ((NewMailNotificationResponse) -> Void)? {
        didSet { deliverPending() }
    }

    /// Brings the app forward for a click and for Reply. Replaceable so the app's tests never activate the runner.
    var activate: () -> Void = { NSApp.activate() }

    /// Registers the notification's actions and becomes the center's delegate. Called before launch ends.
    func connect(to center: NotificationCenterRegistering) {
        center.setNotificationCategories(NewMailNotificationAction.categories)
        center.delegate = self
    }

    /// One response, as the center delivers it (internal so the app's tests can deliver them).
    func receive(actionIdentifier: String, userInfo: [AnyHashable: Any]) {
        receive(NewMailNotificationResponse(actionIdentifier: actionIdentifier, userInfo: userInfo))
    }

    private func receive(_ response: NewMailNotificationResponse?) {
        guard let response else { return }
        if response.bringsAppForward { activate() }
        pending.append(response)
        deliverPending()
    }

    private func deliverPending() {
        guard let receiver, !pending.isEmpty else { return }
        let responses = pending
        pending = []
        responses.forEach(receiver)
    }

    // MARK: UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // The app is in front: the notification shows, without sound (§5.41). The conversation open in a key
        // window never got one.
        completionHandler([.banner, .list])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        // Read here: the user info is not Sendable, the response it becomes is.
        let answer = NewMailNotificationResponse(actionIdentifier: response.actionIdentifier,
                                                 userInfo: response.notification.request.content.userInfo)
        DispatchQueue.main.async {
            MainActor.assumeIsolated { self.receive(answer) }
            completionHandler()
        }
    }
}
