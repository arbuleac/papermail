import XCTest
@testable import SSCore

/// The undo rules of spec §5.30 and §6.1: coalescing within 1000 ms, a toast's undo reaching its group while
/// it shows and for 10000 ms after, and a visible toast keeping its promise over a quieter later action.
final class MailActionUndoHistoryTests: XCTestCase {
    private let account = AccountID("acct")
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    private func record(_ change: MetadataChange, _ n: Int) -> MailActionRecord {
        let message = MessageMetadata(
            id: MessageID(accountID: account, providerID: "m\(n)"),
            conversationID: ConversationID(accountID: account, providerID: "t\(n)"),
            subject: "Subject", snippet: "", from: nil, to: [], date: t0,
            roles: [.inbox], isRead: change != .setRead(true), isStarred: change == .setStarred(false), hasAttachments: false
        )
        return MailActionRecord.make(change, on: [message], conversation: message.conversationID)!
    }

    func testActionsWithinTheWindowCoalesceIntoTheVisibleToast() {
        var history = MailActionUndoHistory()
        let id = history.add(record(.archive, 1), at: t0, toasted: true)
        history.bindToast(7, to: id)
        let grown = history.coalesce(record(.archive, 2), at: t0.addingTimeInterval(0.6), visibleToastID: 7)
        XCTAssertEqual(grown?.id, id)
        XCTAssertEqual(grown?.records.count, 2)
        XCTAssertEqual(grown?.toastID, 7)
        // The window runs from the latest action, so a steady run keeps growing the same toast.
        XCTAssertEqual(history.coalesce(record(.archive, 3), at: t0.addingTimeInterval(1.5), visibleToastID: 7)?.records.count, 3)
        XCTAssertEqual(history.groups.count, 1)
    }

    func testCoalescingNeedsTheSameActionTheVisibleToastAndTheWindow() {
        var history = MailActionUndoHistory()
        let id = history.add(record(.archive, 1), at: t0, toasted: true)
        history.bindToast(7, to: id)
        XCTAssertNil(history.coalesce(record(.trash, 2), at: t0.addingTimeInterval(0.2), visibleToastID: 7), "another action")
        XCTAssertNil(history.coalesce(record(.archive, 3), at: t0.addingTimeInterval(1.2), visibleToastID: 7), "too late")
        XCTAssertNil(history.coalesce(record(.archive, 4), at: t0.addingTimeInterval(0.2), visibleToastID: 8), "toast replaced")
        XCTAssertNil(history.coalesce(record(.archive, 5), at: t0.addingTimeInterval(0.2), visibleToastID: nil), "toast gone")
        XCTAssertEqual(history.groups.first?.records.count, 1)
    }

    func testAToastedGroupIsTheTargetWhileVisibleAndForTheGraceAfter() {
        var history = MailActionUndoHistory()
        let id = history.add(record(.archive, 1), at: t0, toasted: true)
        history.bindToast(7, to: id)
        XCTAssertEqual(history.target(at: t0.addingTimeInterval(4), visibleToastID: 7)?.id, id)
        XCTAssertNil(history.target(at: t0.addingTimeInterval(4), visibleToastID: nil), "bound but not yet ended: only via its toast")
        history.toastEnded(7, at: t0.addingTimeInterval(5))
        XCTAssertNil(history.groups.first?.toastID)
        XCTAssertEqual(history.target(at: t0.addingTimeInterval(14.9), visibleToastID: nil)?.id, id)
        XCTAssertNil(history.target(at: t0.addingTimeInterval(15.1), visibleToastID: nil), "10000 ms after the toast left")
    }

    func testAQuietActionIsReachableForTheGraceFromWhenItHappened() {
        var history = MailActionUndoHistory()
        let id = history.add(record(.setStarred(true), 1), at: t0, toasted: false)
        XCTAssertEqual(history.target(at: t0.addingTimeInterval(9.9), visibleToastID: nil)?.id, id)
        XCTAssertNil(history.target(at: t0.addingTimeInterval(10.1), visibleToastID: nil))
    }

    func testAVisibleToastKeepsItsPromiseOverALaterQuietAction() {
        var history = MailActionUndoHistory()
        let archive = history.add(record(.archive, 1), at: t0, toasted: true)
        history.bindToast(7, to: archive)
        let star = history.add(record(.setStarred(true), 2), at: t0.addingTimeInterval(1), toasted: false)
        // “Archived · Undo Z” is on screen, so Z reverts the archive, not the star the row already shows.
        XCTAssertEqual(history.target(at: t0.addingTimeInterval(2), visibleToastID: 7)?.id, archive)
        XCTAssertEqual(history.remove(archive)?.change, .archive)
        // With the archive reverted, the star is next while its own grace lasts.
        XCTAssertEqual(history.target(at: t0.addingTimeInterval(3), visibleToastID: nil)?.id, star)
    }

    func testOnlyTheLatestGroupIsReachableOnceNoToastShows() {
        var history = MailActionUndoHistory()
        history.add(record(.setStarred(true), 1), at: t0, toasted: false)
        let archive = history.add(record(.archive, 2), at: t0.addingTimeInterval(1), toasted: true)
        history.bindToast(3, to: archive)
        history.toastEnded(3, at: t0.addingTimeInterval(2))
        history.toastEnded(3, at: t0.addingTimeInterval(2))
        XCTAssertEqual(history.target(at: t0.addingTimeInterval(4), visibleToastID: nil)?.id, archive)
        XCTAssertNil(history.target(at: t0.addingTimeInterval(13), visibleToastID: nil),
                     "the earlier star's own grace has run out by the time the archive's does")
    }

    func testRemovingAGroupTwiceFindsNothing() {
        var history = MailActionUndoHistory()
        let id = history.add(record(.trash, 1), at: t0, toasted: false)
        XCTAssertNotNil(history.remove(id))
        XCTAssertNil(history.remove(id))
        XCTAssertNil(history.target(at: t0, visibleToastID: nil))
    }

    func testTheHistoryKeepsTheLatestGroups() {
        var history = MailActionUndoHistory()
        var last = 0
        for n in 0..<(MailActionUndoHistory.capacity + 5) { last = history.add(record(.setStarred(true), n), at: t0, toasted: false) }
        XCTAssertEqual(history.groups.count, MailActionUndoHistory.capacity)
        XCTAssertEqual(history.groups.last?.id, last)
        XCTAssertNotEqual(history.groups.first?.id, 1)
    }
}

/// Several selected conversations make one group (spec §5.19), and steps that are not mail actions share the
/// history (§5.20).
final class MailActionUndoHistoryGroupTests: XCTestCase {
    private let account = AccountID("acct")
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    private func record(_ change: MetadataChange, _ n: Int) -> MailActionRecord {
        let message = MessageMetadata(
            id: MessageID(accountID: account, providerID: "m\(n)"),
            conversationID: ConversationID(accountID: account, providerID: "t\(n)"),
            subject: "Subject", snippet: "", from: nil, to: [], date: t0,
            roles: [.inbox], isRead: true, isStarred: false, hasAttachments: false
        )
        return MailActionRecord.make(change, on: [message], conversation: message.conversationID)!
    }

    func testSeveralRecordsStartOneGroupAndOneUndo() {
        var history = MailActionUndoHistory()
        let id = history.add([record(.archive, 1), record(.archive, 2), record(.archive, 3)], at: t0, toasted: true)
        history.bindToast(4, to: id)
        XCTAssertEqual(history.groups.count, 1)
        XCTAssertEqual(history.groups.first?.records.count, 3)
        XCTAssertEqual(history.target(at: t0, visibleToastID: 4)?.id, id)
        // One more E within the window grows the same toast: “Archived 4 conversations”.
        XCTAssertEqual(history.coalesce([record(.archive, 4)], at: t0.addingTimeInterval(0.5), visibleToastID: 4)?.records.count, 4)
        XCTAssertNil(history.coalesce([record(.archive, 5), record(.trash, 6)], at: t0.addingTimeInterval(0.6), visibleToastID: 4),
                     "a mixed batch never coalesces")
        XCTAssertEqual(history.remove(id)?.records.count, 4)
        XCTAssertTrue(history.groups.isEmpty)
    }

    /// E in Later: an external step joins the latest group only when asked, and only on a mail action's terms: the same
    /// command, its toast still the visible one, within the window.
    func testAnExternalStepCoalescesWithItsOwnCommandWhenAsked() {
        var history = MailActionUndoHistory()
        let id = history.addExternal(command: "Archive", at: t0, toasted: true)
        history.bindToast(1, to: id)
        XCTAssertNil(history.coalesceExternal(command: "Snooze", at: t0.addingTimeInterval(0.2), visibleToastID: 1), "another command")
        XCTAssertNil(history.coalesceExternal(command: "Archive", at: t0.addingTimeInterval(0.2), visibleToastID: 2), "toast replaced")
        XCTAssertNil(history.coalesceExternal(command: "Archive", at: t0.addingTimeInterval(0.2), visibleToastID: nil), "toast gone")
        XCTAssertNil(history.coalesceExternal(command: "Archive", at: t0.addingTimeInterval(1.2), visibleToastID: 1), "too late")
        XCTAssertNil(history.coalesce(record(.archive, 1), at: t0.addingTimeInterval(0.2), visibleToastID: 1), "a mail action never joins it")
        let grown = history.coalesceExternal(command: "Archive", at: t0.addingTimeInterval(0.8), visibleToastID: 1)
        XCTAssertEqual(grown?.id, id)
        XCTAssertEqual(grown?.toastID, 1)
        // The window runs from the latest press, as for mail actions.
        XCTAssertEqual(history.coalesceExternal(command: "Archive", at: t0.addingTimeInterval(1.7), visibleToastID: 1)?.id, id)
        XCTAssertEqual(history.groups.count, 1)
        XCTAssertEqual(history.target(at: t0.addingTimeInterval(1.8), visibleToastID: 1)?.id, id)
        XCTAssertNil(history.coalesceExternal(command: "Discard Draft", at: t0.addingTimeInterval(1.8), visibleToastID: 1))
    }

    func testAnExternalStepIsReachableAndNoMailActionJoinsIt() {
        var history = MailActionUndoHistory()
        let archive = history.add(record(.archive, 1), at: t0, toasted: true)
        history.bindToast(1, to: archive)
        let discard = history.addExternal(command: "Discard Draft", at: t0.addingTimeInterval(0.2), toasted: true)
        history.bindToast(2, to: discard)
        XCTAssertNil(history.coalesce(record(.archive, 2), at: t0.addingTimeInterval(0.3), visibleToastID: 2))
        let group = history.target(at: t0.addingTimeInterval(0.4), visibleToastID: 2)
        XCTAssertEqual(group?.id, discard)
        XCTAssertNil(group?.change)
        XCTAssertEqual(group?.externalCommand, "Discard Draft")
        XCTAssertEqual(history.toastGroup(visibleToastID: 2)?.id, discard)
        history.toastEnded(2, at: t0.addingTimeInterval(1))
        XCTAssertNil(history.toastGroup(visibleToastID: nil))
        XCTAssertEqual(history.graceGroup(at: t0.addingTimeInterval(10.9))?.id, discard)
        XCTAssertNil(history.graceGroup(at: t0.addingTimeInterval(11.1)))
    }
}
