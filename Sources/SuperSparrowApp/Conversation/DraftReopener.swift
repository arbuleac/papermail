import AppKit
import SSCore

/// Continue Editing on a provider's draft (a Drafts row synced from Gmail or Outlook, spec §5.19): the composer
/// that already continues it comes forward, else the kept draft that continues it reopens as it was left,
/// else a composer opens holding the draft's recipients, subject and text, read from the store. The composer
/// remembers the provider's draft, so sending discards it instead of leaving the original behind.
///
/// A kept draft a Send Later message was written in opens as that message's Drafts row does: its schedule is cancelled
/// first, since what is being changed must not also go at the old time; once the message is on its way it cannot be
/// opened, and nothing else is either, since a fresh copy of the provider's draft would go beside it.
@MainActor
enum DraftReopener {
    /// False when nothing opened: the caller beeps.
    @discardableResult
    static func present(_ id: MessageID, client: MailClient, accounts: [Account]) -> Bool {
        if let open = ComposeWindowRegistry.shared.controller(holdingDraft: id) {
            open.window?.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return true
        }
        if let kept = ComposeDraftStore.shared.keptDraft(continuing: id, accounts: accounts) {
            if let scheduled = SendLaterOutbox.send(writtenIn: kept.id, in: client.store) {
                guard SendLaterState(scheduled)?.isHeld == true, (try? client.cancelSend(id: scheduled.id)) == true else { return false }
            }
            ComposeWindowController.present(client: client, accounts: accounts, draft: kept)
            return true
        }
        guard let message = try? client.store.message(id),
              let account = accounts.first(where: { $0.id == id.accountID }) ?? accounts.first else { return false }
        let body = try? client.store.body(for: id)
        var text = message.snippet
        if let plain = body?.body.text, !plain.isEmpty {
            text = plain
        } else if let extracted = body?.plainText, !extracted.isEmpty {
            text = extracted
        }
        // A fresh identity in ComposeDraftStore: the store keeps drafts written on this Mac, and this one is the
        // provider's copy until the composer keeps it.
        let draft = ComposeDraft(
            id: UUID(), mode: .new, account: account, to: message.to, cc: message.cc, bcc: message.bcc, subject: message.subject,
            body: NSAttributedString(string: text), attachments: [], quoted: nil, threading: nil, continuesDraft: id
        )
        ComposeWindowController.present(client: client, accounts: accounts, draft: draft)
        return true
    }
}
