import Foundation

/// What became of a pending sender rule on the server, as the rules lane hands it to the store
/// (`MailStoring.settleSenderRule`). Each case states a fact about the server, not about the row: the store applies it to
/// the row as it stands then, which the user may have changed while the request was on its way.
public enum SenderRuleOutcome: Hashable, Sendable {
    /// The server now holds `action` for the address under `serverIDs` (a rule created, or an identical one adopted), and
    /// no longer holds `deleted` (the old rules of a replacement, deleted or found gone).
    case written(action: SenderRule.Action, serverIDs: [String], deleted: [String])
    /// The server no longer holds `serverIDs`: a delete went through, or found them gone.
    case deleted(serverIDs: [String])
    /// The server refused the `attempted` write for good (its limit on rules, or a refusal of its own): a create is given
    /// up and the row goes; a delete or a replacement is given up and the row is back as the server has it, `serverHas`
    /// (the action the server holds for the address then, folded as a read folds it), or goes when the server holds
    /// nothing it can show. Ignored when the row has moved on to another state meanwhile, which the lane sends in its turn.
    case refused(attempted: SenderRule.Sync, serverHas: SenderRule.Action?)
}
