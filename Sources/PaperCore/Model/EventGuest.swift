import Foundation

/// One guest of an event, as its details list them.
public struct EventGuest: Hashable, Codable, Sendable {
    public var name: String?
    public var address: String
    /// Nil when not known (Microsoft's copy of a guest's answers is the organizer's alone).
    public var response: InvitationResponse?
    /// The user themself.
    public var isSelf: Bool

    public init(name: String? = nil, address: String, response: InvitationResponse? = nil, isSelf: Bool = false) {
        self.name = name
        self.address = address
        self.response = response
        self.isSelf = isSelf
    }

    private enum CodingKeys: String, CodingKey {
        case name, address, response, isSelf
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try? container.decodeIfPresent(String.self, forKey: .name)
        address = (try? container.decodeIfPresent(String.self, forKey: .address)) ?? ""
        response = try? container.decodeIfPresent(InvitationResponse.self, forKey: .response)
        isSelf = (try? container.decodeIfPresent(Bool.self, forKey: .isSelf)) ?? false
    }
}
