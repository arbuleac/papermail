import Foundation

/// One of the two fictional mailboxes demo mode signs in to. There is exactly one per provider kind, which is
/// how the authenticator, the provider and the seeder agree on who is signing in without sharing state.
public struct DemoProfile: Hashable, Sendable {
    public let kind: ProviderKind
    public let email: String
    public let displayName: String
    /// Messages in the generated mailbox before any live arrivals.
    public let messageCount: Int
    let seed: UInt64

    public static let gmail = DemoProfile(
        kind: .gmail, email: "alex@demo-gmail.test", displayName: "Alex Morgan", messageCount: 220, seed: 0x5EED_6A11
    )
    public static let outlook = DemoProfile(
        kind: .microsoft, email: "alex@demo-outlook.test", displayName: "Alex Morgan", messageCount: 180, seed: 0x5EED_0071
    )

    public static let all: [DemoProfile] = [.gmail, .outlook]

    public static func profile(for kind: ProviderKind) -> DemoProfile {
        switch kind {
        case .gmail: return .gmail
        case .microsoft: return .outlook
        }
    }

    public var me: EmailAddress { EmailAddress(name: displayName, address: email) }
}
