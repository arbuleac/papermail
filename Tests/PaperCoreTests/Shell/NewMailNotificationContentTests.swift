import XCTest
@testable import PaperCore

final class NewMailNotificationContentTests: XCTestCase {
    private func row(sender: EmailAddress?, subject: String, snippet: String) -> ConversationSummary {
        let account = AccountID("a")
        return ConversationSummary(
            id: ConversationID(accountID: account, providerID: "c"), subject: subject, snippet: snippet,
            participants: sender.map { [EmailAddress(address: "first@contoso.test"), $0] } ?? [],
            latestDate: Date(timeIntervalSince1970: 0), messageCount: 1, unreadCount: 1, isStarred: false, hasAttachments: false,
            inInbox: true, inboxSection: .focused, latestMessageID: MessageID(accountID: account, providerID: "m"),
            hasPendingOperations: false
        )
    }

    func testPreviewNamesTheLatestSenderTheSubjectAndTheSnippetsFirstLine() {
        let content = NewMailNotificationContent.conversation(
            row(sender: EmailAddress(name: "Ben Carter", address: "ben@contoso.test"), subject: "Contoso rollout",
                snippet: "\n  Tested with three accounts.\nSecond line"),
            accountName: "Contoso", showPreviews: true
        )
        XCTAssertEqual(content, NewMailNotificationContent(title: "Ben Carter", subtitle: "Contoso rollout", body: "Tested with three accounts."))
    }

    func testFallbacksForMissingNameSubjectAndSender() {
        let noName = NewMailNotificationContent.conversation(row(sender: EmailAddress(address: "ben@contoso.test"), subject: " ", snippet: ""),
                                                            accountName: "Contoso", showPreviews: true)
        XCTAssertEqual(noName.title, "ben@contoso.test")
        XCTAssertEqual(noName.subtitle, "No subject")
        XCTAssertNil(noName.body)
        let noSender = NewMailNotificationContent.conversation(row(sender: nil, subject: "Hi", snippet: "x"), accountName: "Contoso",
                                                              showPreviews: true)
        XCTAssertEqual(noSender.title, "No sender")
    }

    func testBodyIsCutAt120Characters() {
        let long = String(repeating: "a", count: 200)
        let content = NewMailNotificationContent.conversation(row(sender: EmailAddress(address: "b@c.test"), subject: "s", snippet: long),
                                                             accountName: "C", showPreviews: true)
        XCTAssertEqual(content.body?.count, NewMailNotificationContent.bodyMaxCharacters)
        XCTAssertEqual(content.body?.last, "…")
    }

    func testPrivateModeHidesSenderSubjectAndBody() {
        let content = NewMailNotificationContent.conversation(
            row(sender: EmailAddress(name: "Ben Carter", address: "ben@contoso.test"), subject: "Secret", snippet: "Body"),
            accountName: "Contoso", showPreviews: false
        )
        XCTAssertEqual(content, NewMailNotificationContent(title: "New message", subtitle: "Contoso", body: nil))
    }

    func testSummary() {
        XCTAssertEqual(NewMailNotificationContent.summary(count: 4, accountName: "Contoso"),
                       NewMailNotificationContent(title: "4 new messages", subtitle: "Contoso"))
    }
}
