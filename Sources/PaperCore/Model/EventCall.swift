import Foundation

/// An event's call beyond its join address: the numbers to dial, the meeting ID and passcode, and a join address found
/// in the notes when the row has none.
public struct EventCall: Hashable, Codable, Sendable {
    /// What the provider calls the code dialled after a number: Google's PIN, Microsoft's conference ID.
    public enum PinLabel: String, Codable, Sendable {
        case pin
        case conferenceID
    }

    /// An https address on a known call host found in the notes (Zoom or Webex scheduled in Outlook); only when the row
    /// has no join address of its own.
    public var joinURL: String?
    public var meetingID: String?
    public var passcode: String?
    /// At most `maxPhones`.
    public var phones: [EventPhone]
    public var pinLabel: PinLabel
    /// An https page of more numbers.
    public var morePhonesURL: String?

    public static let maxPhones = 5

    public init(joinURL: String? = nil, meetingID: String? = nil, passcode: String? = nil, phones: [EventPhone] = [],
                pinLabel: PinLabel = .pin, morePhonesURL: String? = nil) {
        self.joinURL = joinURL
        self.meetingID = meetingID
        self.passcode = passcode
        self.phones = phones
        self.pinLabel = pinLabel
        self.morePhonesURL = morePhonesURL
    }

    /// Nothing to show.
    public var isEmpty: Bool {
        joinURL == nil && meetingID == nil && passcode == nil && phones.isEmpty && morePhonesURL == nil
    }

    private enum CodingKeys: String, CodingKey {
        case joinURL, meetingID, passcode, phones, pinLabel, morePhonesURL
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        joinURL = try? container.decodeIfPresent(String.self, forKey: .joinURL)
        meetingID = try? container.decodeIfPresent(String.self, forKey: .meetingID)
        passcode = try? container.decodeIfPresent(String.self, forKey: .passcode)
        phones = (try? container.decodeIfPresent([EventPhone].self, forKey: .phones)) ?? []
        pinLabel = (try? container.decodeIfPresent(PinLabel.self, forKey: .pinLabel)) ?? .pin
        morePhonesURL = try? container.decodeIfPresent(String.self, forKey: .morePhonesURL)
    }
}
