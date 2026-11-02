import AppKit
import SSCore

/// Continue Editing on a read-only draft (spec §5.19): a composer opens holding the draft's recipients,
/// subject and text, read from the store, so writing picks up where it stopped.
@MainActor
enum DraftReopener {
    @discardableResult
    static func present(_ id: MessageID, client: MailClient, accounts: [Account]) -> Bool {
        guard let message = try? client.store.message(id),
              let account = accounts.first(where: { $0.id == id.accountID }) ?? accounts.first else { return false }
        let body = try? client.store.body(for: id)
        var text = message.snippet
        if let plain = body?.body.text, !plain.isEmpty {
            text = plain
        } else if let extracted = body?.plainText, !extracted.isEmpty {
            text = extracted
        }
        let draft = ComposeDraft(
            mode: .new, account: account, to: message.to, cc: message.cc, bcc: message.bcc, subject: message.subject,
            body: NSAttributedString(string: text), attachments: [], quoted: nil, threading: nil
        )
        ComposeWindowController.present(client: client, accounts: accounts, draft: draft)
        return true
    }
}
