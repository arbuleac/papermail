import Foundation
@testable import SSCore

/// Shared inputs for the conversation tests: one account, a UTC builder and metadata/body factories.
enum ConversationFixtures {
    static let accountID = AccountID("acct-1")
    static let conversationID = ConversationID(accountID: accountID, providerID: "thread-1")

    static let me = EmailAddress(name: "Me", address: "me@example.com")
    static let ada = EmailAddress(name: "Ada Lovelace", address: "ada@example.com")
    static let bob = EmailAddress(name: "Bob", address: "bob@example.com")
    static let carol = EmailAddress(name: "Carol", address: "carol@example.com")

    static let account = Account(
        id: accountID,
        kind: .gmail,
        email: "me@example.com",
        displayName: "Me",
        addedAt: Date(timeIntervalSince1970: 0)
    )

    static var accounts: [AccountID: Account] { [accountID: account] }

    /// Fixed calendar, locale and zone so date strings do not depend on the machine running the tests. British
    /// English writes the spec's own forms: a 24-hour clock and day before month ("Fri 30 Oct").
    static let builder = RenderPayloadBuilder(
        calendar: Calendar(identifier: .gregorian),
        locale: Locale(identifier: "en_GB"),
        timeZone: TimeZone(identifier: "UTC") ?? .current
    )

    static func utc(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = TimeZone(identifier: "UTC")
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        return components.date ?? .distantPast
    }

    static func message(
        _ providerID: String,
        from: EmailAddress? = ada,
        to: [EmailAddress] = [me],
        cc: [EmailAddress] = [],
        replyTo: [EmailAddress] = [],
        subject: String = "Engines",
        snippet: String = "A snippet",
        date: Date = utc(2025, 1, 3, 14, 5),
        roles: Set<MailboxRole> = [.inbox],
        isRead: Bool = true,
        isStarred: Bool = false,
        hasAttachments: Bool = false,
        internetMessageID: String? = nil,
        references: [String] = []
    ) -> MessageMetadata {
        MessageMetadata(
            id: MessageID(accountID: accountID, providerID: providerID),
            conversationID: conversationID,
            internetMessageID: internetMessageID,
            references: references,
            subject: subject,
            snippet: snippet,
            from: from,
            to: to,
            cc: cc,
            replyTo: replyTo,
            date: date,
            roles: roles,
            isRead: isRead,
            isStarred: isStarred,
            hasAttachments: hasAttachments
        )
    }

    static func body(
        html: String,
        text: String? = nil,
        plainText: String = "",
        attachments: [AttachmentInfo] = []
    ) -> StoredBody {
        StoredBody(
            body: MessageBody(html: html.isEmpty ? nil : html, text: text, attachments: attachments),
            renderedHTML: html,
            plainText: plainText
        )
    }
}
