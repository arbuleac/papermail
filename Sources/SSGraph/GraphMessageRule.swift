import Foundation

/// One inbox rule as `/me/mailFolders/inbox/messageRules` lists it. The conditions, exceptions and actions are read as
/// untyped JSON so a predicate or an action this build does not know (Exchange has dozens, and adds more) makes the rule
/// one the app does not show, rather than one it shows wrongly.
struct GraphMessageRule: Decodable, Sendable {
    var id: String?
    var displayName: String?
    var sequence: Int?
    var isEnabled: Bool?
    var conditions: GraphJSONValue?
    var exceptions: GraphJSONValue?
    var actions: GraphJSONValue?

    /// Whether the rule moves mail to a folder: only then does reading it need the Archive folder's id.
    var movesToFolder: Bool {
        guard let folder = actions?.objectValue?["moveToFolder"]?.stringValue else { return false }
        return !folder.isEmpty
    }
}

/// The body of a create, in exactly the shape `GraphProvider.senderRule(from:archiveFolderID:)` recognizes.
struct GraphMessageRulePayload: Encodable, Sendable {
    struct Recipient: Encodable, Sendable {
        struct Address: Encodable, Sendable {
            var address: String
        }

        var emailAddress: Address
    }

    struct Conditions: Encodable, Sendable {
        var fromAddresses: [Recipient]
    }

    struct Actions: Encodable, Sendable {
        var moveToFolder: String?
        var delete: Bool?
        var stopProcessingRules: Bool
    }

    var displayName: String
    var sequence: Int
    var isEnabled = true
    var conditions: Conditions
    var actions: Actions
}
