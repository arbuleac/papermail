import AppKit
import PaperCore
import PaperDesign

/// The app's alerts (spec §5.33): system `NSAlert`s with the app icon, a sentence-case title, a body that says
/// what happens or went wrong and the remedy, and title-case verbs. The safe choice is the default (↩) and
/// the destructive button is never the default; Esc picks the safe choice. Every alert the app shows is one
/// of the static builders below, so no screen invents its own copy.
@MainActor
struct AppAlert {
    enum Role {
        case normal
        /// `hasDestructiveAction`: system red text. Never the default, never more than one per alert.
        case destructive
        /// What Esc picks when no button is titled “Cancel” (NSAlert gives Esc to that title by itself).
        case cancel
    }

    struct Button {
        var title: String
        var role: Role = .normal
    }

    var title: String
    var body: String
    /// Default first.
    var buttons: [Button]

    /// The response index of the button the user chose, in `buttons` order.
    typealias Completion = @MainActor (Int) -> Void

    func makeAlert() -> NSAlert {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = body
        alert.alertStyle = .informational
        for button in buttons {
            let made = alert.addButton(withTitle: button.title)
            made.hasDestructiveAction = button.role == .destructive
            // The alert's buttons are AppKit's, so the hand comes from an overlay (§4.17).
            QuirePointerOverlay.install(on: made)
        }
        // NSAlert gives a first button titled Cancel only Esc, so “Remove …?” would have no default at all.
        // The safe choice is the default (↩, which also moves it to the default position); `installEscape`
        // keeps Esc on it.
        if let first = alert.buttons.first, first.keyEquivalent != "\r" { first.keyEquivalent = "\r" }
        return alert
    }

    /// The button Esc presses: the one titled Cancel, else the one marked `.cancel`, else the only button.
    var escapeIndex: Int? {
        if let cancel = buttons.firstIndex(where: { $0.title == "Cancel" }) { return cancel }
        if let marked = buttons.firstIndex(where: { $0.role == .cancel }) { return marked }
        return buttons.count == 1 ? 0 : nil
    }

    /// Shows the alert as a sheet on `window` (the window where the action started), or app-modal when there
    /// is no visible window.
    func present(on window: NSWindow?, completion: Completion? = nil) {
        let alert = makeAlert()
        let monitor = installEscape(for: alert)
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            if let monitor { NSEvent.removeMonitor(monitor) }
            let index = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
            completion?(index)
        }
        if let window, window.isVisible {
            alert.beginSheetModal(for: window) { response in
                MainActor.assumeIsolated { finish(response) }
            }
        } else {
            finish(alert.runModal())
        }
    }

    /// NSAlert maps Esc only to a button titled “Cancel” that is not the default. “Keep Writing”, the lone
    /// “Quit” and a default Cancel need it too.
    private func installEscape(for alert: NSAlert) -> Any? {
        guard let index = escapeIndex, alert.buttons.indices.contains(index), alert.buttons[index].keyEquivalent != "\u{1b}" else {
            return nil
        }
        let button = alert.buttons[index]
        return NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak alert] event in
            guard event.keyCode == 53, let alert, event.window === alert.window else { return event }
            MainActor.assumeIsolated { button.performClick(nil) }
            return nil
        }
    }

    // MARK: The inventory (spec §5.33)

    /// Launch, before any window exists: app-modal, and the app quits when it closes.
    static func databaseUnavailable(reason: String) -> AppAlert {
        AppAlert(title: "Paper couldn't open its mail database",
                 body: sentence(reason) + " It is stored in ~/Library/Application Support/\(AppIdentity.applicationSupportFolderName).",
                 buttons: [Button(title: "Quit")])
    }

    /// Launch, before anything is opened, when the old app is open on a mailbox Paper has not moved yet
    /// (docs/ARCHITECTURE.md, "Identity"): app-modal, and the app quits when it closes.
    static var legacyAppOpen: AppAlert {
        let old = LegacyIdentity.name
        return AppAlert(title: "\(old) is still open",
                        body: "Paper brings over your mail, accounts and settings from \(old) the first time it opens, and can't while \(old) is open. Quit \(old), then open Paper again.",
                        buttons: [Button(title: "Quit")])
    }

    /// Launch, before anything is opened, when the first launch's move could not bring the old app's mailbox over
    /// (docs/ARCHITECTURE.md, "Identity"): a move failed. App-modal, and the app quits when it closes; the next launch
    /// tries again.
    static var mailboxNotMoved: AppAlert {
        let old = LegacyIdentity.name
        return AppAlert(title: "Paper couldn't bring over your mail",
                        body: "Your mailbox, accounts and drafts from \(old) are still in ~/Library/Application Support/\(LegacyIdentity.applicationSupportFolderName), and nothing was lost. Paper quits rather than start an empty mailbox beside them. Open Paper again to try once more.",
                        buttons: [Button(title: "Quit")])
    }

    /// Launch, before anything is opened, when Paper's folder already holds a mailbox the move did not put there and the
    /// old app's never moved (docs/ARCHITECTURE.md, "Identity"): the move puts one beside the other no more than it
    /// chooses between them. Show in Finder selects Paper's; either button quits.
    static var mailboxInBothFolders: AppAlert {
        let old = LegacyIdentity.name
        let folder = AppIdentity.applicationSupportFolderName
        return AppAlert(title: "Paper already has a mailbox",
                        body: "Your mail from \(old) is in ~/Library/Application Support/\(LegacyIdentity.applicationSupportFolderName), but a mailbox made before Paper first opened, by a development build perhaps, is already in ~/Library/Application Support/\(folder). Paper quits rather than choose between them. To bring your mail over, move mail.sqlite and the files that begin with its name out of \(folder), then open Paper again.",
                        buttons: [Button(title: "Show in Finder"), Button(title: "Quit", role: .cancel)])
    }

    /// What a launch shows instead of opening anything after the first launch's move (`IdentityMigration.run`), or nil
    /// when it opens as usual: the old app open on a mailbox not moved yet, or a mailbox the move could not bring over.
    static func identityHold(for outcome: IdentityMigration.Outcome) -> AppAlert? {
        switch outcome {
        case .deferred(applicationSupportWaiting: true): legacyAppOpen
        case .leftBehind(.moveFailed): mailboxNotMoved
        case .leftBehind(.mailboxInBothFolders): mailboxInBothFolders
        case .notThisApp, .ran, .deferred(applicationSupportWaiting: false): nil
        }
    }

    static func remove(_ account: Account) -> AppAlert {
        AppAlert(title: "Remove \(account.email)?",
                 body: "Mail from this account is removed from this Mac. Nothing changes on the server.",
                 buttons: [Button(title: "Cancel"), Button(title: "Remove", role: .destructive)])
    }

    static func removeFailed(_ account: Account, reason: String) -> AppAlert {
        AppAlert(title: "Couldn't remove \(account.email)",
                 body: sentence(reason) + " The account is still here; nothing was deleted.",
                 buttons: [Button(title: "Try Again"), Button(title: "Cancel")])
    }

    static func missingClient(_ kind: ProviderKind) -> AppAlert {
        let company = kind == .gmail ? "Google" : "Microsoft"
        let service = kind == .gmail ? "a Gmail account" : "a Microsoft account"
        return AppAlert(title: "Set up a \(company) OAuth client first",
                        body: "Paper needs your own \(company) OAuth client ID to add \(service).",
                        buttons: [Button(title: "Open Settings"), Button(title: "Cancel")])
    }

    /// Before a Microsoft sign-in: the address may be both kinds of account, and only the user knows which holds the mail.
    static let microsoftAccountType = AppAlert(title: "Which kind of Microsoft account?",
                                               body: "An address can be both a work or school account and a personal Microsoft account. Choose the one that holds your mail.",
                                               buttons: [Button(title: "Work or School"), Button(title: "Personal"), Button(title: "Cancel")])

    static func addFailed(reason: String) -> AppAlert {
        AppAlert(title: "Couldn't add the account", body: sentence(reason), buttons: [Button(title: "Try Again"), Button(title: "Cancel")])
    }

    static func alreadyAdded(_ account: Account) -> AppAlert {
        AppAlert(title: "\(account.email) is already added", body: "Choose it in the rail or in Settings.",
                 buttons: [Button(title: "Show Account"), Button(title: "Cancel")])
    }

    static func reconnectFailed(_ account: Account, reason: String) -> AppAlert {
        AppAlert(title: "Couldn't reconnect \(account.email)", body: sentence(reason),
                 buttons: [Button(title: "Try Again"), Button(title: "Cancel")])
    }

    static func wrongAccount(expected: String, actual: String) -> AppAlert {
        AppAlert(title: "Signed in to a different account",
                 body: "You signed in as \(actual), but this account is \(expected). Nothing was changed. "
                     + "Try again and choose \(expected) in your browser.",
                 buttons: [Button(title: "Try Again"), Button(title: "Cancel")])
    }

    /// Nothing real is lost, so there is no destructive button.
    static let leaveDemo = AppAlert(title: "Leave the demo?",
                                    body: "The made-up mailboxes are removed from this Mac. You'll return to the welcome screen.",
                                    buttons: [Button(title: "Leave Demo"), Button(title: "Cancel")])

    static let replaceDemo = AppAlert(title: "Replace the demo with this account?",
                                      body: "The made-up mailboxes are removed from this Mac when your account is added.",
                                      buttons: [Button(title: "Continue"), Button(title: "Cancel")])

    /// A sender rule on an account that has not let Paper save rules on the server (§5.52): the rule becomes a Gmail
    /// filter or an Outlook rule, which needs one more permission. Continue is the default, since the user just chose the
    /// rule: it opens the browser to allow it, and the rule is set once it is allowed. Cancel sets nothing.
    static func saveSenderRules(_ kind: ProviderKind, action: SenderRule.Action) -> AppAlert {
        let service = SenderRuleCopy.service(kind)
        let rule = kind == .gmail ? "a Gmail filter" : "an Outlook rule"
        let effect = action == .archive ? "is archived" : "goes to the Trash"
        return AppAlert(title: "Save sender rules in \(service)?",
                        body: "Paper saves this as \(rule), so mail from this sender \(effect) on every device, even when "
                            + "this Mac is off. \(service) asks you to allow it once.",
                        buttons: [Button(title: "Continue"), Button(title: "Cancel")])
    }

    /// After Continue's sign-in came back without the permission (a consent screen that let the user leave it unticked):
    /// nothing was set, and Try Again asks again.
    static func senderRulesNotAllowed(_ kind: ProviderKind) -> AppAlert {
        let service = SenderRuleCopy.service(kind)
        let rules = kind == .gmail ? "Gmail filters" : "Outlook rules"
        return AppAlert(title: "\(service) didn't allow sender rules",
                        body: "The rule wasn't saved. Try again and allow Paper to read and save \(rules) in your browser.",
                        buttons: [Button(title: "Try Again"), Button(title: "Cancel")])
    }

    /// Composer: Message › Discard Draft… (§5.20). `recipient` is the first To name, if any.
    static func discardDraft(recipient: String?) -> AppAlert {
        let subject = recipient.map { "The message to \($0) hasn't been sent." } ?? "This message hasn't been sent."
        return AppAlert(title: "Discard this draft?", body: subject + " Discarding removes it from this Mac.",
                        buttons: [Button(title: "Keep Writing", role: .cancel), Button(title: "Discard", role: .destructive)])
    }

    /// Composer: Send with an empty subject (§5.20). Add Subject takes ↩ and Esc; Send Anyway is the choice
    /// that cannot be taken back once the undo window ends.
    static let sendWithoutSubject = AppAlert(title: "Send without a subject?", body: "Messages without a subject are easy to miss.",
                                             buttons: [Button(title: "Add Subject", role: .cancel), Button(title: "Send Anyway")])

    /// Main window, at launch (§5.23): Send Later times that passed while the app was closed. Keep in Drafts takes ↩ and
    /// Esc, since a message sent late cannot be taken back; Send Now sends them at once. `time` is the one message's time,
    /// written as its row wrote it.
    static func missedSends(count: Int, subject: String, recipient: String?, time: String?) -> AppAlert {
        let buttons = [Button(title: "Keep in Drafts", role: .cancel), Button(title: "Send Now")]
        guard count > 1 else {
            let trimmed = subject.trimmingCharacters(in: .whitespaces)
            var message = trimmed.isEmpty ? "The message" : "\u{201c}\(trimmed)\u{201d}"
            if let recipient { message += " to \(recipient)" }
            let when = time.map { " at \($0)" } ?? ""
            return AppAlert(title: "A scheduled message wasn't sent",
                            body: "\(message) was due to send\(when), while Paper was closed. Send it now, or keep it in Drafts.",
                            buttons: buttons)
        }
        return AppAlert(title: "\(count) scheduled messages weren't sent",
                        body: "They were due to send while Paper was closed. Send them now, or keep them in Drafts.",
                        buttons: buttons)
    }

    /// Drafts reader and # in Drafts (§5.19): one draft or several. Cancel is the default here, unlike the
    /// composer's form, because nothing is being written.
    static func discardDrafts(count: Int, recipient: String?) -> AppAlert {
        guard count > 1 else {
            let subject = recipient.map { "The message to \($0) hasn't been sent." } ?? "This message hasn't been sent."
            return AppAlert(title: "Discard this draft?", body: subject + " Discarding removes it from this Mac.",
                            buttons: [Button(title: "Cancel"), Button(title: "Discard", role: .destructive)])
        }
        return AppAlert(title: "Discard \(count) drafts?", body: "They haven't been sent. Discarding removes them from this Mac.",
                        buttons: [Button(title: "Cancel"), Button(title: "Discard", role: .destructive)])
    }

    /// Reader: Open on an attachment that is a program or script (§5.17). Cancel is the default: nothing is
    /// lost by not opening it.
    static func openProgram(filename: String) -> AppAlert {
        AppAlert(title: "Open \u{201c}\(filename)\u{201d}?",
                 body: "It is a program or script, and opening it lets it change your Mac. Open it only if you trust the sender "
                     + "and expected it.",
                 buttons: [Button(title: "Cancel"), Button(title: "Open")])
    }

    /// Settings › AI, as a provider is chosen (§5.40, §5.56): the privacy notice, at that moment and only then, never while
    /// writing. What goes, when, and to whom, in few words. Cancel is the default and Esc, and puts the popup back; Turn On
    /// keeps the choice and gives that provider permission (Off withdraws it). The CLIs add whose rules then apply. The
    /// demo's writer makes replies up on the Mac and sends nothing, so its sheet says only that.
    static func helpMeWriteTurnOn(_ kind: AIProviderKind, demo: Bool = false) -> AppAlert {
        if demo {
            return AppAlert(title: "Try Help Me Write?",
                            body: "In the demo, replies are made up on this Mac. Nothing is sent.",
                            buttons: [Button(title: "Cancel"), Button(title: "Turn On")])
        }
        let company = kind.destination.displayName
        // The user's own notes go as typed (an address there is one they want in the reply); the conversation's go redacted.
        var body = "When you press Write, the conversation you\u{2019}re replying to (newest messages first, older ones "
            + "shortened), your notes and your first name go to \(company) to draft a reply. Email addresses from the conversation, "
            + "attachments and other mail are never sent. Nothing is sent until you press Write."
        switch kind {
        case .claudeCode: body += " Through Claude Code, under your Claude plan\u{2019}s privacy settings."
        case .codex: body += " Through Codex, under your OpenAI account\u{2019}s privacy settings."
        default: break
        }
        return AppAlert(title: "Use \(kind.displayName) to help write replies?", body: body,
                        buttons: [Button(title: "Cancel"), Button(title: "Turn On")])
    }

    /// Every alert of the inventory this surface owns, with sample values, for the alert snapshot.
    static var specimens: [AppAlert] {
        let contoso = Account(id: AccountID("contoso"), kind: .microsoft, email: "alex@contoso.test", displayName: "Alex Morgan",
                              addedAt: Date())
        let fabrikam = Account(id: AccountID("fabrikam"), kind: .microsoft, email: "alex@fabrikam.test", displayName: "Alex Morgan",
                               addedAt: Date())
        return [
            sendWithoutSubject,
            missedSends(count: 1, subject: "Re: Contoso rollout", recipient: "Ben Carter", time: "Mon 09:00"),
            discardDraft(recipient: "Ben Carter"),
            discardDrafts(count: 3, recipient: nil),
            remove(contoso),
            removeFailed(contoso, reason: "The mail database is busy."),
            missingClient(.gmail),
            addFailed(reason: "Google refused the sign-in. Check the client ID in Settings › OAuth."),
            alreadyAdded(contoso),
            reconnectFailed(fabrikam, reason: "Couldn't reach Microsoft. Check your internet connection."),
            wrongAccount(expected: "alex@fabrikam.test", actual: "sam@contoso.test"),
            databaseUnavailable(reason: "The disk is full."),
            legacyAppOpen,
            mailboxNotMoved,
            mailboxInBothFolders,
            leaveDemo,
            replaceDemo,
            saveSenderRules(.gmail, action: .archive),
            saveSenderRules(.microsoft, action: .trash),
            senderRulesNotAllowed(.gmail),
            openProgram(filename: "Invoice.command"),
            helpMeWriteTurnOn(.claudeAPI),
            helpMeWriteTurnOn(.claudeCode),
            helpMeWriteTurnOn(.codex),
            helpMeWriteTurnOn(.claudeAPI, demo: true),
        ]
    }

    /// Ends a reason with a full stop so the remedy that follows reads as its own sentence.
    static func sentence(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last else { return "" }
        return ".!?…".contains(last) ? trimmed : trimmed + "."
    }
}
