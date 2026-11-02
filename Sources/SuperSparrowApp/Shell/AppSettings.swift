import Combine
import Foundation

/// User preferences, backed by `UserDefaults`. Observable so the SwiftUI settings window and the AppKit shell
/// read the same values.
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    static let undoSendChoices: [TimeInterval] = [5, 10, 20]

    /// Posted after any of the Quire display preferences below change (reading font, density, account
    /// initials), so AppKit views that cache laid-out text can rebuild without observing each property.
    static let displayPreferencesChanged = Notification.Name("AppSettings.displayPreferencesChanged")

    /// Spec §5.40 General: the face plain and unstyled bodies are set in.
    enum ReadingFont: String, CaseIterable {
        case newYork
        case sfPro
    }

    /// Spec §5.7: standard rows are 68 pt, compact rows 48 pt.
    enum ListDensity: String, CaseIterable {
        case standard
        case compact
    }

    private enum Key {
        static let notifications = "notificationsEnabled"
        static let previews = "notificationPreviews"
        static let remoteImages = "loadRemoteImages"
        static let undoSend = "undoSendDelay"
        static let askedForNotifications = "askedForNotificationPermission"
        static let readingFont = "readingFont"
        static let listDensity = "listDensity"
        static let showAccountInitials = "showAccountInitials"
        static let originalColorsNoticeDismissed = "originalColorsNoticeDismissed"
        static let accountInitialsTurnedOnAutomatically = "accountInitialsTurnedOnAutomatically"
        static let accountInitialsChosenByUser = "accountInitialsChosenByUser"
        static let sevenAccountsNoticePending = "sevenAccountsNoticePending"
    }

    /// Spec §4.2: with this many accounts, colours alone can look alike, so account initials turn on once.
    static let accountInitialsThreshold = 7

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

    @Published var readingFont: ReadingFont {
        didSet {
            defaults.set(readingFont.rawValue, forKey: Key.readingFont)
            postDisplayChange()
        }
    }

    @Published var listDensity: ListDensity {
        didSet {
            defaults.set(listDensity.rawValue, forKey: Key.listDensity)
            postDisplayChange()
        }
    }

    /// Spec §5.7: an initial tile beside the account ring in unified views, a second, non-colour account cue.
    @Published var showAccountInitials: Bool {
        didSet {
            defaults.set(showAccountInitials, forKey: Key.showAccountInitials)
            postDisplayChange()
        }
    }

    /// Spec §5.16: the Original colors notice is shown until the user dismisses it once.
    @Published var originalColorsNoticeDismissed: Bool {
        didSet { defaults.set(originalColorsNoticeDismissed, forKey: Key.originalColorsNoticeDismissed) }
    }

    /// Spec §5.40 Seven accounts: account initials were turned on by a seventh account, not by the user.
    /// While this holds and the user has not touched the checkbox, General captions it.
    @Published private(set) var accountInitialsTurnedOnAutomatically: Bool {
        didSet { defaults.set(accountInitialsTurnedOnAutomatically, forKey: Key.accountInitialsTurnedOnAutomatically) }
    }

    /// The user changed Show account initials themselves; their choice is kept and an eighth account does not
    /// turn it back on.
    @Published private(set) var accountInitialsChosenByUser: Bool {
        didSet { defaults.set(accountInitialsChosenByUser, forKey: Key.accountInitialsChosenByUser) }
    }

    /// Settings › Accounts shows the seven-accounts notice until it is dismissed or followed, across launches.
    @Published var sevenAccountsNoticePending: Bool {
        didSet { defaults.set(sevenAccountsNoticePending, forKey: Key.sevenAccountsNoticePending) }
    }

    /// General's caption under the Rows checkbox: “Turned on when you added a seventh account.”
    var showsSevenAccountsCaption: Bool {
        showAccountInitials && accountInitialsTurnedOnAutomatically && !accountInitialsChosenByUser
    }

    /// The Rows checkbox: the user's own choice, which ends the automatic state for good.
    func setShowAccountInitialsByUser(_ on: Bool) {
        accountInitialsChosenByUser = true
        sevenAccountsNoticePending = false
        if showAccountInitials != on { showAccountInitials = on }
    }

    /// Called after an account is added. The seventh account turns initials on, once ever, unless the user
    /// already chose (spec §4.2).
    func accountWasAdded(totalAccounts: Int) {
        guard totalAccounts >= Self.accountInitialsThreshold, !accountInitialsTurnedOnAutomatically, !accountInitialsChosenByUser,
              !showAccountInitials else { return }
        accountInitialsTurnedOnAutomatically = true
        sevenAccountsNoticePending = true
        showAccountInitials = true
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
            Key.readingFont: ReadingFont.newYork.rawValue,
            Key.listDensity: ListDensity.standard.rawValue,
            Key.showAccountInitials: false,
            Key.originalColorsNoticeDismissed: false,
            Key.accountInitialsTurnedOnAutomatically: false,
            Key.accountInitialsChosenByUser: false,
            Key.sevenAccountsNoticePending: false,
        ])
        notificationsEnabled = defaults.bool(forKey: Key.notifications)
        showPreviews = defaults.bool(forKey: Key.previews)
        loadRemoteImages = defaults.bool(forKey: Key.remoteImages)
        let stored = defaults.double(forKey: Key.undoSend)
        undoSendDelay = AppSettings.undoSendChoices.contains(stored) ? stored : 5
        readingFont = ReadingFont(rawValue: defaults.string(forKey: Key.readingFont) ?? "") ?? .newYork
        listDensity = ListDensity(rawValue: defaults.string(forKey: Key.listDensity) ?? "") ?? .standard
        showAccountInitials = defaults.bool(forKey: Key.showAccountInitials)
        originalColorsNoticeDismissed = defaults.bool(forKey: Key.originalColorsNoticeDismissed)
        accountInitialsTurnedOnAutomatically = defaults.bool(forKey: Key.accountInitialsTurnedOnAutomatically)
        accountInitialsChosenByUser = defaults.bool(forKey: Key.accountInitialsChosenByUser)
        sevenAccountsNoticePending = defaults.bool(forKey: Key.sevenAccountsNoticePending)
        applyUndoSendDelay()
        ConversationViewController.loadRemoteImages = loadRemoteImages
    }

    private func postDisplayChange() {
        NotificationCenter.default.post(name: AppSettings.displayPreferencesChanged, object: self)
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
