import SSCore
import SSDesign
import SwiftUI

/// Settings › Accounts › Senders… (spec §5.40, "Sender rules (Q4.2)"): the account's sender rules, the one place they are
/// listed, each with its − to remove it. Rules are set from a message's menu, never here, so the sheet has no +.
/// Removing one takes effect at once and moves no mail back.
struct SendersSheet: View {
    @ObservedObject var model: SettingsModel
    let account: Account
    let onDone: () -> Void

    /// One row per rule of the account, by address: the address, then what the rule does (“Blocked”).
    var rows: [QuireRemovableList.Row] {
        model.senderRules(for: account).map {
            QuireRemovableList.Row(id: $0.address, title: $0.address, detail: MailActionCopy.senderRuleDescription($0.action))
        }
    }

    /// A row's −: its rule goes through the model, which the app delegate points at the engine.
    func remove(_ row: QuireRemovableList.Row) {
        guard let rule = model.senderRules(for: account).first(where: { $0.address == row.id }) else { return }
        model.removeSenderRule(rule)
    }

    var body: some View {
        QuireRuleSheet(
            title: "Senders",
            caption: "Mail from these senders to \(account.email) is archived or moved to the Trash as it arrives.",
            rows: rows,
            emptyTitle: "No sender rules",
            emptyHint: "Set one from a message's menu.",
            onRemove: remove,
            onDone: onDone
        )
    }
}
