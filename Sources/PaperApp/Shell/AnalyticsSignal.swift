import Foundation
import PaperCore
import PaperDesign

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
    /// Accept, Tentative or Decline: where it was given, what it answered, and how it went (through the mail or on the
    /// calendar alone).
    case invitationAnswered(InvitationAnswer, Surface, AnswerSpan, AnswerRoute)
    /// An event's details opened by the user (§5.54): what kind of event, and how. Never the details the week opens by
    /// itself beside the selected conversation's invitation.
    case detailsOpened(EventKind, Trigger)
    /// A step in an event's details, or Join on an event's face: once it took (a link once the opener took it, a copy
    /// once the pasteboard did).
    case eventAction(EventAction, Surface, Trigger)
    /// A step taken back: an undo-history group reverted (Z, ⌘Z, a toast's Undo).
    case undo(Trigger)
    case accountAdded(Provider)
    case accountRemoved(Provider)
    /// A Help me write write ended (§5.56; `AIWriter`'s milestones): which kind of provider wrote, how it ended and, by
    /// kind only, what was written, from what and where (`WriteDetails`). Never the instruction, the notes, the subject,
    /// the conversation, the model or a word of the draft, and none for a draft the demo makes up
    /// (`HelpMeWrite.analyticsSignal`).
    case helpMeWriteUsed(Writer, WriteEnding, WriteDetails?)
    /// Reader mode switched on or off from the reader (§5.59): its switch in the header, ⇧⌘R or View › Reader Mode. Never
    /// when its experiment's gate moved it (that is Settings › Experimental's change).
    case readerModeSwitched(on: Bool, Trigger)
    /// Show original or Show text on one message in reader mode (§5.59): the line the user clicked it on.
    case readerVersionSwitched(ReaderLine)
    /// A message's quoted text shown or hidden (§5.15): its mark, or “.”.
    case quotedText(shown: Bool, Trigger)
    /// Block trackers held trackers back in a conversation the reader showed (§5.60): how many, once a conversation per
    /// window and run.
    case trackersBlocked(count: Int)
    /// A link opened from a message went without its tracking parameters (§5.60).
    case linkCleaned
    /// An attachment opened, saved, copied or dragged out (§5.17).
    case attachmentUsed(AttachmentAction, Trigger)
    /// The sign-in that asks an account for a permission on top of what it holds (the server's sender rules, its
    /// calendar) ended: granted or not.
    case permissionAsked(Permission, granted: Bool, Provider)
    /// A sender rule removed with Settings › Accounts › Senders…'s − (§5.52).
    case senderRuleRemoved(Provider)
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
        case detailsOpened = "Calendar.detailsOpened"
        case eventAction = "Calendar.eventAction"
        case undo = "Undo.used"
        case accountAdded = "Account.added"
        case accountRemoved = "Account.removed"
        case helpMeWriteUsed = "HelpMeWrite.used"
        case readerModeSwitched = "ReaderMode.switched"
        case readerVersionSwitched = "ReaderMode.versionSwitched"
        case quotedText = "Reader.quotedText"
        case trackersBlocked = "Trackers.blocked"
        case linkCleaned = "Trackers.linkCleaned"
        case attachmentUsed = "Attachment.used"
        case permissionAsked = "Account.permission"
        case senderRuleRemoved = "SenderRule.removed"
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
        /// Rows dragged onto a rail folder or the calendar; files or a message's attachments dropped on the quick reply;
        /// the rail's edge dragged to show or hide its names.
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

    /// What an event's details were opened on.
    enum EventKind: String, CaseIterable, Sendable {
        /// An event the user is a guest of.
        case invitee
        /// The user's own (organized, a kind, no guests).
        case own
        /// Time set aside for a mail.
        case setAside
        /// The selected mail's invitation drawn from the mail.
        case pencil
        case later
        case sendLater
    }

    /// A step in an event's details.
    enum EventAction: String, CaseIterable, Sendable {
        case join, copyLink, phone, copyPhone, morePhones, copyMeetingID, copyPasscode, placeLink, notesLink, showAllGuests,
             showMoreNotes, showMail, remove, openIn
    }

    /// Where a calendar step was taken: the reader's invitation card, an event's details, an event's own Join.
    enum Surface: String, CaseIterable, Sendable {
        case reader, details, face
    }

    /// What an answer answered.
    enum AnswerSpan: String, CaseIterable, Sendable {
        case single, occurrence, series

        init(_ span: PaperCore.AnswerSpan) {
            switch span {
            case .single: self = .single
            case .occurrence: self = .occurrence
            case .series: self = .series
            }
        }

        /// What an invitation's mail answers: one occurrence (RECURRENCE-ID), the series (a repeat), else one event.
        init(_ invitation: CalendarInvitation) {
            self = invitation.recurrenceID != nil ? .occurrence : invitation.repeats != nil ? .series : .single
        }
    }

    /// How an answer went to the provider.
    enum AnswerRoute: String, CaseIterable, Sendable {
        case mail, calendar

        init(_ route: PaperCore.AnswerRoute) {
            self = route == .mail ? .mail : .calendar
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

    /// Help me write's provider, by kind only (`AIProviderKind`'s raw values, the four Settings › AI offers): never a
    /// model, a CLI's path or a key. The demo's made-up writer is none, since a reply it makes up sends nothing.
    enum Writer: String, CaseIterable, Sendable {
        case claudeAPI, claudeCode, openAIAPI, codex

        init?(_ kind: AIProviderKind) {
            switch kind {
            case .claudeAPI: self = .claudeAPI
            case .claudeCode: self = .claudeCode
            case .openAIAPI: self = .openAIAPI
            case .codex: self = .codex
            case .demo: return nil
            }
        }
    }

    /// How a write ended. Its start is no signal of its own: every write that starts ends once.
    enum WriteEnding: String, CaseIterable, Sendable {
        case finished, stopped, failed

        init?(_ milestone: AIWriteMilestone) {
            switch milestone {
            case .started: return nil
            case .finished: self = .finished
            case .stopped: self = .stopped
            case .failed: self = .failed
            }
        }
    }

    /// What a Help me write write wrote, what it worked from and how it was asked for, and where (§5.56): never the
    /// words.
    struct WriteDetails: Equatable, Sendable {
        var draft: WriteDraft
        /// An instruction came with it: the prompt line's words or a chip.
        var instruction: Bool
        /// Try again: written again from the notes the last reply came from.
        var retry: Bool
        var source: SendSource
        /// What was being written, in the composers' own kinds, so a write lines up with `Compose.started` and
        /// `Compose.sent`: a new message, a reply, a reply to all or a forward. Never `draft`.
        var kind: ComposeKind
        /// A subject was asked for with the message. Whether one came back and was set is not known as the signal is
        /// made, so it is not said.
        var subject: Bool
        /// For a selection's rewrite only: whether the user's draft around the selection went with it, or the selection
        /// alone. Nil for every other write.
        var around: WriteAround?
        /// For a rewrite that sent the draft around it and finished only: how the words beside the selection came out
        /// (the writer's milestone says, as the write ends). Nil otherwise.
        var join: WriteJoinResult?

        init(draft: WriteDraft, instruction: Bool, retry: Bool, source: SendSource, kind: ComposeKind, subject: Bool,
             around: WriteAround? = nil, join: WriteJoinResult? = nil) {
            self.draft = draft
            self.instruction = instruction
            self.retry = retry
            self.source = source
            self.kind = kind
            self.subject = subject
            self.around = around
            self.join = join
        }

        init(_ ask: WriteAsk, retry: Bool, source: SendSource, kind: ComposeKind, subject: Bool) {
            self.init(draft: WriteDraft(ask.draft), instruction: !ask.instruction.isEmpty, retry: retry, source: source,
                      kind: kind, subject: subject, around: ask.isRewrite ? (ask.around == nil ? .alone : .draft) : nil)
        }
    }

    /// What a selection's rewrite sent besides the selection (§5.56): the user's draft around it, or nothing of it.
    enum WriteAround: String, CaseIterable, Sendable {
        case draft, alone
    }

    /// How the words beside a rewritten selection came out (`WriteJoinOutcome`): no seam line came; the words before
    /// it, after it, or both were changed; or seam lines came and none passed the writer's checks.
    enum WriteJoinResult: String, CaseIterable, Sendable {
        case none, before, after, both, refused

        init(_ outcome: WriteJoinOutcome) {
            switch outcome {
            case .none: self = .none
            case .before: self = .before
            case .after: self = .after
            case .both: self = .both
            case .refused: self = .refused
            }
        }
    }

    /// The field's text a write started from (`WriteAsk.Draft`), by kind only.
    enum WriteDraft: String, CaseIterable, Sendable {
        case empty, notes, selection

        init(_ draft: WriteAsk.Draft) {
            switch draft {
            case .empty: self = .empty
            case .notes: self = .notes
            case .selection: self = .selection
            }
        }
    }

    /// The reader line the user switched a message's version on (§5.59): its text part, the text from its design, its
    /// snippet (each with Show original), or the message as sent (Show text). `RenderPayload.Message.ReaderView`'s names.
    enum ReaderLine: String, CaseIterable, Sendable {
        case text, extracted, snippet, original

        init(_ view: RenderPayload.ReaderView) {
            switch view {
            case .text: self = .text
            case .extracted: self = .extracted
            case .snippet: self = .snippet
            case .original: self = .original
            }
        }
    }

    /// What was done with an attachment (§5.17): Quick Look (a click on its chip, Space), the default app (a double click,
    /// Open), Download, Download all, Save As…, Copy, or a drag out of the reader (to the Finder or a composer).
    enum AttachmentAction: String, CaseIterable, Sendable {
        case quickLook, open, download, downloadAll, saveAs, copy, drag
    }

    /// A permission an account is asked for on top of the mail (§5.52, §5.54).
    enum Permission: String, CaseIterable, Sendable {
        case rules, calendar
    }

    enum PermissionResult: String, CaseIterable, Sendable {
        case granted, notGranted
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

    /// A setting changed, in Settings or by its own control elsewhere (Send's drop-down, View › Compact Rows, the rail's
    /// names), with its new value.
    enum SettingChange: Equatable, Sendable {
        case listDensity(AppSettings.ListDensity)
        case accountFaces(Bool)
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
        /// At login: macOS now opens Paper at login, or no longer does (waiting for approval counts as on).
        case launchAtLogin(Bool)
        /// Mail links: Paper became the default mail app. Only on: the app cannot hand the role back.
        case defaultMailApp
        /// Settings › Experimental (§5.58): Offer reader mode and Block trackers. Reader mode itself, switched from the
        /// reader, is a signal of its own (`readerModeSwitched`).
        case offerReaderMode(Bool)
        case blockTrackers(Bool)
        /// Settings › AI's Provider (§5.40): the kind chosen once turned on, or none; never the model or a key.
        case aiProvider(Writer?)
        /// Settings › Accounts' Face for an account (§5.10): chosen automatically, the letters, or a paper face (never
        /// which, nor whose).
        case accountFace(AccountFace)
        /// The rail shows its names beside its icons, or the icons alone again (§5.2), and how it was asked: View › Show
        /// Names in Rail, or a drag of the rail's edge.
        case railNames(Bool, Trigger)

        /// An account's face, by kind.
        enum FaceKind: String, CaseIterable, Sendable {
            case automatic, monogram, paper

            init(_ face: AccountFace) {
                switch face {
                case .automatic: self = .automatic
                case .monogram: self = .monogram
                case .paper: self = .paper
                }
            }
        }

        enum Setting: String, CaseIterable, Sendable {
            case listDensity, accountFaces, undoSend, remoteImages, notifications, notificationPreviews, keepMail, theme
            case appearance, font, textSize, adaptMailColours, sendAction, launchAtLogin, defaultMailApp
            case offerReaderMode, blockTrackers, aiProvider, accountFace, railNames
        }

        var setting: Setting {
            switch self {
            case .listDensity: return .listDensity
            case .accountFaces: return .accountFaces
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
            case .offerReaderMode: return .offerReaderMode
            case .blockTrackers: return .blockTrackers
            case .aiProvider: return .aiProvider
            case .accountFace: return .accountFace
            case .railNames: return .railNames
            }
        }

        /// Where the change came from, for the one setting with two ways in outside Settings: the rail's names.
        var trigger: Trigger? {
            if case .railNames(_, let trigger) = self { return trigger }
            return nil
        }

        /// The new value, as one of `values(of:)`.
        var value: String {
            switch self {
            case .listDensity(let density): return density.rawValue
            case .accountFaces(let on), .remoteImages(let on), .notifications(let on), .notificationPreviews(let on),
                 .adaptMailColours(let on), .launchAtLogin(let on), .offerReaderMode(let on), .blockTrackers(let on),
                 .railNames(let on, _):
                return Toggle(on).rawValue
            case .defaultMailApp: return Toggle.on.rawValue
            case .undoSend(let seconds): return Self.undoSendValue(seconds)
            case .keepMail(let retention): return retention.rawValue
            case .theme(let theme): return theme.rawValue
            case .appearance(let appearance): return appearance.rawValue
            case .font(let typeface): return typeface.rawValue
            case .textSize(let size): return size.rawValue
            case .sendAction(let action): return action.rawValue
            case .aiProvider(let writer): return writer?.rawValue ?? Toggle.off.rawValue
            case .accountFace(let face): return FaceKind(face).rawValue
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
            case .accountFaces, .remoteImages, .notifications, .notificationPreviews, .adaptMailColours, .launchAtLogin,
                 .offerReaderMode, .blockTrackers, .railNames:
                return Toggle.allCases.map(\.rawValue)
            case .aiProvider: return Writer.allCases.map(\.rawValue) + [Toggle.off.rawValue]
            case .accountFace: return FaceKind.allCases.map(\.rawValue)
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

        /// Conversations a mail action took. Only Always Archive Mail from This Sender sends "0": the rule is set even
        /// when no Inbox holds the sender's mail, while every other action that takes nothing sends nothing.
        static let conversations = CountBuckets(ranges: [(0, "0"), (1, "1"), (2, "2-5"), (6, "6-20"), (21, "21+")])
        /// Accounts of one kind.
        static let accounts = CountBuckets(ranges: [(0, "0"), (1, "1"), (2, "2"), (3, "3-5"), (6, "6+")])
        /// Search operators in a query (`from:`, `is:`, a leading minus…).
        static let operators = CountBuckets(ranges: [(0, "0"), (1, "1"), (2, "2"), (3, "3+")])
        /// Trackers held back in one conversation.
        static let trackers = CountBuckets(ranges: [(0, "1"), (2, "2-5"), (6, "6-20"), (21, "21+")])
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
            "eventKind": EventKind.allCases.map(\.rawValue),
            "eventAction": EventAction.allCases.map(\.rawValue),
            "surface": Surface.allCases.map(\.rawValue),
            "span": AnswerSpan.allCases.map(\.rawValue),
            "route": AnswerRoute.allCases.map(\.rawValue),
            "provider": Provider.allCases.map(\.rawValue),
            "aiProvider": Writer.allCases.map(\.rawValue),
            "ending": WriteEnding.allCases.map(\.rawValue),
            "draft": WriteDraft.allCases.map(\.rawValue),
            "instruction": Toggle.allCases.map(\.rawValue),
            "retry": Toggle.allCases.map(\.rawValue),
            "subject": Toggle.allCases.map(\.rawValue),
            "around": WriteAround.allCases.map(\.rawValue),
            "join": WriteJoinResult.allCases.map(\.rawValue),
            "readerLine": ReaderLine.allCases.map(\.rawValue),
            "trackers": CountBuckets.trackers.labels,
            "attachmentAction": AttachmentAction.allCases.map(\.rawValue),
            "permission": Permission.allCases.map(\.rawValue),
            "result": PermissionResult.allCases.map(\.rawValue),
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
        case .detailsOpened: return .detailsOpened
        case .eventAction: return .eventAction
        case .undo: return .undo
        case .accountAdded: return .accountAdded
        case .accountRemoved: return .accountRemoved
        case .helpMeWriteUsed: return .helpMeWriteUsed
        case .readerModeSwitched: return .readerModeSwitched
        case .readerVersionSwitched: return .readerVersionSwitched
        case .quotedText: return .quotedText
        case .trackersBlocked: return .trackersBlocked
        case .linkCleaned: return .linkCleaned
        case .attachmentUsed: return .attachmentUsed
        case .permissionAsked: return .permissionAsked
        case .senderRuleRemoved: return .senderRuleRemoved
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
            var parameters = ["setting": change.setting.rawValue, "value": change.value]
            if let trigger = change.trigger { parameters["trigger"] = trigger.rawValue }
            return parameters
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
        case .invitationAnswered(let answer, let surface, let span, let route):
            return ["answer": answer.rawValue, "surface": surface.rawValue, "span": span.rawValue, "route": route.rawValue]
        case .detailsOpened(let kind, let trigger):
            return ["eventKind": kind.rawValue, "trigger": trigger.rawValue]
        case .eventAction(let action, let surface, let trigger):
            return ["eventAction": action.rawValue, "surface": surface.rawValue, "trigger": trigger.rawValue]
        case .accountAdded(let provider), .accountRemoved(let provider), .senderRuleRemoved(let provider):
            return ["provider": provider.rawValue]
        case .helpMeWriteUsed(let writer, let ending, let details):
            var parameters = ["aiProvider": writer.rawValue, "ending": ending.rawValue]
            if let details {
                parameters["draft"] = details.draft.rawValue
                parameters["instruction"] = Toggle(details.instruction).rawValue
                parameters["retry"] = Toggle(details.retry).rawValue
                parameters["source"] = details.source.rawValue
                parameters["kind"] = details.kind.rawValue
                parameters["subject"] = Toggle(details.subject).rawValue
                if let around = details.around { parameters["around"] = around.rawValue }
                if let join = details.join { parameters["join"] = join.rawValue }
            }
            return parameters
        case .readerModeSwitched(let on, let trigger):
            return ["value": Toggle(on).rawValue, "trigger": trigger.rawValue]
        case .readerVersionSwitched(let line):
            return ["readerLine": line.rawValue]
        case .quotedText(let shown, let trigger):
            return ["state": (shown ? DayColumnState.shown : .hidden).rawValue, "trigger": trigger.rawValue]
        case .trackersBlocked(let count):
            return ["trackers": CountBuckets.trackers.label(count)]
        case .linkCleaned:
            return [:]
        case .attachmentUsed(let action, let trigger):
            return ["attachmentAction": action.rawValue, "trigger": trigger.rawValue]
        case .permissionAsked(let permission, let granted, let provider):
            return ["permission": permission.rawValue, "result": (granted ? PermissionResult.granted : .notGranted).rawValue,
                    "provider": provider.rawValue]
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
