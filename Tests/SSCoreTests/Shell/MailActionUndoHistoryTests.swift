import XCTest
@testable import SSCore

/// The undo rules of spec §5.30 and §6.1: coalescing within 1000 ms, Z reaching a toast's group while it shows and for
/// 10000 ms after, ⌘Z reaching every group still in the history, newest first, and a visible toast keeping its promise
/// over a quieter later action for both.
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

    /// An unsubscribe's archive (spec §5.30): its toast also names the request, so a later archive within the window
    /// starts a toast of its own instead of renaming it, and neither does the unsubscribe join an earlier archive's.
    func testAGroupThatDoesNotCoalesceKeepsItsToast() {
        var history = MailActionUndoHistory()
        let unsubscribe = history.add([record(.archive, 1)], at: t0, toasted: true, coalesces: false)
        history.bindToast(7, to: unsubscribe)
        XCTAssertNil(history.coalesce(record(.archive, 2), at: t0.addingTimeInterval(0.2), visibleToastID: 7))
        let archive = history.add(record(.archive, 2), at: t0.addingTimeInterval(0.2), toasted: true)
        XCTAssertNotEqual(archive, unsubscribe)
        XCTAssertEqual(history.groups.map(\.records.count), [1, 1])
        XCTAssertEqual(history.groups.first?.change, .archive, "Undo reverts an archive, so Edit › Undo reads Undo Archive")
        XCTAssertFalse(history.groups[0].coalesces)
        XCTAssertTrue(history.groups[1].coalesces)
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
        XCTAssertEqual(history.zTarget(at: t0.addingTimeInterval(4), visibleToastID: 7)?.id, id)
        XCTAssertNil(history.zTarget(at: t0.addingTimeInterval(4), visibleToastID: nil), "bound but not yet ended: only via its toast")
        history.toastEnded(7, at: t0.addingTimeInterval(5))
        XCTAssertNil(history.groups.first?.toastID)
        XCTAssertEqual(history.zTarget(at: t0.addingTimeInterval(14.9), visibleToastID: nil)?.id, id)
        XCTAssertNil(history.zTarget(at: t0.addingTimeInterval(15.1), visibleToastID: nil), "10000 ms after the toast left")
    }

    func testAQuietActionIsReachableForTheGraceFromWhenItHappened() {
        var history = MailActionUndoHistory()
        let id = history.add(record(.setStarred(true), 1), at: t0, toasted: false)
        XCTAssertEqual(history.zTarget(at: t0.addingTimeInterval(9.9), visibleToastID: nil)?.id, id)
        XCTAssertNil(history.zTarget(at: t0.addingTimeInterval(10.1), visibleToastID: nil))
    }

    func testAVisibleToastKeepsItsPromiseOverALaterQuietAction() {
        var history = MailActionUndoHistory()
        let archive = history.add(record(.archive, 1), at: t0, toasted: true)
        history.bindToast(7, to: archive)
        let star = history.add(record(.setStarred(true), 2), at: t0.addingTimeInterval(1), toasted: false)
        // “Archived · Undo Z” is on screen, so Z reverts the archive, not the star the row already shows.
        XCTAssertEqual(history.zTarget(at: t0.addingTimeInterval(2), visibleToastID: 7)?.id, archive)
        XCTAssertEqual(history.remove(archive)?.change, .archive)
        // With the archive reverted, the star is next while its own grace lasts.
        XCTAssertEqual(history.zTarget(at: t0.addingTimeInterval(3), visibleToastID: nil)?.id, star)
    }

    func testOnlyTheLatestGroupIsReachableOnceNoToastShows() {
        var history = MailActionUndoHistory()
        history.add(record(.setStarred(true), 1), at: t0, toasted: false)
        let archive = history.add(record(.archive, 2), at: t0.addingTimeInterval(1), toasted: true)
        history.bindToast(3, to: archive)
        history.toastEnded(3, at: t0.addingTimeInterval(2))
        history.toastEnded(3, at: t0.addingTimeInterval(2))
        XCTAssertEqual(history.zTarget(at: t0.addingTimeInterval(4), visibleToastID: nil)?.id, archive)
        XCTAssertNil(history.zTarget(at: t0.addingTimeInterval(13), visibleToastID: nil),
                     "the earlier star's own grace has run out by the time the archive's does")
    }

    func testRemovingAGroupTwiceFindsNothing() {
        var history = MailActionUndoHistory()
        let id = history.add(record(.trash, 1), at: t0, toasted: false)
        XCTAssertNotNil(history.remove(id))
        XCTAssertNil(history.remove(id))
        XCTAssertNil(history.zTarget(at: t0, visibleToastID: nil))
    }

    func testTheHistoryKeepsTheLatestGroups() {
        var history = MailActionUndoHistory()
        var last = 0
        for n in 0..<(MailActionUndoHistory.capacity + 5) { last = history.add(record(.setStarred(true), n), at: t0, toasted: false) }
        XCTAssertEqual(history.groups.count, MailActionUndoHistory.capacity)
        XCTAssertEqual(history.groups.last?.id, last)
        XCTAssertNotEqual(history.groups.first?.id, 1)
    }

    /// ⌘Z walks back through 50 steps (§6.1): the 51st drops the oldest, and only that one.
    func testTheFiftyFirstStepDropsTheOldest() {
        XCTAssertEqual(MailActionUndoHistory.capacity, 50)
        var history = MailActionUndoHistory()
        let ids = (1...51).map { n in history.add(record(.archive, n), at: t0.addingTimeInterval(Double(n) * 60), toasted: false) }
        XCTAssertEqual(history.groups.map(\.id), Array(ids.dropFirst()))
        XCTAssertNil(history.remove(ids[0]), "the first step is gone")
        var reverted: [Int] = []
        while let next = history.commandZTarget(visibleToastID: nil) {
            reverted.append(next.id)
            XCTAssertNotNil(history.remove(next.id))
        }
        XCTAssertEqual(reverted, Array(ids.dropFirst().reversed()), "50 presses, newest first")
        XCTAssertNil(history.commandZTarget(visibleToastID: nil), "then ⌘Z has nothing left: Can't Undo")
    }

    /// Past every toast and grace, ⌘Z still reverts the latest step, then the one before, however old; Z reaches none.
    func testCommandZReachesEveryGroupNewestFirstWhileZStopsAtTheGrace() {
        var history = MailActionUndoHistory()
        let archive = history.add(record(.archive, 1), at: t0, toasted: true)
        history.bindToast(1, to: archive)
        history.toastEnded(1, at: t0.addingTimeInterval(5))
        let star = history.add(record(.setStarred(true), 2), at: t0.addingTimeInterval(20), toasted: false)
        let trash = history.add(record(.trash, 3), at: t0.addingTimeInterval(40), toasted: true)
        history.bindToast(2, to: trash)
        history.toastEnded(2, at: t0.addingTimeInterval(45))
        let hourLater = t0.addingTimeInterval(3_600)

        XCTAssertNil(history.zTarget(at: hourLater, visibleToastID: nil), "Z is unchanged: nothing past the grace")
        XCTAssertNil(history.graceGroup(at: hourLater))
        XCTAssertEqual(history.commandZTarget(visibleToastID: nil)?.id, trash)
        XCTAssertFalse(history.isRecent(trash, at: hourLater), "a deeper ⌘Z")
        XCTAssertTrue(history.isRecent(trash, at: t0.addingTimeInterval(50)), "within its grace it is a recent step")
        XCTAssertEqual(history.remove(trash)?.change, .trash, "removing pops one")
        XCTAssertEqual(history.commandZTarget(visibleToastID: nil)?.id, star, "a star never had a toast, and ⌘Z still reaches it")
        XCTAssertEqual(history.remove(star)?.change, .setStarred(true))
        XCTAssertEqual(history.commandZTarget(visibleToastID: nil)?.id, archive)
        XCTAssertEqual(history.remove(archive)?.change, .archive)
        XCTAssertNil(history.commandZTarget(visibleToastID: nil))
    }

    /// A visible toast is a promise for ⌘Z as for Z: its step goes first, even when a quieter one came after it, and the
    /// rest follow newest first.
    func testTheVisibleToastStillWinsForCommandZ() {
        var history = MailActionUndoHistory()
        let old = history.add(record(.archive, 1), at: t0, toasted: false)
        let archive = history.add(record(.archive, 2), at: t0.addingTimeInterval(100), toasted: true)
        history.bindToast(9, to: archive)
        let star = history.add(record(.setStarred(true), 3), at: t0.addingTimeInterval(101), toasted: false)
        XCTAssertEqual(history.commandZTarget(visibleToastID: 9)?.id, archive)
        XCTAssertEqual(history.zTarget(at: t0.addingTimeInterval(102), visibleToastID: 9)?.id, archive)
        XCTAssertTrue(history.isRecent(archive, at: t0.addingTimeInterval(500)), "its toast still shows")
        XCTAssertNotNil(history.remove(archive))
        XCTAssertEqual(history.commandZTarget(visibleToastID: nil)?.id, star)
        XCTAssertNotNil(history.remove(star))
        XCTAssertEqual(history.commandZTarget(visibleToastID: nil)?.id, old)
        XCTAssertNil(history.zTarget(at: t0.addingTimeInterval(102), visibleToastID: nil), "Z: the old step's grace is long over")
    }

    /// A removed account takes its share of the history with it: its records leave a step that holds other accounts'
    /// too, a step of only its records goes, and so does an external step that named it. The rest stay in order.
    func testRemovingAnAccountDropsItsSteps() {
        let other = AccountID("other")
        func record(_ change: MetadataChange, _ n: Int, in account: AccountID) -> MailActionRecord {
            let message = MessageMetadata(
                id: MessageID(accountID: account, providerID: "m\(n)"),
                conversationID: ConversationID(accountID: account, providerID: "t\(n)"),
                subject: "Subject", snippet: "", from: nil, to: [], date: t0,
                roles: [.inbox], isRead: true, isStarred: false, hasAttachments: false
            )
            return MailActionRecord.make(change, on: [message], conversation: message.conversationID)!
        }
        var history = MailActionUndoHistory()
        let mixed = history.add([record(.archive, 1, in: account), record(.archive, 2, in: other)], at: t0, toasted: true)
        let mine = history.add(record(.setStarred(true), 3, in: account), at: t0, toasted: false)
        let snooze = history.addExternal(command: "Snooze", accounts: [account], at: t0, toasted: true)
        let theirs = history.addExternal(command: "Discard Draft", accounts: [other], at: t0, toasted: true)
        XCTAssertEqual(history.groups.first?.accounts, [account, other])

        let gone = history.removeAccounts([account])
        XCTAssertEqual(Set(gone), [mine, snooze])
        XCTAssertEqual(history.groups.map(\.id), [mixed, theirs])
        XCTAssertEqual(history.groups.first?.records.map(\.accountID), [other])
        XCTAssertEqual(history.groups.first?.accounts, [other])
        XCTAssertEqual(history.commandZTarget(visibleToastID: nil)?.id, theirs)
        XCTAssertTrue(history.removeAccounts([]).isEmpty)
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
        XCTAssertEqual(history.zTarget(at: t0, visibleToastID: 4)?.id, id)
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
        XCTAssertEqual(history.zTarget(at: t0.addingTimeInterval(1.8), visibleToastID: 1)?.id, id)
        XCTAssertNil(history.coalesceExternal(command: "Discard Draft", at: t0.addingTimeInterval(1.8), visibleToastID: 1))
    }

    /// An unsubscribe in Later ends a snooze, as E there does, and is named Archive like it, yet its toast also names the
    /// request: an E in Later within the window starts a toast of its own, and the next E joins that one as E always does.
    func testAnExternalStepThatDoesNotCoalesceKeepsItsToastFromTheSameCommand() {
        var history = MailActionUndoHistory()
        let unsubscribe = history.addExternal(command: "Archive", at: t0, toasted: true, coalesces: false)
        history.bindToast(1, to: unsubscribe)
        XCTAssertNil(history.coalesceExternal(command: "Archive", at: t0.addingTimeInterval(0.2), visibleToastID: 1))
        let archive = history.addExternal(command: "Archive", at: t0.addingTimeInterval(0.2), toasted: true)
        history.bindToast(2, to: archive)
        XCTAssertEqual(history.coalesceExternal(command: "Archive", at: t0.addingTimeInterval(0.5), visibleToastID: 2)?.id, archive)
        XCTAssertEqual(history.groups.map(\.id), [unsubscribe, archive])
        XCTAssertEqual(history.groups.map(\.externalCommand), ["Archive", "Archive"], "Edit › Undo reads Undo Archive for both")
        XCTAssertEqual(history.groups.map(\.coalesces), [false, true])
    }

    func testAnExternalStepIsReachableAndNoMailActionJoinsIt() {
        var history = MailActionUndoHistory()
        let archive = history.add(record(.archive, 1), at: t0, toasted: true)
        history.bindToast(1, to: archive)
        let discard = history.addExternal(command: "Discard Draft", at: t0.addingTimeInterval(0.2), toasted: true)
        history.bindToast(2, to: discard)
        XCTAssertNil(history.coalesce(record(.archive, 2), at: t0.addingTimeInterval(0.3), visibleToastID: 2))
        let group = history.zTarget(at: t0.addingTimeInterval(0.4), visibleToastID: 2)
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
