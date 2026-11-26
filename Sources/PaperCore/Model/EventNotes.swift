import Foundation

/// An event's notes as plain text with the links kept from them (https and tel only, `EventNotesReader`), converted
/// once at sync time: the card never parses HTML and nothing in the notes ever loads.
public struct EventNotes: Hashable, Codable, Sendable {
    /// A link over a UTF-16 range of `text`.
    public struct Link: Hashable, Codable, Sendable {
        public var location: Int
        public var length: Int
        public var url: String

        public init(location: Int, length: Int, url: String) {
            self.location = location
            self.length = length
            self.url = url
        }
    }

    /// At most `maxLength` UTF-16 units.
    public var text: String
    /// Ordered, never overlapping, at most `maxLinks`.
    public var links: [Link]
    /// The provider's notes were longer: the rest is on the provider's calendar.
    public var isCut: Bool

    public static let maxLength = 4_000
    public static let maxLinks = 100

    public init(text: String, links: [Link] = [], isCut: Bool = false) {
        self.text = text
        self.links = links
        self.isCut = isCut
    }

    private enum CodingKeys: String, CodingKey {
        case text, links, isCut
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = (try? container.decodeIfPresent(String.self, forKey: .text)) ?? ""
        links = (try? container.decodeIfPresent([Link].self, forKey: .links)) ?? []
        isCut = (try? container.decodeIfPresent(Bool.self, forKey: .isCut)) ?? false
    }
}
