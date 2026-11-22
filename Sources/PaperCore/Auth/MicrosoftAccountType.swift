import Foundation

/// Which Microsoft identity a new account signs in as. One address can be both a work or school account and a
/// personal Microsoft account; through `common` Microsoft may pick the personal one without asking, and its mailbox
/// can be empty. So the user chooses, and the account signs in and renews its token through that audience only.
public enum MicrosoftAccountType: String, Sendable, CaseIterable {
    case workOrSchool
    case personal

    /// The tenant to sign in through: personal accounts through `consumers`; work or school accounts through the
    /// tenant Settings › OAuth names when it names one organisation, else `organizations`.
    public func tenant(configured: String?) -> String {
        switch self {
        case .personal:
            return "consumers"
        case .workOrSchool:
            let named = configured?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return named.isEmpty || Self.audiences.contains(named.lowercased()) ? "organizations" : named
        }
    }

    /// The type a stored tenant signs in as; nil for `common` or none, which may be either.
    public init?(tenant: String?) {
        let named = tenant?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        guard !named.isEmpty, named != "common" else { return nil }
        self = named == "consumers" || named == Self.consumersTenantID ? .personal : .workOrSchool
    }

    private static let audiences: Set<String> = ["common", "organizations", "consumers"]
    /// The tenant every personal Microsoft account belongs to.
    private static let consumersTenantID = "9188040d-6c67-4c5b-b112-36a304b66dad"
}
