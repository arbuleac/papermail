import Foundation

/// Conversions between model values and their column representations: JSON columns, epoch milliseconds,
/// the roles bitmask and zlib-compressed body blobs.
enum MailStoreCodec {
    // Sorted keys keep the stored JSON byte-stable, so the FTS content view derives the same text for a row
    // whether it is read back today or after a reindex.
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()
    private static let decoder = JSONDecoder()

    static func json<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    static func decode<T: Decodable>(_ type: T.Type, from json: String) throws -> T {
        try decoder.decode(type, from: Data(json.utf8))
    }

    // MARK: Dates

    static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }

    static func date(_ milliseconds: Int64) -> Date {
        Date(timeIntervalSince1970: Double(milliseconds) / 1000)
    }

    // MARK: Roles

    static let inboxBit = 1
    static let sentBit = 2
    static let draftsBit = 4
    static let trashBit = 8
    static let spamBit = 16

    static func roleBits(_ roles: Set<MailboxRole>) -> Int {
        var bits = 0
        for role in roles {
            switch role {
            case .inbox: bits |= inboxBit
            case .sent: bits |= sentBit
            case .drafts: bits |= draftsBit
            case .trash: bits |= trashBit
            case .spam: bits |= spamBit
            }
        }
        return bits
    }

    static func roles(_ bits: Int) -> Set<MailboxRole> {
        var roles: Set<MailboxRole> = []
        if bits & inboxBit != 0 { roles.insert(.inbox) }
        if bits & sentBit != 0 { roles.insert(.sent) }
        if bits & draftsBit != 0 { roles.insert(.drafts) }
        if bits & trashBit != 0 { roles.insert(.trash) }
        if bits & spamBit != 0 { roles.insert(.spam) }
        return roles
    }

    // MARK: Typesetting

    /// `bodies.typesetting` values. Fixed numbers rather than the enum's order, so adding a case can never
    /// reinterpret stored rows.
    static func typesettingCode(_ typesetting: BodyTypesetting) -> Int {
        switch typesetting {
        case .plain: return 0
        case .unstyled: return 1
        case .styled: return 2
        }
    }

    /// An unknown code reads as styled, the same as NULL: the sender's design is the safe rendering.
    static func typesetting(_ code: Int?) -> BodyTypesetting? {
        guard let code else { return nil }
        switch code {
        case 0: return .plain
        case 1: return .unstyled
        default: return .styled
        }
    }

    // MARK: Bodies

    /// Bodies are compressed because a mailbox of 100k HTML messages is several gigabytes raw, and zlib makes
    /// typical email HTML five to ten times smaller at a cost of well under a millisecond per message.
    static func compress(_ text: String) throws -> Data {
        try (Data(text.utf8) as NSData).compressed(using: .zlib) as Data
    }

    static func decompress(_ blob: Data) throws -> String {
        let data = try (blob as NSData).decompressed(using: .zlib) as Data
        return String(decoding: data, as: UTF8.self)
    }
}
