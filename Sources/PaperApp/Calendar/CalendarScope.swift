import PaperCore

/// Whose events the calendar draws: every account's, or only the one the window is narrowed to (⌘1…⌘9), as the list
/// is (spec §5.54, “unified”).
enum CalendarScope: Hashable, Sendable {
    case all
    case account(AccountID)

    /// Whether an item of `accountID` belongs in this scope.
    func includes(_ accountID: AccountID) -> Bool {
        switch self {
        case .all: return true
        case .account(let id): return id == accountID
        }
    }
}
