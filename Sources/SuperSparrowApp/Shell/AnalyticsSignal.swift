import Foundation
import SSCore
import SSDesign

/// One product-analytics signal, from a closed catalog (docs/ANALYTICS-AND-REPORTS.md, "What is sent"). Every parameter
/// value is an enum's raw value, a count put in a bucket or a duration put in a bucket, so no call site can hand
/// TelemetryDeck text: nothing here can carry mail, a subject, an address, an account's name, search words, a file name
/// or a URL. `Analytics.send` adds `mode` (demo or accounts); TelemetryDeck adds its own defaults (app version, macOS,
/// the Mac's model, screen, locale and time zone, when and how often the app is used), listed in the doc.
enum AnalyticsSignal: Equatable, Sendable {
    /// Once a launch, when the first main window is on screen.
    case launched(Launch)
    case settingsOpened
    case settingChanged(SettingChange)
    /// A change to mail the user made: how many conversations it took, and where it came from.
    case mailAction(MailAction, Trigger, conversations: Int)
    /// A composer window opened (one already open only brought forward is none). The trigger only for the app's own
    /// ways in: a mail link or a service comes from another app.
    case composeStarted(ComposeKind, ComposeOrigin, Trigger?)
    /// A composer's message handed to the outbox (its undo window still to run).
    case messageSent(ComposeKind, archives: Bool)
    case sendLaterScheduled(SendSource)
    case sendUndone(SendSource)
    case quickReplySent(replyAll: Bool, archives: Bool)
    /// A search of this Mac, once the user stopped typing (`Analytics.searchSettleDelay`).
    case localSearch(operators: Int, results: Int)
    /// Search Gmail or Microsoft for more finished: how, with how many operators, what it added, and how long it took.
    case serverSearch(ServerSearchOutcome, operators: Int, found: Int, seconds: Double)
    case readerWindowOpened(Trigger)
    /// The user moved to another view or scope (the rail, the title menu, the View and Go menus, ⌘0…⌘9, a G-sequence):
    /// which view, and whether All Inboxes or one account, never which.
    case viewOpened(MailboxView, unified: Bool, Trigger)
    case dayColumn(shown: Bool, Trigger)
    case weekOpened(Trigger)
    case timeBlocked(Trigger)
    case invitationAnswered(InvitationAnswer)
    /// A step taken back: an undo-history group reverted (Z, ⌘Z, a toast's Undo).
    case undo(Trigger)
    case accountAdded(Provider)
    case accountRemoved(Provider)
    /// A timing where the app keeps an `os_signpost` interval, sampled (`Analytics.performanceSampleRate`).
    case performance(PerformanceSample, seconds: Double)

    // MARK: Vocabulary

    /// The signal's name in TelemetryDeck.
    enum Name: String, CaseIterable, Sendable {
        case launched = "App.launched"
        case settingsOpened = "Settings.opened"
        case settingChanged = "Settings.changed"
        case mailAction = "Mail.action"
        case composeStarted = "Compose.started"
        case messageSent = "Compose.sent"
        case sendLaterScheduled = "Compose.sendLaterScheduled"
        case sendUndone = "Compose.sendUndone"
        case quickReplySent = "QuickReply.sent"
        case localSearch = "Search.local"
        case serverSearch = "Search.server"
        case readerWindowOpened = "Reader.windowOpened"
        case viewOpened = "View.opened"
        case dayColumn = "Calendar.dayColumn"
        case weekOpened = "Calendar.weekOpened"
        case timeBlocked = "Calendar.timeBlocked"
        case invitationAnswered = "Calendar.invitationAnswered"
        case undo = "Undo.used"
        case accountAdded = "Account.added"
        case accountRemoved = "Account.removed"
        case listRefresh = "Performance.listRefresh"
        case conversationOpen = "Performance.conversationOpen"
        case search = "Performance.search"
    }

    /// Where a step came from. A key wins whenever a key is being handled (a menu item's key equivalent, a key in a
    /// reader window); otherwise what the way in said (`Analytics.from`), else a menu.
    enum Trigger: String, CaseIterable, Sendable {
        case key
        case menu
        /// A button in the reader's header or the page's own (Reply, Archive, Star…).
        case toolbar
        case swipe
        /// Rows dragged onto a rail folder or the calendar.
        case drag
        /// A double-click on a row.
        case click
        /// A click on the account rail: a folder, an account, All Inboxes.
        case rail
        /// The Undo button on a toast.
        case toast
        /// A notification's Archive or Mark as Read.
        case notification
    }

    enum MailAction: String, CaseIterable, Sendable {
        case archive, trash, spam, moveToInbox, star, unstar, markRead, markUnread, later, mute, unmute, unsubscribe
        case alwaysArchiveSender, blockSender

        /// The action a metadata change is, as the user took it; nil for changes the user never takes as a mail action
        /// (an undo's inverse, an invitation's answer).
        init?(_ change: MetadataChange) {
            switch change {
            case .archive: self = .archive
            case .trash: self = .trash
            case .markSpam: self = .spam
            case .moveToInbox, .restoreFromTrash: self = .moveToInbox
            case .setStarred(let on): self = on ? .star : .unstar
            case .setRead(let read): self = read ? .markRead : .markUnread
            case .unsubscribe: self = .unsubscribe
            case .markNotSpam, .answerInvitation: return nil
            }
        }
    }

    enum ComposeKind: String, CaseIterable, Sendable {
        case new, reply, replyAll, forward
        /// A kept draft opened again: Continue Editing, or a reply or forward that was kept (sent with the kind it is).
        case draft

        init(_ mode: ComposeMode) {
            switch mode {
            case .new: self = .new
            case .reply(_, let all): self = all ? .replyAll : .reply
            case .forward: self = .forward
            }
        }
    }

    /// What opened a composer: the app itself, a `mailto` link from another app, or the Services menu.
    enum ComposeOrigin: String, CaseIterable, Sendable {
        case app, mailLink, service
    }

    enum SendSource: String, CaseIterable, Sendable {
        case composer, quickReply
        /// A Send Later message taken back from the outbox with the toast's Undo.
        case sendLater
    }

    enum ServerSearchOutcome: String, CaseIterable, Sendable {
        case found, nothing, failed
    }

    enum InvitationAnswer: String, CaseIterable, Sendable {
        case accept, tentative, decline

        init?(_ response: InvitationResponse) {
            switch response {
            case .accepted: self = .accept
            case .tentative: self = .tentative
            case .declined: self = .decline
            case .needsAction: return nil
            }
        }
    }

    enum Provider: String, CaseIterable, Sendable {
        case gmail, microsoft

        init(_ kind: ProviderKind) {
            switch kind {
            case .gmail: self = .gmail
            case .microsoft: self = .microsoft
            }
        }
    }

    enum PerformanceSample: String, CaseIterable, Sendable {
        case listRefresh, conversationOpen, search
    }

    enum Toggle: String, CaseIterable, Sendable {
        case on, off

        init(_ on: Bool) { self = on ? .on : .off }
    }

    enum DayColumnState: String, CaseIterable, Sendable {
        case shown, hidden
    }

    /// All Inboxes, or one account (never which).
    enum Scope: String, CaseIterable, Sendable {
        case unified, account
    }

    /// The app as a launch found it: how long the launch took, how many accounts of each kind, and how it looks.
    struct Launch: Equatable, Sendable {
        var seconds: Double
        var gmailAccounts: Int
        var microsoftAccounts: Int
        var theme: QuireTheme
        var appearance: AppAppearance
        var density: AppSettings.ListDensity
        var textSize: QuireFont.TextSize
        var typeface: QuireFont.Typeface
    }

    /// A setting changed, in Settings or by its own control elsewhere (Send's drop-down, View › Compact Rows), with its
    /// new value.
    enum SettingChange: Equatable, Sendable {
        case listDensity(AppSettings.ListDensity)
        case accountInitials(Bool)
        case undoSend(TimeInterval)
        case remoteImages(Bool)
        case notifications(Bool)
        case notificationPreviews(Bool)
        case keepMail(MailRetention)
        case theme(QuireTheme)
        case appearance(AppAppearance)
        case font(QuireFont.Typeface)
        case textSize(QuireFont.TextSize)
        case adaptMailColours(Bool)
        case sendAction(SendAction)
        /// At login: macOS now opens SuperSparrow at login, or no longer does (waiting for approval counts as on).
        case launchAtLogin(Bool)
        /// Mail links: SuperSparrow became the default mail app. Only on: the app cannot hand the role back.
        case defaultMailApp

        enum Setting: String, CaseIterable, Sendable {
            case listDensity, accountInitials, undoSend, remoteImages, notifications, notificationPreviews, keepMail, theme
            case appearance, font, textSize, adaptMailColours, sendAction, launchAtLogin, defaultMailApp
        }

        var setting: Setting {
            switch self {
            case .listDensity: return .listDensity
            case .accountInitials: return .accountInitials
            case .undoSend: return .undoSend
            case .remoteImages: return .remoteImages
            case .notifications: return .notifications
            case .notificationPreviews: return .notificationPreviews
            case .keepMail: return .keepMail
            case .theme: return .theme
            case .appearance: return .appearance
            case .font: return .font
            case .textSize: return .textSize
            case .adaptMailColours: return .adaptMailColours
            case .sendAction: return .sendAction
            case .launchAtLogin: return .launchAtLogin
            case .defaultMailApp: return .defaultMailApp
            }
        }

        /// The new value, as one of `values(of:)`.
        var value: String {
            switch self {
            case .listDensity(let density): return density.rawValue
            case .accountInitials(let on), .remoteImages(let on), .notifications(let on), .notificationPreviews(let on),
                 .adaptMailColours(let on), .launchAtLogin(let on):
                return Toggle(on).rawValue
            case .defaultMailApp: return Toggle.on.rawValue
            case .undoSend(let seconds): return Self.undoSendValue(seconds)
            case .keepMail(let retention): return retention.rawValue
            case .theme(let theme): return theme.rawValue
            case .appearance(let appearance): return appearance.rawValue
            case .font(let typeface): return typeface.rawValue
            case .textSize(let size): return size.rawValue
            case .sendAction(let action): return action.rawValue
            }
        }

        /// Undo send's three choices; anything else (a value written by hand) is "other".
        static func undoSendValue(_ seconds: TimeInterval) -> String {
            AppSettings.undoSendChoices.contains(seconds) ? "\(Int(seconds))s" : "other"
        }

        /// Every value `setting` can report.
        static func values(of setting: Setting) -> [String] {
            switch setting {
            case .listDensity: return AppSettings.ListDensity.allCases.map(\.rawValue)
            case .accountInitials, .remoteImages, .notifications, .notificationPreviews, .adaptMailColours, .launchAtLogin:
                return Toggle.allCases.map(\.rawValue)
            case .defaultMailApp: return [Toggle.on.rawValue]
            case .undoSend: return AppSettings.undoSendChoices.map(undoSendValue) + ["other"]
            case .keepMail: return MailRetention.allCases.map(\.rawValue)
            case .theme: return QuireTheme.allCases.map(\.rawValue)
            case .appearance: return AppAppearance.allCases.map(\.rawValue)
            case .font: return QuireFont.Typeface.allCases.map(\.rawValue)
            case .textSize: return QuireFont.TextSize.allCases.map(\.rawValue)
            case .sendAction: return SendAction.allCases.map(\.rawValue)
            }
        }
    }

    // MARK: Buckets

    /// A count put in a range, so a signal says "2-5", never 3. Each range is a lower bound and its label.
    struct CountBuckets: Sendable {
        let ranges: [(from: Int, label: String)]

        func label(_ count: Int) -> String {
            ranges.last { count >= $0.from }?.label ?? ranges[0].label
        }

        var labels: [String] { ranges.map(\.label) }

        /// Conversations a mail action took.
        static let conversations = CountBuckets(ranges: [(0, "1"), (2, "2-5"), (6, "6-20"), (21, "21+")])
        /// Accounts of one kind.
        static let accounts = CountBuckets(ranges: [(0, "0"), (1, "1"), (2, "2"), (3, "3-5"), (6, "6+")])
        /// Search operators in a query (`from:`, `is:`, a leading minus…).
        static let operators = CountBuckets(ranges: [(0, "0"), (1, "1"), (2, "2"), (3, "3+")])
        /// Results a search listed; the list's first page holds 200, so "200+" is a full page.
        static let results = CountBuckets(ranges: [(0, "0"), (1, "1-10"), (11, "11-50"), (51, "51-199"), (200, "200+")])
    }

    /// A duration put in a range.
    struct DurationBuckets: Sendable {
        let ranges: [(from: Double, label: String)]

        func label(_ seconds: Double) -> String {
            ranges.last { seconds >= $0.from }?.label ?? ranges[0].label
        }

        var labels: [String] { ranges.map(\.label) }

        /// A launch, from the process starting to the first main window on screen.
        static let launch = DurationBuckets(ranges: [(0, "<0.5s"), (0.5, "0.5-1s"), (1, "1-2s"), (2, "2-5s"), (5, "5s+")])
        /// A search of the server: a network round trip, or several.
        static let serverSearch = DurationBuckets(ranges: [(0, "<0.5s"), (0.5, "0.5-1s"), (1, "1-2s"), (2, "2-5s"), (5, "5-10s"),
                                                           (10, "10s+")])
        /// The interactions the performance budgets name (16, 50 and 100 ms).
        static let interaction = DurationBuckets(ranges: [(0, "<16ms"), (0.016, "16-50ms"), (0.05, "50-100ms"), (0.1, "100-250ms"),
                                                          (0.25, "250ms-1s"), (1, "1s+")])
    }

    /// Every value each parameter can take. The tests hold every signal's parameters to it, and the doc lists it.
    static let vocabulary: [String: [String]] = {
        let words: [String: [String]] = [
            "mode": Analytics.Mode.allCases.map(\.rawValue),
            "launchTime": DurationBuckets.launch.labels,
            "gmailAccounts": CountBuckets.accounts.labels,
            "microsoftAccounts": CountBuckets.accounts.labels,
            "theme": QuireTheme.allCases.map(\.rawValue),
            "appearance": AppAppearance.allCases.map(\.rawValue),
            "density": AppSettings.ListDensity.allCases.map(\.rawValue),
            "textSize": QuireFont.TextSize.allCases.map(\.rawValue),
            "font": QuireFont.Typeface.allCases.map(\.rawValue),
            "setting": SettingChange.Setting.allCases.map(\.rawValue),
            "value": SettingChange.Setting.allCases.flatMap(SettingChange.values(of:)),
            "action": MailAction.allCases.map(\.rawValue),
            "trigger": Trigger.allCases.map(\.rawValue),
            "conversations": CountBuckets.conversations.labels,
            "kind": ComposeKind.allCases.map(\.rawValue),
            "origin": ComposeOrigin.allCases.map(\.rawValue),
            "archives": Toggle.allCases.map(\.rawValue),
            "source": SendSource.allCases.map(\.rawValue),
            "operators": CountBuckets.operators.labels,
            "results": CountBuckets.results.labels,
            "outcome": ServerSearchOutcome.allCases.map(\.rawValue),
            "searchTime": DurationBuckets.serverSearch.labels,
            "view": MailboxView.allCases.map(\.rawValue),
            "scope": Scope.allCases.map(\.rawValue),
            "state": DayColumnState.allCases.map(\.rawValue),
            "answer": InvitationAnswer.allCases.map(\.rawValue),
            "provider": Provider.allCases.map(\.rawValue),
            "duration": DurationBuckets.interaction.labels,
        ]
        // Settings' values repeat (on and off for every toggle): each once, in order.
        return words.mapValues { values in
            var seen = Set<String>()
            return values.filter { seen.insert($0).inserted }
        }
    }()

    /// How many operators a search uses: every term but a plain word or a quoted phrase, and every negated term. Words
    /// are counted, never sent.
    static func operators(in search: SearchQuery?) -> Int {
        (search?.terms ?? []).filter { term in
            switch term.kind {
            case .text, .phrase: return term.negated
            default: return true
            }
        }.count
    }

    // MARK: What is sent

    var name: Name {
        switch self {
        case .launched: return .launched
        case .settingsOpened: return .settingsOpened
        case .settingChanged: return .settingChanged
        case .mailAction: return .mailAction
        case .composeStarted: return .composeStarted
        case .messageSent: return .messageSent
        case .sendLaterScheduled: return .sendLaterScheduled
        case .sendUndone: return .sendUndone
        case .quickReplySent: return .quickReplySent
        case .localSearch: return .localSearch
        case .serverSearch: return .serverSearch
        case .readerWindowOpened: return .readerWindowOpened
        case .viewOpened: return .viewOpened
        case .dayColumn: return .dayColumn
        case .weekOpened: return .weekOpened
        case .timeBlocked: return .timeBlocked
        case .invitationAnswered: return .invitationAnswered
        case .undo: return .undo
        case .accountAdded: return .accountAdded
        case .accountRemoved: return .accountRemoved
        case .performance(let sample, _):
            switch sample {
            case .listRefresh: return .listRefresh
            case .conversationOpen: return .conversationOpen
            case .search: return .search
            }
        }
    }

    /// The signal's parameters, every value from `vocabulary`.
    var parameters: [String: String] {
        switch self {
        case .launched(let launch):
            return [
                "launchTime": DurationBuckets.launch.label(launch.seconds),
                "gmailAccounts": CountBuckets.accounts.label(launch.gmailAccounts),
                "microsoftAccounts": CountBuckets.accounts.label(launch.microsoftAccounts),
                "theme": launch.theme.rawValue,
                "appearance": launch.appearance.rawValue,
                "density": launch.density.rawValue,
                "textSize": launch.textSize.rawValue,
                "font": launch.typeface.rawValue,
            ]
        case .settingsOpened:
            return [:]
        case .settingChanged(let change):
            return ["setting": change.setting.rawValue, "value": change.value]
        case .mailAction(let action, let trigger, let count):
            return ["action": action.rawValue, "trigger": trigger.rawValue, "conversations": CountBuckets.conversations.label(count)]
        case .composeStarted(let kind, let origin, let trigger):
            var parameters = ["kind": kind.rawValue, "origin": origin.rawValue]
            if origin == .app, let trigger { parameters["trigger"] = trigger.rawValue }
            return parameters
        case .messageSent(let kind, let archives):
            return ["kind": kind.rawValue, "archives": Toggle(archives).rawValue]
        case .sendLaterScheduled(let source), .sendUndone(let source):
            return ["source": source.rawValue]
        case .quickReplySent(let replyAll, let archives):
            return ["kind": (replyAll ? ComposeKind.replyAll : .reply).rawValue, "archives": Toggle(archives).rawValue]
        case .localSearch(let operators, let results):
            return ["operators": CountBuckets.operators.label(operators), "results": CountBuckets.results.label(results)]
        case .serverSearch(let outcome, let operators, let found, let seconds):
            return ["outcome": outcome.rawValue, "operators": CountBuckets.operators.label(operators),
                    "results": CountBuckets.results.label(found), "searchTime": DurationBuckets.serverSearch.label(seconds)]
        case .readerWindowOpened(let trigger), .weekOpened(let trigger), .timeBlocked(let trigger), .undo(let trigger):
            return ["trigger": trigger.rawValue]
        case .viewOpened(let view, let unified, let trigger):
            return ["view": view.rawValue, "scope": (unified ? Scope.unified : .account).rawValue, "trigger": trigger.rawValue]
        case .dayColumn(let shown, let trigger):
            return ["state": (shown ? DayColumnState.shown : .hidden).rawValue, "trigger": trigger.rawValue]
        case .invitationAnswered(let answer):
            return ["answer": answer.rawValue]
        case .accountAdded(let provider), .accountRemoved(let provider):
            return ["provider": provider.rawValue]
        case .performance(_, let seconds):
            return ["duration": DurationBuckets.interaction.label(seconds)]
        }
    }

    /// TelemetryDeck's number for the signal, which its dashboard averages: a launch's or a server search's seconds (to
    /// the millisecond), a timing's milliseconds (to a tenth). A number, never text; none for a time that is not finite,
    /// which the SDK could not encode, and whose batch it would then retry for ever.
    var floatValue: Double? {
        let value: Double
        switch self {
        case .launched(let launch): value = (max(0, launch.seconds) * 1000).rounded() / 1000
        case .serverSearch(_, _, _, let seconds): value = (max(0, seconds) * 1000).rounded() / 1000
        case .performance(_, let seconds): value = (max(0, seconds) * 10_000).rounded() / 10
        default: return nil
        }
        return value.isFinite ? value : nil
    }
}
