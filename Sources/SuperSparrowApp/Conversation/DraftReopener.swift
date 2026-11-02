import AppKit
import SSCore

/// Continue Editing on a provider's draft (a Drafts row synced from Gmail or Outlook, spec §5.19): the composer
/// that already continues it comes forward, else the kept draft that continues it reopens as it was left,
/// else a composer opens holding the draft's recipients, subject and text, read from the store. The composer
/// remembers the provider's draft, so sending discards it instead of leaving the original behind.
@MainActor
enum DraftReopener {
    @discardableResult
    static func present(_ id: MessageID, client: MailClient, accounts: [Account]) -> Bool {
        if let open = ComposeWindowRegistry.shared.controller(holdingDraft: id) {
            open.window?.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return true
        }
        if let kept = ComposeDraftStore.shared.keptDraft(continuing: id, accounts: accounts) {
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
