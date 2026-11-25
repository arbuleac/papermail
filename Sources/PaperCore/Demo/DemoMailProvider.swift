import Foundation

/// A `MailProvider` over a generated, deterministic mailbox, for demo mode and end-to-end tests. It behaves like
/// the real providers where the engine can tell: bootstrap pages newest first with a cursor captured up front,
/// changes come from a log, applied changes and sent messages show up in later polls, and new mail trickles in
/// while the app runs. Nothing here touches the network.
public final class DemoMailProvider: MailProvider, Sendable {
    public let accountID: AccountID
    public let kind: ProviderKind
    private let mailbox: DemoMailbox

    init(mailbox: DemoMailbox) {
        self.accountID = mailbox.accountID
        self.kind = mailbox.profile.kind
        self.mailbox = mailbox
    }

    public convenience init(account: Account, service: DemoMailService) {
        self.init(mailbox: service.mailbox(for: account.id, kind: account.kind))
    }

    public func profile() async throws -> AccountProfile {
        AccountProfile(email: mailbox.profile.email, displayName: mailbox.profile.displayName)
    }

    public func bootstrap(page: String?, limit: Int) async throws -> BootstrapPage {
        var offset = 0
        var cursor: String?
        if let page {
            guard page.hasPrefix("offset:"), let value = Int(page.dropFirst("offset:".count)) else {
                throw ProviderError.decoding("unknown demo bootstrap page \(page)")
            }
            offset = value
        } else {
            // Captured before enumerating, as the contract requires, so nothing that changes meanwhile is lost.
            cursor = mailbox.currentCursor
        }
        let result = mailbox.bootstrapPage(offset: offset, limit: limit)
        return BootstrapPage(messages: result.messages, nextPage: result.next.map { "offset:\($0)" }, changeCursor: cursor)
    }

    public func changes(since cursor: String, limit: Int) async throws -> ChangesPage {
        mailbox.changes(since: cursor, limit: limit)
    }

    public func metadata(for providerIDs: [String]) async throws -> [MessageMetadata] {
        mailbox.metadata(for: providerIDs)
    }

    public func body(for providerID: String) async throws -> MessageBody {
        guard let body = mailbox.body(for: providerID) else { throw ProviderError.notFound }
        return body
    }

    public func attachment(messageID providerID: String, attachmentID: String) async throws -> Data {
        guard let data = mailbox.attachment(messageID: providerID, attachmentID: attachmentID) else {
            throw ProviderError.notFound
        }
        return data
    }

    public func apply(_ change: MetadataChange, to providerIDs: [String]) async throws {
        mailbox.apply(change, to: providerIDs)
    }

    public func send(_ message: OutgoingMessage) async throws -> SendReceipt {
        mailbox.send(message)
    }

    public func search(_ text: String, limit: Int) async throws -> [String] {
        mailbox.search(text, limit: limit)
    }
}

/// The demo account's main calendar (`DemoCalendar`), served from its mailbox: its events, and the time the user sets
/// aside and removes, kept in memory for the run like the rest of the made-up server.
extension DemoMailProvider: CalendarProvider {
    /// The demo's token scope is "demo", which names no calendar scope, but its made-up calendar needs no Connect.
    public func hasCalendarPermission() async -> Bool { true }

    public func calendarEvents(in window: DateInterval) async throws -> CalendarListing {
        CalendarListing(events: mailbox.calendarEvents(in: window), requestCount: 1)
    }

    public func createCalendarEvent(_ event: CalendarEvent) async throws -> CalendarEvent {
        mailbox.createCalendarEvent(event)
    }

    public func deleteCalendarEvent(providerID: String) async throws {
        mailbox.deleteCalendarEvent(providerID: providerID)
    }

    public func calendarEventDetails(providerID: String, seriesID: String?, knownRepeats: String?,
                                     account: CalendarAccountFacts) async throws -> CalendarDetailsRead? {
        mailbox.calendarEventDetails(providerID: providerID)
    }
}

/// The demo account's server rules (its made-up Gmail filters or Outlook inbox rules), served from its mailbox and kept in
/// memory for the run like the rest of the made-up server.
extension DemoMailProvider: RuleProvider {
    /// The demo's token scope is "demo", which names no rules scope, but its made-up server needs no reconnect.
    public func hasRulesPermission() async -> Bool { true }

    public func serverRules() async throws -> ServerRuleListing {
        mailbox.serverRules()
    }

    public func createSenderRule(address: String, action: SenderRule.Action) async throws -> String {
        mailbox.createSenderRule(address: address, action: action)
    }

    public func deleteRule(serverID: String) async throws {
        mailbox.deleteRule(serverID: serverID)
    }
}
