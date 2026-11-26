import XCTest
import PaperCore

/// An event's related mail (`MailStoring.invitationMessages(for:)`, docs/DATA-MODEL.md "message_fts"): found by the
/// event's title in the subject through the full-text index, kept by the stored invitation's UID. Both stores.
extension MailStoreContractTests {
    private func relatedEvent(title: String = "Design review", uid: String? = "uid-9@google.com",
                              account: AccountID? = nil) -> CalendarEvent {
        let accountID = account ?? accountA
        return CalendarEvent(id: CalendarEvent.localID(accountID: accountID, providerID: "evt"), accountID: accountID,
                             providerID: "evt", title: title, start: date(86_400), end: date(90_000), response: .needsAction,
                             invitationUID: uid)
    }

    private func seedRelated(_ providerID: String, subject: String, uid: String = "uid-9@google.com", account: AccountID? = nil,
                             roles: Set<MailboxRole> = [.inbox], at offset: TimeInterval = 0, method: CalendarInvitation.Method = .request) throws {
        let accountID = account ?? accountA
        try store.upsertMessages([message(providerID, in: "c-" + providerID, account: accountID, subject: subject,
                                          date: date(offset), roles: roles)])
        let invitation = CalendarInvitation(method: method, uid: uid, title: subject, start: date(86_400), end: date(90_000),
                                            organizer: CalendarInvitation.Person(name: "Ben", address: "ben@contoso.test"))
        try store.saveBody(StoredBody(body: MessageBody(html: "<p>x</p>", text: nil), renderedHTML: "<p>x</p>", plainText: "x",
                                      invitation: invitation), for: MessageID(accountID: accountID, providerID: providerID))
    }

    func testRelatedMailIsFoundBySubjectAndUIDNewestFirst() throws {
        try seedRelated("first", subject: "Invitation: Design review @ Thu 19 Nov", at: 10)
        try seedRelated("update", subject: "Updated invitation: Design review", at: 20)
        try seedRelated("other", subject: "Invitation: Design review", uid: "someone-else@google.com", at: 30)
        try seedRelated("draft", subject: "Design review", roles: [.drafts], at: 40)
        try seedRelated("spam", subject: "Design review", roles: [.spam], at: 50)
        try seedRelated("trash", subject: "Design review", roles: [.trash], at: 60)
        try seedRelated("theirs", subject: "Design review", account: accountB, at: 70)
        try store.upsertMessages([message("plain", in: "c-plain", subject: "Design review notes", date: date(80))])

        let found = try store.invitationMessages(for: relatedEvent()).map(\.message.id.providerID)
        XCTAssertEqual(found, ["trash", "update", "first"], "the UID's, newest first; drafts, spam, another account out; Trash kept")
    }

    func testAnExchangeOccurrenceUIDMatchesItsSeries() throws {
        let series = "040000008200E00074C5B7101A82E00800000000A0B1C2D3000000000000000010000000AABBCCDD"
        let occurrence = String(series.prefix(32)) + "07EA0105" + String(series.dropFirst(40))
        try seedRelated("series", subject: "Weekly sync", uid: series)
        XCTAssertEqual(try store.invitationMessages(for: relatedEvent(title: "Weekly sync", uid: occurrence)).map(\.message.id.providerID),
                       ["series"])
    }

    func testATitleWithQuotesOrSearchSyntaxIsSafeAndOneWithNoWordFindsNothing() throws {
        try seedRelated("quoted", subject: #"Review "Q3" plan AND NOT -x OR subject:y"#, uid: "uid-9@google.com")
        XCTAssertEqual(try store.invitationMessages(for: relatedEvent(title: #"Review "Q3" plan AND NOT -x OR subject:y"#))
            .map(\.message.id.providerID), ["quoted"])
        XCTAssertEqual(try store.invitationMessages(for: relatedEvent(title: "— !! —")), [])
        XCTAssertEqual(try store.invitationMessages(for: relatedEvent(uid: nil)), [], "no UID, nothing to match")
    }

    func testAnEvictedBodyGivesNoRelatedMail() throws {
        try seedRelated("old", subject: "Design review", at: -200 * 86_400)
        XCTAssertEqual(try store.evictBodies(receivedBefore: date(-90 * 86_400), excluding: [], limit: 10), 1)
        XCTAssertEqual(try store.invitationMessages(for: relatedEvent()), [])
    }

    func testNewerMailWithTheSameSubjectButNoInvitationSpendsNoRead() throws {
        // A weekly meeting's replies and notes share its subject: they carry no invitation, so they are passed over.
        for index in 0..<13 {
            try store.upsertMessages([message("re\(index)", in: "c-re\(index)", subject: "Re: Design review notes",
                                              date: date(Double(200 - index)))])
        }
        try seedRelated("invite", subject: "Invitation: Design review", at: 10)
        XCTAssertEqual(try store.invitationMessages(for: relatedEvent()).map(\.message.id.providerID), ["invite"],
                       "the invitation is the 14th newest match, the first with an invitation")
    }

    func testAtMostTwelveInvitationsAreRead() throws {
        for index in 0..<14 {
            try seedRelated("m\(index)", subject: "Design review", uid: index < 13 ? "other-\(index)" : "uid-9@google.com",
                            at: Double(100 - index))
        }
        XCTAssertEqual(try store.invitationMessages(for: relatedEvent()), [], "the match is the 14th newest: past the reads")
    }
}
