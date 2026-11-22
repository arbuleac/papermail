import AppKit
import UserNotifications

/// What macOS lets Paper show, in our own words so the model and its tests never import UserNotifications.
enum NotificationPermission: Equatable, Sendable {
    /// The user has not been asked yet.
    case notAsked
    /// Off for Paper in System Settings › Notifications, or the user said Don't Allow: macOS shows no
    /// notification and draws no Dock badge, though the app still sets it.
    case denied
    /// Allowed, the Dock badge with them.
    case allowed
    /// Allowed, with Badge application icon off: notifications show and the Dock badge does not.
    case allowedWithoutBadge
    /// Running outside an app bundle (a bare build, the tests): there is no notification center to ask.
    case unavailable
}

/// Paper's notification permission. Settings › General asks and requests it only through this, so the app's
/// tests, which pass a fake, never read or change the Mac's real notification settings.
@MainActor
protocol NotificationPermissionHandling {
    func permission() async -> NotificationPermission
    /// Puts macOS's own prompt up. Only ever while the user has not been asked: macOS asks once, and after that only
    /// System Settings changes the answer.
    func request() async
    /// System Settings at Notifications, on Paper's own page.
    func openNotificationSettings()
}

/// The app's notification center, the one `NewMailNotifier` posts through.
struct SystemNotificationPermission: NotificationPermissionHandling {
    func permission() async -> NotificationPermission {
        guard let center = NewMailNotifier.systemCenter else { return .unavailable }
        let settings = await center.notificationSettings()
        return NotificationPermission(settings.authorizationStatus, badge: settings.badgeSetting)
    }

    func request() async {
        guard let center = NewMailNotifier.systemCenter else { return }
        _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
    }

    func openNotificationSettings() {
        // The app's own page where macOS knows the bundle; the Notifications list otherwise.
        let pane = "x-apple.systempreferences:com.apple.Notifications-Settings.extension"
        let own = Bundle.main.bundleIdentifier.flatMap { URL(string: "\(pane)?id=\($0)") }
        if let own, NSWorkspace.shared.open(own) { return }
        if let list = URL(string: pane) { NSWorkspace.shared.open(list) }
    }
}

/// The snapshots' answer: allowed, and nothing is ever asked of or opened in macOS, so a render depends on nothing but
/// the build.
struct SnapshotNotificationPermission: NotificationPermissionHandling {
    func permission() async -> NotificationPermission { .allowed }
    func request() async {}
    func openNotificationSettings() {}
}

extension NotificationPermission {
    init(_ status: UNAuthorizationStatus, badge: UNNotificationSetting) {
        switch status {
        case .notDetermined: self = .notAsked
        case .denied: self = .denied
        // Provisional delivery is quiet, but it is delivery, and the badge follows its own switch as when allowed.
        case .authorized, .provisional: self = badge == .disabled ? .allowedWithoutBadge : .allowed
        // A status newer than this build says nothing is wrong, rather than a line the user can do nothing about.
        @unknown default: self = .allowed
        }
    }
}
