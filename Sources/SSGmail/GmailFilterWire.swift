import Foundation

/// `users.settings.filters.list`: every filter of the mailbox in one reply (the method has no pages), under `filter`,
/// which Google leaves out altogether when there are none.
struct GmailFilterList: Decodable, Sendable {
    var filter: [GmailFilterResource]?
}

/// One Gmail filter as the API returns it. The criteria and the action are read as untyped JSON so a field this build
/// does not know (Google adds them) makes the filter one the app does not show, rather than one it shows wrongly.
struct GmailFilterResource: Decodable, Sendable {
    var id: String?
    var criteria: [String: GmailJSONValue]?
    var action: [String: GmailJSONValue]?
}

/// The body of `users.settings.filters.create` for a sender rule: exactly the two shapes the app recognizes.
struct GmailFilterInsert: Encodable, Sendable {
    struct Criteria: Encodable, Sendable {
        var from: String
    }

    struct Action: Encodable, Sendable {
        var addLabelIds: [String]?
        var removeLabelIds: [String]?
    }

    var criteria: Criteria
    var action: Action
}

/// The reply to a create: the filter with its id.
struct GmailFilterCreated: Decodable, Sendable {
    var id: String?
}

/// Untyped JSON, for the parts of a filter whose every field matters to recognition.
enum GmailJSONValue: Decodable, Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case array([GmailJSONValue])
    case object([String: GmailJSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([GmailJSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: GmailJSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    /// Whether the field says anything: Google may spell a field it does not apply as null, false, empty or
    /// `unspecified` (a size comparison with no size).
    var isSet: Bool {
        switch self {
        case .null: return false
        case .bool(let value): return value
        case .number: return true
        case .string(let value): return !value.isEmpty && value.lowercased() != "unspecified"
        case .array(let values): return !values.isEmpty
        case .object(let fields): return fields.values.contains(where: \.isSet)
        }
    }

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    /// The strings of an array of strings; nil for anything else.
    var strings: [String]? {
        guard case .array(let values) = self else { return nil }
        let strings = values.compactMap(\.stringValue)
        return strings.count == values.count ? strings : nil
    }
}
