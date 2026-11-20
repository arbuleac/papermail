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

    nonisolated static let undoSendChoices: [TimeInterval] = [5, 10, 20]

    /// Posted after the row display preferences below change (density, account faces), so AppKit views that
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
        /// The Font setting's key from when it was Reading font; kept, with its raw values, so the choice carries over.
        static let typeface = "readingFont"
        static let textSize = "textSize"
        /// The reader's own size, from ⌘+ and ⌘−; absent while the reader follows Text size.
        static let readerTextSize = "readerTextSize"
        static let listDensity = "listDensity"
        // Named for the initial tile the faces replaced (Quire 1.10), and kept, so a choice made then still holds.
        static let showAccountFaces = "showAccountInitials"
        static let originalColorsNoticeDismissed = "originalColorsNoticeDismissed"
        static let accountFacesTurnedOnAutomatically = "accountInitialsTurnedOnAutomatically"
        static let accountFacesChosenByUser = "accountInitialsChosenByUser"
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
        /// The main window's day column (spec §5.54): on by default; D hides it.
        static let showsDayColumn = "showsDayColumn"
        /// Some account had granted the calendar permission when the engine last said (spec §5.54, the calendar toggle).
        static let hasCalendarAccess = "hasCalendarAccess"
        /// Settings › General › Analytics and reports (`CrashReporting` and `Analytics` read it at launch, before the app
        /// delegate exists). Named for crash reports, which it governed first, so a choice made then still holds.
        static let sendsAnalyticsAndReports = CrashReporting.enabledDefaultsKey
        /// Settings › AI › Provider (§5.56): an `AIProviderKind` raw value; absent while Help Me Write is off.
        static let aiProvider = "aiProvider"
        /// The model chosen for each provider, under this prefix and the provider's raw value.
        static let aiModelPrefix = "aiModel."
        /// The CLI chosen with Choose… for Claude Code and Codex, under this prefix and the provider's raw value.
        static let aiCLIPathPrefix = "aiCLIPath."
        /// The providers the user allowed to receive a conversation (the consent sheet's Allow), as raw values.
        static let aiConsent = "aiConsent"
        /// The demo's own, so an Allow given where nothing leaves the Mac never stands for the user's real mail.
        static let demoAIConsent = "aiConsent.demo"
        /// The demo's Allows for a CLI it runs for real (`--live-ai-clis`), apart again: an Allow on the demo's “Nothing
        /// is sent” sheet never stands for a send.
        static let liveDemoAIConsent = "aiConsent.demo.live"
        /// The demo's provider, models and CLIs, kept apart for the same reason: a choice made while trying the demo
        /// never turns Help Me Write on for the user's own mail.
        static let demoAIProvider = "aiProvider.demo"
        static let demoAIModelPrefix = "demoAIModel."
        static let demoAICLIPathPrefix = "demoAICLIPath."
    }

    /// Account ids are UUIDs, so this can never be one.
    private static let unifiedScopeValue = "unified"

    /// Spec §4.2: with this many accounts, colours alone can look alike, so account faces turn on once.
    static let accountFacesThreshold = 7

    private let defaults: UserDefaults

    @Published var notificationsEnabled: Bool {
        didSet {
            defaults.set(notificationsEnabled, forKey: Key.notifications)
            if oldValue != notificationsEnabled { report(.notifications(notificationsEnabled)) }
        }
    }

    /// Sender and subject in the notification body. On by default: this is a personal client on the user's own Mac.
    @Published var showPreviews: Bool {
        didSet {
            defaults.set(showPreviews, forKey: Key.previews)
            if oldValue != showPreviews { report(.notificationPreviews(showPreviews)) }
        }
    }

    /// Read live: by the sanitizer for bodies synced from now on, and by the reader, which renders every
    /// body under a policy that blocks remote fetches while this is off, whatever the body was stored with.
    @Published var loadRemoteImages: Bool {
        didSet {
            defaults.set(loadRemoteImages, forKey: Key.remoteImages)
            applyRemoteImages()
            if oldValue != loadRemoteImages { report(.remoteImages(loadRemoteImages)) }
        }
    }

    /// Spec §5.40 General › Keep mail on this Mac: how far back bodies stay whole on this Mac. Each environment's engine
    /// follows it (`AppEnvironment.follow`), sweeping at once when it narrows; Everything is the default.
    @Published var keepMail: MailRetention {
        didSet {
            defaults.set(keepMail.rawValue, forKey: Key.keepMail)
            if oldValue != keepMail { report(.keepMail(keepMail)) }
        }
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
            if oldValue != sendAction {
                NotificationCenter.default.post(name: SendActionPreference.didChange, object: self)
                report(.sendAction(sendAction))
            }
        }
    }

    @Published var undoSendDelay: TimeInterval {
        didSet {
            defaults.set(undoSendDelay, forKey: Key.undoSend)
            applyUndoSendDelay()
            if oldValue != undoSendDelay { report(.undoSend(undoSendDelay)) }
        }
    }

    /// Spec §4.4, §5.40 Appearance › Font: the face every New York role is set in, app-wide. A change is saved and
    /// pushed into `QuireEnvironment` at once, so everything on screen switches face live.
    @Published var typeface: QuireFont.Typeface {
        didSet {
            defaults.set(typeface.rawValue, forKey: Key.typeface)
            applyTypeface()
            if oldValue != typeface { report(.font(typeface)) }
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
            if oldValue != textSize {
                readerTextSize = nil
                report(.textSize(textSize))
            }
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

    /// Spec §4.16, §5.40 Appearance › Theme. A choice is saved and pushed into `QuireEnvironment` at once, so every
    /// window, Settings included, re-themes live. Pushed even when it equals the saved one, as `typeface` is: under
    /// `--theme` the app draws another theme than Settings shows chosen, and choosing the shown one must still apply
    /// it. The environment announces nothing when its theme does not change.
    @Published var theme: QuireTheme {
        didSet {
            defaults.set(theme.rawValue, forKey: Key.theme)
            applyTheme()
            if oldValue != theme { report(.theme(theme)) }
        }
    }

    /// Spec §5.40 Appearance › Appearance: Automatic, Light or Dark for this app. A change is saved and applied at once.
    @Published var appearance: AppAppearance {
        didSet {
            defaults.set(appearance.rawValue, forKey: Key.appearance)
            if oldValue != appearance {
                applyAppearance()
                report(.appearance(appearance))
            }
        }
    }

    /// Spec §5.14, §5.40 Appearance › Dark Mode, “Adapt mail that sets its own colours”: in a dark appearance, styled mail
    /// that declares its own colours opens adapted to the theme's inks (on, the default) or as sent on a white page
    /// (off). ⇧⌘O still switches one message. The reader reads it for every render.
    @Published var adaptsMailColours: Bool {
        didSet {
            defaults.set(adaptsMailColours, forKey: Key.adaptsMailColours)
            if oldValue != adaptsMailColours { report(.adaptMailColours(adaptsMailColours)) }
        }
    }

    @Published var listDensity: ListDensity {
        didSet {
            defaults.set(listDensity.rawValue, forKey: Key.listDensity)
            postDisplayChange()
            if oldValue != listDensity { report(.listDensity(listDensity)) }
        }
    }

    /// Spec §5.7: the account's face (or its initial) before the time in unified views, a second, non-colour account cue.
    @Published var showAccountFaces: Bool {
        didSet {
            defaults.set(showAccountFaces, forKey: Key.showAccountFaces)
            postDisplayChange()
        }
    }

    /// Spec §5.16: the Original colors notice is shown until the user dismisses it once.
    @Published var originalColorsNoticeDismissed: Bool {
        didSet { defaults.set(originalColorsNoticeDismissed, forKey: Key.originalColorsNoticeDismissed) }
    }

    /// Spec §5.40 Seven accounts: account faces were turned on by a seventh account, not by the user.
    /// While this holds and the user has not touched the checkbox, General captions it.
    @Published private(set) var accountFacesTurnedOnAutomatically: Bool {
        didSet { defaults.set(accountFacesTurnedOnAutomatically, forKey: Key.accountFacesTurnedOnAutomatically) }
    }

    /// The user changed Show account faces themselves; their choice is kept and an eighth account does not
    /// turn it back on.
    @Published private(set) var accountFacesChosenByUser: Bool {
        didSet { defaults.set(accountFacesChosenByUser, forKey: Key.accountFacesChosenByUser) }
    }

    /// Settings › Accounts shows the seven-accounts notice until it is dismissed or followed, across launches.
    @Published var sevenAccountsNoticePending: Bool {
        didSet { defaults.set(sevenAccountsNoticePending, forKey: Key.sevenAccountsNoticePending) }
    }

    /// General's caption under the Rows checkbox: “Turned on when you added a seventh account.”
    var showsSevenAccountsCaption: Bool {
        showAccountFaces && accountFacesTurnedOnAutomatically && !accountFacesChosenByUser
    }

    /// The Rows checkbox: the user's own choice, which ends the automatic state for good.
    func setShowAccountFacesByUser(_ on: Bool) {
        accountFacesChosenByUser = true
        sevenAccountsNoticePending = false
        if showAccountFaces != on {
            showAccountFaces = on
            report(.accountFaces(on))
        }
    }

    /// Called after an account is added. The seventh account turns faces on, once ever, unless the user
    /// already chose (spec §4.2).
    func accountWasAdded(totalAccounts: Int) {
        guard totalAccounts >= Self.accountFacesThreshold, !accountFacesTurnedOnAutomatically, !accountFacesChosenByUser,
              !showAccountFaces else { return }
        accountFacesTurnedOnAutomatically = true
        sevenAccountsNoticePending = true
        showAccountFaces = true
    }

    /// The main window's day column is on (spec §5.54, D): kept here rather than in the split view's autosave, so the
    /// window opens with the column as it was left, as it does with a hidden rail, and tests keep theirs apart. Not a
    /// setting in Settings: D, View › Hide Day and the calendar toggle at the window's trailing edge change it.
    @Published var showsDayColumn: Bool {
        didSet { defaults.set(showsDayColumn, forKey: Key.showsDayColumn) }
    }

    /// Settings › General › Analytics and reports: crash reports (Sentry) and analytics (TelemetryDeck) together, on
    /// unless turned off. Turning it off stops both at once and deletes what they had queued; on starts crash reports
    /// again, and analytics too unless it already ran in this process, when it waits for the next launch
    /// (`CrashReporting.setEnabled`, `Analytics.setEnabled`).
    @Published var sendsAnalyticsAndReports: Bool {
        didSet {
            guard oldValue != sendsAnalyticsAndReports else { return }
            defaults.set(sendsAnalyticsAndReports, forKey: Key.sendsAnalyticsAndReports)
            onAnalyticsAndReportsChanged(sendsAnalyticsAndReports)
        }
    }

    /// Applies Analytics and reports; the app's crash reporter and analytics unless a test sets its own.
    var onAnalyticsAndReportsChanged: (Bool) -> Void = { on in
        CrashReporting.setEnabled(on)
        Analytics.setEnabled(on)
    }

    /// Whether some account had granted the calendar permission when the engine last said. Not a setting: the main
    /// window keeps it so the calendar toggle (and a hidden column's strip) is in place from a launch's first frame,
    /// before the engine has looked at any account's permission.
    @Published var hasCalendarAccess: Bool {
        didSet { if oldValue != hasCalendarAccess { defaults.set(hasCalendarAccess, forKey: Key.hasCalendarAccess) } }
    }

    // MARK: Help Me Write (§5.56)

    /// Settings › AI › Provider: where Help Me Write sends a conversation when the user asks it to write. Nil is Off, the
    /// default, and nothing is ever sent while it is. The demo writer is never a choice, so it is never stored.
    @Published var aiProvider: AIProviderKind? {
        didSet { if oldValue != aiProvider { Self.store(aiProvider, in: defaults, key: Key.aiProvider) } }
    }

    /// The demo's own choice of provider, kept apart: Off until chosen in the demo, and never the user's.
    @Published var demoAIProvider: AIProviderKind? {
        didSet { if oldValue != demoAIProvider { Self.store(demoAIProvider, in: defaults, key: Key.demoAIProvider) } }
    }

    /// The model chosen for each provider, so switching providers keeps each one's choice. Absent is the provider's
    /// default (the CLI's own for Claude Code and Codex).
    @Published private(set) var aiModels: [AIProviderKind: String]

    /// The CLI the user chose with Choose… for Claude Code or Codex; absent means the standard folders.
    @Published private(set) var aiCLIPaths: [AIProviderKind: String]

    /// The demo's models and CLIs, as `aiModels` and `aiCLIPaths`, kept apart.
    @Published private(set) var demoAIModels: [AIProviderKind: String]
    @Published private(set) var demoAICLIPaths: [AIProviderKind: String]

    /// The providers the user allowed to receive a conversation, outside the demo.
    @Published private(set) var aiConsent: Set<AIProviderKind>

    /// The demo's Allows, kept apart: nothing leaves the Mac there, so they never stand for the user's real mail.
    @Published private(set) var demoAIConsent: Set<AIProviderKind>

    /// The demo's Allows for its CLIs run for real (`--live-ai-clis`): the conversation does leave the Mac there, so an
    /// Allow given where replies are made up never counts for them.
    @Published private(set) var liveDemoAIConsent: Set<AIProviderKind>

    /// What Help Me Write uses now for the user's own mail, or nil while it is off.
    var aiConfiguration: AIProviderConfiguration? { aiConfiguration(demo: false) }

    /// What Help Me Write uses now, the demo's in the demo, or nil while it is off there.
    func aiConfiguration(demo: Bool) -> AIProviderConfiguration? {
        aiProvider(demo: demo).map { kind in
            AIProviderConfiguration(kind: kind, model: aiModel(for: kind, demo: demo), cliPath: aiCLIPath(for: kind, demo: demo))
        }
    }

    func aiProvider(demo: Bool) -> AIProviderKind? {
        demo ? demoAIProvider : aiProvider
    }

    func setAIProvider(_ kind: AIProviderKind?, demo: Bool) {
        if demo { demoAIProvider = kind } else { aiProvider = kind }
    }

    func aiModel(for kind: AIProviderKind, demo: Bool) -> String? {
        (demo ? demoAIModels : aiModels)[kind]
    }

    func aiCLIPath(for kind: AIProviderKind, demo: Bool) -> String? {
        (demo ? demoAICLIPaths : aiCLIPaths)[kind]
    }

    func setAIModel(_ model: String?, for kind: AIProviderKind, demo: Bool = false) {
        let value = model.flatMap { $0.isEmpty ? nil : $0 }
        if demo { demoAIModels[kind] = value } else { aiModels[kind] = value }
        Self.store(value, in: defaults, key: (demo ? Key.demoAIModelPrefix : Key.aiModelPrefix) + kind.rawValue)
    }

    func setAICLIPath(_ path: String?, for kind: AIProviderKind, demo: Bool = false) {
        let value = path.flatMap { $0.isEmpty ? nil : $0 }
        if demo { demoAICLIPaths[kind] = value } else { aiCLIPaths[kind] = value }
        Self.store(value, in: defaults, key: (demo ? Key.demoAICLIPathPrefix : Key.aiCLIPathPrefix) + kind.rawValue)
    }

    /// The demo writer is never a choice, so it is never stored.
    private static func store(_ kind: AIProviderKind?, in defaults: UserDefaults, key: String) {
        if let kind, kind != .demo { defaults.set(kind.rawValue, forKey: key) } else { defaults.removeObject(forKey: key) }
    }

    private static func store(_ value: String?, in defaults: UserDefaults, key: String) {
        if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
    }

    /// Whether the user allowed `kind` to receive a conversation: the demo's Allows in the demo (`live`: those for a CLI the
    /// demo runs for real), the real ones elsewhere.
    func hasAIConsent(for kind: AIProviderKind, demo: Bool, live: Bool = false) -> Bool {
        if !demo { return aiConsent.contains(kind) }
        return (live ? liveDemoAIConsent : demoAIConsent).contains(kind)
    }

    /// The consent sheet's Allow (`given`), or Settings › AI's Forget, which makes the sheet ask again next time.
    func setAIConsent(_ given: Bool, for kind: AIProviderKind, demo: Bool, live: Bool = false) {
        var kinds = !demo ? aiConsent : live ? liveDemoAIConsent : demoAIConsent
        if given { kinds.insert(kind) } else { kinds.remove(kind) }
        let stored = kinds.map(\.rawValue).sorted()
        if !demo {
            aiConsent = kinds
            defaults.set(stored, forKey: Key.aiConsent)
        } else if live {
            liveDemoAIConsent = kinds
            defaults.set(stored, forKey: Key.liveDemoAIConsent)
        } else {
            demoAIConsent = kinds
            defaults.set(stored, forKey: Key.demoAIConsent)
        }
    }

    private static func storedProvider(_ defaults: UserDefaults, _ key: String) -> AIProviderKind? {
        defaults.string(forKey: key).flatMap(AIProviderKind.init(rawValue:)).flatMap { AIProviderKind.selectable.contains($0) ? $0 : nil }
    }

    private static func storedKinds(_ defaults: UserDefaults, _ key: String) -> Set<AIProviderKind> {
        Set((defaults.stringArray(forKey: key) ?? []).compactMap(AIProviderKind.init(rawValue:)).filter { $0 != .demo })
    }

    private static func storedValues(_ defaults: UserDefaults, prefix: String) -> [AIProviderKind: String] {
        var values: [AIProviderKind: String] = [:]
        for kind in AIProviderKind.selectable {
            if let value = defaults.string(forKey: prefix + kind.rawValue), !value.isEmpty { values[kind] = value }
        }
        return values
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
            Key.showAccountFaces: false,
            Key.originalColorsNoticeDismissed: false,
            Key.accountFacesTurnedOnAutomatically: false,
            Key.accountFacesChosenByUser: false,
            Key.sevenAccountsNoticePending: false,
            Key.keepMail: MailRetention.everything.rawValue,
            Key.sendAction: SendAction.default.rawValue,
            Key.theme: QuireTheme.study.rawValue,
            Key.appearance: AppAppearance.automatic.rawValue,
            Key.adaptsMailColours: true,
            Key.showsDayColumn: true,
            Key.sendsAnalyticsAndReports: true,
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
        showAccountFaces = defaults.bool(forKey: Key.showAccountFaces)
        originalColorsNoticeDismissed = defaults.bool(forKey: Key.originalColorsNoticeDismissed)
        accountFacesTurnedOnAutomatically = defaults.bool(forKey: Key.accountFacesTurnedOnAutomatically)
        accountFacesChosenByUser = defaults.bool(forKey: Key.accountFacesChosenByUser)
        sevenAccountsNoticePending = defaults.bool(forKey: Key.sevenAccountsNoticePending)
        sendsAnalyticsAndReports = defaults.bool(forKey: Key.sendsAnalyticsAndReports)
        showsDayColumn = defaults.bool(forKey: Key.showsDayColumn)
        hasCalendarAccess = defaults.bool(forKey: Key.hasCalendarAccess)
        // A raw value this version does not know (a provider from a later one) is Off: nothing is sent to a guess.
        aiProvider = Self.storedProvider(defaults, Key.aiProvider)
        demoAIProvider = Self.storedProvider(defaults, Key.demoAIProvider)
        aiModels = Self.storedValues(defaults, prefix: Key.aiModelPrefix)
        aiCLIPaths = Self.storedValues(defaults, prefix: Key.aiCLIPathPrefix)
        demoAIModels = Self.storedValues(defaults, prefix: Key.demoAIModelPrefix)
        demoAICLIPaths = Self.storedValues(defaults, prefix: Key.demoAICLIPathPrefix)
        aiConsent = Self.storedKinds(defaults, Key.aiConsent)
        demoAIConsent = Self.storedKinds(defaults, Key.demoAIConsent)
        liveDemoAIConsent = Self.storedKinds(defaults, Key.liveDemoAIConsent)
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

    /// A setting the user changed, for analytics: which, and its new value from a closed set.
    private func report(_ change: AnalyticsSignal.SettingChange) {
        Analytics.send(.settingChanged(change))
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
