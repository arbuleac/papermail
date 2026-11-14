import AppKit
import Combine
import Foundation
import SSCore
import SSDesign

/// User preferences, backed by `UserDefaults`. Observable so the SwiftUI settings window and the AppKit shell
/// read the same values.
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    static let undoSendChoices: [TimeInterval] = [5, 10, 20]

    /// Posted after the row display preferences below change (density, account initials), so AppKit views that
    /// cache laid-out rows can rebuild without observing each property. The Font setting is not posted here: it
    /// lives in `QuireEnvironment`, whose change notification every Quire surface already follows.
    static let displayPreferencesChanged = Notification.Name("AppSettings.displayPreferencesChanged")

    /// Posted after the reader's own Text size changes (⌘+, ⌘−, or Settings' Text size setting it too). The reader
    /// alone follows it; the app-wide size is `QuireEnvironment`'s.
    static let readerTextSizeChanged = Notification.Name("AppSettings.readerTextSizeChanged")

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
        /// The Font setting's key from when it was Reading font; kept, with its raw values, so the choice carries over.
        static let typeface = "readingFont"
        static let textSize = "textSize"
        /// The reader's own size, from ⌘+ and ⌘−; absent while the reader follows Text size.
        static let readerTextSize = "readerTextSize"
        static let listDensity = "listDensity"
        static let showAccountInitials = "showAccountInitials"
        static let originalColorsNoticeDismissed = "originalColorsNoticeDismissed"
        static let accountInitialsTurnedOnAutomatically = "accountInitialsTurnedOnAutomatically"
        static let accountInitialsChosenByUser = "accountInitialsChosenByUser"
        static let sevenAccountsNoticePending = "sevenAccountsNoticePending"
        /// The main window's account scope: `unifiedScopeValue` or an account id's raw value.
        static let accountScope = "accountScope"
        /// The demo's own, so trying the demo never changes the scope the user's accounts open on.
        static let demoAccountScope = "accountScope.demo"
        static let keepMail = "keepMail"
        static let sendAction = "sendAction"
        static let theme = "theme"
        static let appearance = "appearance"
        static let adaptsMailColours = "adaptsMailColours"
    }

    /// Account ids are UUIDs, so this can never be one.
    private static let unifiedScopeValue = "unified"

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

    /// Spec §5.40 General › Keep mail on this Mac: how far back bodies stay whole on this Mac. Each environment's engine
    /// follows it (`AppEnvironment.follow`), sweeping at once when it narrows; Everything is the default.
    @Published var keepMail: MailRetention {
        didSet { defaults.set(keepMail.rawValue, forKey: Key.keepMail) }
    }

    /// The popup's choices, in the order it lists them.
    static let keepMailChoices: [MailRetention] = [.everything, .oneYear, .threeMonths]

    /// The words the popup shows for each choice (§5.40).
    static func title(for retention: MailRetention) -> String {
        switch retention {
        case .everything: return "Everything"
        case .oneYear: return "1 year"
        case .threeMonths: return "3 months"
        }
    }

    /// Spec §5.23: what the Send button and ⌘↩ do, Send and Archive unless the user chose Send. Not in Settings: the Send
    /// button's drop-down changes it (`SendActionPreference`), and every open composer and the quick reply follow at once.
    @Published var sendAction: SendAction {
        didSet {
            defaults.set(sendAction.rawValue, forKey: Key.sendAction)
            if oldValue != sendAction { NotificationCenter.default.post(name: SendActionPreference.didChange, object: self) }
        }
    }

    @Published var undoSendDelay: TimeInterval {
        didSet {
            defaults.set(undoSendDelay, forKey: Key.undoSend)
            applyUndoSendDelay()
        }
    }

    /// Spec §4.4, §5.40 Appearance › Font: the face every New York role is set in, app-wide. A change is saved and
    /// pushed into `QuireEnvironment` at once, so everything on screen switches face live.
    @Published var typeface: QuireFont.Typeface {
        didSet {
            defaults.set(typeface.rawValue, forKey: Key.typeface)
            applyTypeface()
        }
    }

    /// Spec §4.15, §5.40 Appearance › Text size: the step every role where mail is read and written takes. A change is
    /// saved, sets the reader to it too, and is pushed into `QuireEnvironment` at once, so the list, the reader and
    /// every composer switch live.
    @Published var textSize: QuireFont.TextSize {
        didSet {
            defaults.set(textSize.rawValue, forKey: Key.textSize)
            // Quire first, the reader's own size after: the other way round, the reader would hear the reset while
            // Quire still held the old size, broadcast that and measure every body at a size nobody chose, then
            // measure them all again at the new one.
            applyTextSize()
            if oldValue != textSize { readerTextSize = nil }
        }
    }

    /// The reader's own size (spec §4.15), when ⌘+ or ⌘− chose one other than Text size's; nil follows Text size.
    /// Kept across launches.
    @Published private(set) var readerTextSize: QuireFont.TextSize? {
        didSet {
            if let readerTextSize { defaults.set(readerTextSize.rawValue, forKey: Key.readerTextSize) } else {
                defaults.removeObject(forKey: Key.readerTextSize)
            }
            if oldValue != readerTextSize { NotificationCenter.default.post(name: AppSettings.readerTextSizeChanged, object: self) }
        }
    }

    /// The size the reader sets its headline, sheets and bodies at: its own, else the one Quire draws at now (Text
    /// size, or a `--text-size` override).
    var readerSize: QuireFont.TextSize { readerTextSize ?? QuireEnvironment.textSize }

    /// ⌘+ and ⌘−: the reader one size up or down, never past Larger or Small. Back at Text size's own size it
    /// follows Text size again. False when there is no size that way.
    @discardableResult
    func stepReaderTextSize(larger: Bool) -> Bool {
        guard let next = larger ? readerSize.larger : readerSize.smaller else { return false }
        readerTextSize = next == QuireEnvironment.textSize ? nil : next
        return true
    }

    /// Spec §4.16, §5.40 Appearance › Theme. A change is saved and pushed into `QuireEnvironment` at once, so every
    /// window, Settings included, re-themes live.
    @Published var theme: QuireTheme {
        didSet {
            defaults.set(theme.rawValue, forKey: Key.theme)
            if oldValue != theme { applyTheme() }
        }
    }

    /// Spec §5.40 Appearance › Appearance: Automatic, Light or Dark for this app. A change is saved and applied at once.
    @Published var appearance: AppAppearance {
        didSet {
            defaults.set(appearance.rawValue, forKey: Key.appearance)
            if oldValue != appearance { applyAppearance() }
        }
    }

    /// Spec §5.14, §5.40 Appearance › Dark Mode, “Adapt mail that sets its own colours”: in a dark appearance, styled mail
    /// that declares its own colours opens adapted to the theme's inks (on, the default) or as sent on a white page
    /// (off). ⇧⌘O still switches one message. The reader reads it for every render.
    @Published var adaptsMailColours: Bool {
        didSet { defaults.set(adaptsMailColours, forKey: Key.adaptsMailColours) }
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

    /// The account scope an earlier launch left the main window on, or nil when none is saved. Not a setting: the
    /// window saves it whenever the scope changes and opens on it at the next launch. The demo's is kept apart,
    /// so trying the demo never changes the scope the user's own accounts open on.
    func savedAccountScope(demo: Bool) -> AccountScope? {
        guard let raw = defaults.string(forKey: demo ? Key.demoAccountScope : Key.accountScope), !raw.isEmpty else { return nil }
        return raw == Self.unifiedScopeValue ? .unified : .account(AccountID(raw))
    }

    /// Saves `scope` for the next launch; nil forgets it, so the next launch opens on All Inboxes.
    func saveAccountScope(_ scope: AccountScope?, demo: Bool) {
        let key = demo ? Key.demoAccountScope : Key.accountScope
        switch scope {
        case nil: defaults.removeObject(forKey: key)
        case .unified?: defaults.set(Self.unifiedScopeValue, forKey: key)
        case .account(let id)?: defaults.set(id.rawValue, forKey: key)
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
            Key.typeface: QuireFont.Typeface.newYork.rawValue,
            Key.textSize: QuireFont.TextSize.default.rawValue,
            Key.listDensity: ListDensity.standard.rawValue,
            Key.showAccountInitials: false,
            Key.originalColorsNoticeDismissed: false,
            Key.accountInitialsTurnedOnAutomatically: false,
            Key.accountInitialsChosenByUser: false,
            Key.sevenAccountsNoticePending: false,
            Key.keepMail: MailRetention.everything.rawValue,
            Key.sendAction: SendAction.default.rawValue,
            Key.theme: QuireTheme.study.rawValue,
            Key.appearance: AppAppearance.automatic.rawValue,
            Key.adaptsMailColours: true,
        ])
        notificationsEnabled = defaults.bool(forKey: Key.notifications)
        showPreviews = defaults.bool(forKey: Key.previews)
        loadRemoteImages = defaults.bool(forKey: Key.remoteImages)
        keepMail = MailRetention(rawValue: defaults.string(forKey: Key.keepMail) ?? "") ?? .everything
        sendAction = SendAction(rawValue: defaults.string(forKey: Key.sendAction) ?? "") ?? .default
        let stored = defaults.double(forKey: Key.undoSend)
        undoSendDelay = AppSettings.undoSendChoices.contains(stored) ? stored : 5
        // Not pushed into QuireEnvironment here: the app does that at launch (a `--font` override may win), and
        // the throwaway settings tests build must not change what every other window draws.
        typeface = QuireFont.Typeface(rawValue: defaults.string(forKey: Key.typeface) ?? "") ?? .newYork
        // Not pushed either, for the same reasons; an unknown value is Default.
        textSize = QuireFont.TextSize(rawValue: defaults.string(forKey: Key.textSize) ?? "") ?? .default
        readerTextSize = defaults.string(forKey: Key.readerTextSize).flatMap(QuireFont.TextSize.init(rawValue:))
        // Not applied either: the app delegate does that at launch, where `--theme` and `--appearance` may win. A value
        // this version does not know (a theme from a later one) is the default, so every install opens as it did.
        theme = QuireTheme(rawValue: defaults.string(forKey: Key.theme) ?? "") ?? .study
        appearance = AppAppearance(rawValue: defaults.string(forKey: Key.appearance) ?? "") ?? .automatic
        adaptsMailColours = defaults.object(forKey: Key.adaptsMailColours) as? Bool ?? true
        listDensity = ListDensity(rawValue: defaults.string(forKey: Key.listDensity) ?? "") ?? .standard
        showAccountInitials = defaults.bool(forKey: Key.showAccountInitials)
        originalColorsNoticeDismissed = defaults.bool(forKey: Key.originalColorsNoticeDismissed)
        accountInitialsTurnedOnAutomatically = defaults.bool(forKey: Key.accountInitialsTurnedOnAutomatically)
        accountInitialsChosenByUser = defaults.bool(forKey: Key.accountInitialsChosenByUser)
        sevenAccountsNoticePending = defaults.bool(forKey: Key.sevenAccountsNoticePending)
        applyUndoSendDelay()
        ConversationViewController.loadRemoteImages = loadRemoteImages
    }

    /// Makes the saved choice what Quire draws in. Called by `typeface`'s observer; the app delegate sets the
    /// environment itself at launch.
    func applyTypeface() {
        QuireEnvironment.shared.setTypeface(typeface)
    }

    /// Makes the saved Text size what the list, the reader and the composer set their text at. Called by `textSize`'s
    /// observer; the app delegate sets the environment itself at launch.
    func applyTextSize() {
        QuireEnvironment.shared.setTextSize(textSize)
    }

    /// Makes the saved theme what every window draws. Called by `theme`'s observer; the app delegate sets the
    /// environment itself at launch. The `list.theme` interval (the theme budget in docs/ARCHITECTURE.md) is taken here,
    /// not in the list: the environment runs its redraw sweep after every observer of the change, the list's among them,
    /// so only the caller sees the rows rebuilt and every view marked as one span.
    func applyTheme() {
        let state = ListSignposts.signposter.beginInterval("list.theme")
        defer { ListSignposts.signposter.endInterval("list.theme", state) }
        QuireEnvironment.shared.setTheme(theme)
    }

    /// Shows the saved appearance. Called by `appearance`'s observer; the app delegate applies it itself at launch.
    func applyAppearance() {
        NSApplication.shared.appearance = appearance.nsAppearance
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
