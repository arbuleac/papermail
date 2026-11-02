import SwiftUI

/// The text a Quire field sets (spec §5.25).
public enum QuireFieldVariant: String, CaseIterable, Sendable {
    /// `body`.
    case standard
    /// `mono`: OAuth client IDs, secrets and tenants.
    case mono

    public var role: QuireFont.Role {
        switch self {
        case .standard: return .body
        case .mono: return .mono
        }
    }
}
