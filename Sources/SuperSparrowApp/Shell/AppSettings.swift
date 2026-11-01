import Combine
import Foundation

/// User preferences, backed by `UserDefaults`. Observable so the SwiftUI settings window and the AppKit shell
/// read the same values.
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    static let undoSendChoices: [TimeInterval] = [5, 10, 20]

    private enum Key {
        static let notifications = "notificationsEnabled"
        static let previews = "notificationPreviews"
        static let remoteImages = "loadRemoteImages"
        static let undoSend = "undoSendDelay"
        static let askedForNotifications = "askedForNotificationPermission"
    }

    private let defaults: UserDefaults

    @Published var notificationsEnabled: Bool {
        didSet { defaults.set(notificationsEnabled, forKey: Key.notifications) }
    }

    /// Sender and subject in the notification body. On by default: this is a personal client on the user's own Mac.
    @Published var showPreviews: Bool {
        didSet { defaults.set(showPreviews, forKey: Key.previews) }
    }

    /// Read live: by the sanitizer for bodies synced from now on, and by the reader, which renders every
    /// body under a policy that blocks remote fetches while this is off, whatever the body was stored with.
    @Published var loadRemoteImages: Bool {
        didSet {
            defaults.set(loadRemoteImages, forKey: Key.remoteImages)
            applyRemoteImages()
        }
    }

    @Published var undoSendDelay: TimeInterval {
        didSet {
            defaults.set(undoSendDelay, forKey: Key.undoSend)
            applyUndoSendDelay()
        }
    }

    var hasAskedForNotifications: Bool {
        get { defaults.bool(forKey: Key.askedForNotifications) }
        set { defaults.set(newValue, forKey: Key.askedForNotifications) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.notifications: true,
            Key.previews: true,
            Key.remoteImages: false,
            Key.undoSend: 5.0,
        ])
        notificationsEnabled = defaults.bool(forKey: Key.notifications)
        showPreviews = defaults.bool(forKey: Key.previews)
        loadRemoteImages = defaults.bool(forKey: Key.remoteImages)
        let stored = defaults.double(forKey: Key.undoSend)
        undoSendDelay = AppSettings.undoSendChoices.contains(stored) ? stored : 5
        applyUndoSendDelay()
        ConversationViewController.loadRemoteImages = loadRemoteImages
    }

    private func applyRemoteImages() {
        ConversationViewController.loadRemoteImages = loadRemoteImages
        NotificationCenter.default.post(name: ConversationViewController.remoteImagesPolicyChanged, object: nil)
    }

    /// For the sanitizer, which runs off the main actor: UserDefaults is safe to read from any thread.
    nonisolated static func loadRemoteImagesNow(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: Key.remoteImages)
    }

    func applyUndoSendDelay() {
        ComposeWindowController.undoWindow = undoSendDelay
        ConversationViewController.undoWindow = undoSendDelay
    }
}
