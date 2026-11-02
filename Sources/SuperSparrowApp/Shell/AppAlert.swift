import AppKit
import SSCore

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
        }
        return alert
    }

    /// The button Esc presses: the one titled Cancel (NSAlert's own rule), else the one marked `.cancel`, else
    /// the only button.
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

    /// NSAlert maps Esc only to a button titled “Cancel”. “Keep Writing” and the lone “Quit” need it too.
    private func installEscape(for alert: NSAlert) -> Any? {
        guard let index = escapeIndex, buttons[index].title != "Cancel" else { return nil }
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
        AppAlert(title: "SuperSparrow couldn't open its mail database",
                 body: sentence(reason) + " It is stored in ~/Library/Application Support/SuperSparrow.",
                 buttons: [Button(title: "Quit")])
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
                        body: "SuperSparrow needs your own \(company) OAuth client ID to add \(service).",
                        buttons: [Button(title: "Open Settings"), Button(title: "Cancel")])
    }

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

    /// Composer: Message › Discard Draft… (§5.20). `recipient` is the first To name, if any.
    static func discardDraft(recipient: String?) -> AppAlert {
        let subject = recipient.map { "The message to \($0) hasn't been sent." } ?? "This message hasn't been sent."
        return AppAlert(title: "Discard this draft?", body: subject + " Discarding removes it from this Mac.",
                        buttons: [Button(title: "Keep Writing", role: .cancel), Button(title: "Discard", role: .destructive)])
    }

    /// Every alert of the inventory this surface owns, with sample values, for the alert snapshot.
    static var specimens: [AppAlert] {
        let contoso = Account(id: AccountID("contoso"), kind: .microsoft, email: "alex@contoso.test", displayName: "Alex Morgan",
                              colorHex: "#000000", addedAt: Date())
        let fabrikam = Account(id: AccountID("fabrikam"), kind: .microsoft, email: "alex@fabrikam.test", displayName: "Alex Morgan",
                               colorHex: "#000000", addedAt: Date())
        return [
            discardDraft(recipient: "Ben Carter"),
            remove(contoso),
            removeFailed(contoso, reason: "The mail database is busy."),
            missingClient(.gmail),
            addFailed(reason: "Google refused the sign-in. Check the client ID in Settings › OAuth."),
            alreadyAdded(contoso),
            reconnectFailed(fabrikam, reason: "Couldn't reach Microsoft. Check your internet connection."),
            wrongAccount(expected: "alex@fabrikam.test", actual: "sam@contoso.test"),
            databaseUnavailable(reason: "The disk is full."),
            leaveDemo,
            replaceDemo,
        ]
    }

    /// Ends a reason with a full stop so the remedy that follows reads as its own sentence.
    static func sentence(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last else { return "" }
        return ".!?…".contains(last) ? trimmed : trimmed + "."
    }
}
