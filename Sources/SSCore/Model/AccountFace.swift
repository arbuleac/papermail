import Foundation

/// The face an account wears in the rail, the Settings row, the list's account tile, the quick reply and the title menu
/// (Quire §5.55). The store keeps the choice and the design layer draws it, so SSCore never knows which faces exist.
public enum AccountFace: Hashable, Sendable {
    /// Nothing chosen: the paper face the design layer picks from the account's ink slot. Every account from before faces
    /// reads as this, so it shows a face on its first launch after the update.
    case automatic
    /// The letter monogram, drawn as it was before faces (§4.2): the typed one, or the one derived from the domain.
    case monogram
    /// One paper face, by its id in the art (`fox`, `curly-hair`). An id the design layer no longer has draws as
    /// `automatic`, so art can be retired without a migration.
    case paper(String)

    /// How `accounts.face` keeps the choice: NULL for automatic, `monogram`, or `paper:` and the face's id.
    public var storedValue: String? {
        switch self {
        case .automatic: return nil
        case .monogram: return "monogram"
        case .paper(let id): return id.isEmpty ? nil : "paper:" + id
        }
    }

    /// The choice a stored value names. Anything unreadable (a later version's kind of face, an empty id) is automatic:
    /// the account then shows a face rather than nothing.
    public init(storedValue: String?) {
        guard let value = storedValue else {
            self = .automatic
            return
        }
        if value == "monogram" {
            self = .monogram
        } else if value.hasPrefix("paper:"), value.count > "paper:".count {
            self = .paper(String(value.dropFirst("paper:".count)))
        } else {
            self = .automatic
        }
    }

    /// The one representation the store keeps: `.paper("")` is automatic.
    public static func normalized(_ face: AccountFace) -> AccountFace {
        AccountFace(storedValue: face.storedValue)
    }
}

extension AccountFace: Codable {
    // One string, as the column holds it, so a value written by a later version still reads (as automatic).
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(storedValue: container.decodeNil() ? nil : try container.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        if let value = storedValue { try container.encode(value) } else { try container.encodeNil() }
    }
}
