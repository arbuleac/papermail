import Foundation

/// A number to dial into an event's call.
public struct EventPhone: Hashable, Codable, Sendable {
    /// As shown: “+1 555-0134”.
    public var number: String
    /// One tap: the number's digits, then the PIN after two pauses and a `#` (“+15550134,,601225430#”).
    public var dial: String
    /// The number's country (“US”), when stated.
    public var region: String?
    /// The PIN or conference ID as the provider writes it.
    public var pin: String?

    public init(number: String, dial: String, region: String? = nil, pin: String? = nil) {
        self.number = number
        self.dial = dial
        self.region = region
        self.pin = pin
    }

    private enum CodingKeys: String, CodingKey {
        case number, dial, region, pin
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        number = (try? container.decodeIfPresent(String.self, forKey: .number)) ?? ""
        dial = (try? container.decodeIfPresent(String.self, forKey: .dial)) ?? number
        region = try? container.decodeIfPresent(String.self, forKey: .region)
        pin = try? container.decodeIfPresent(String.self, forKey: .pin)
    }
}
