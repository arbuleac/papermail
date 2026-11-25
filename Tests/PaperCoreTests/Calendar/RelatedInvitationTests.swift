import XCTest
@testable import PaperCore

/// Which related mail stands for an event (`RelatedInvitation.pick`): the occurrence's own invitation, else the
/// series'; the latest revision; the newest message.
final class RelatedInvitationTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_795_000_000)

    private func candidate(_ id: String, recurrenceID: Date? = nil, sequence: Int = 0, method: CalendarInvitation.Method = .request,
                           at offset: TimeInterval) -> RelatedInvitation {
        let message = MessageMetadata(id: MessageID(accountID: AccountID("a"), providerID: id),
                                      conversationID: ConversationID(accountID: AccountID("a"), providerID: "c-" + id),
                                      subject: "Weekly", snippet: "", from: nil, to: [], date: base.addingTimeInterval(offset),
                                      roles: [.inbox], isRead: true, isStarred: false, hasAttachments: false)
        let invitation = CalendarInvitation(method: method, uid: "uid", sequence: sequence, recurrenceID: recurrenceID, title: "Weekly",
                                            start: base, end: base.addingTimeInterval(1_800))
        return RelatedInvitation(message: message, invitation: invitation)
    }

    private func event(series: String?, start: TimeInterval = 7 * 86_400) -> CalendarEvent {
        CalendarEvent(id: "a|e", accountID: AccountID("a"), providerID: "e", title: "Weekly", start: base.addingTimeInterval(start),
                      end: base.addingTimeInterval(start + 1_800), invitationUID: "uid", seriesID: series)
    }

    func testAnOccurrencePrefersItsOwnInvitationThenTheSeries() {
        let series = candidate("series", at: 10)
        let own = candidate("own", recurrenceID: base.addingTimeInterval(7 * 86_400), at: 5)
        let another = candidate("another", recurrenceID: base.addingTimeInterval(14 * 86_400), at: 20)
        XCTAssertEqual(RelatedInvitation.pick([another, series, own], for: event(series: "S"))?.message.id.providerID, "own")
        XCTAssertEqual(RelatedInvitation.pick([another, series], for: event(series: "S"))?.message.id.providerID, "series",
                       "another occurrence's never stands for this one")
        XCTAssertNil(RelatedInvitation.pick([another], for: event(series: "S")))
    }

    func testASingleEventTakesOneWithNoRecurrenceID() {
        let single = candidate("single", at: 1)
        let occurrence = candidate("occ", recurrenceID: base, at: 2)
        XCTAssertEqual(RelatedInvitation.pick([occurrence, single], for: event(series: nil))?.message.id.providerID, "single")
    }

    func testTheLatestRevisionThenTheNewestMessage() {
        let first = candidate("first", sequence: 0, at: 30)
        let update = candidate("update", sequence: 1, at: 10)
        XCTAssertEqual(RelatedInvitation.pick([first, update], for: event(series: nil))?.message.id.providerID, "update",
                       "superseded by SEQUENCE, whatever the message dates")
        let again = candidate("again", sequence: 1, at: 40)
        XCTAssertEqual(RelatedInvitation.pick([first, update, again], for: event(series: nil))?.message.id.providerID, "again")
    }

    func testACancellationAsTheLatestIsPicked() {
        let request = candidate("request", sequence: 0, at: 10)
        let cancel = candidate("cancel", sequence: 1, method: .cancel, at: 20)
        let picked = RelatedInvitation.pick([cancel, request], for: event(series: nil))
        XCTAssertEqual(picked?.message.id.providerID, "cancel")
        XCTAssertEqual(picked?.invitation.isCancelled, true)
    }
}
