import XCTest
@testable import SSCore

/// Staleness of a rendered slot is decided from these inputs alone, so the rules below are what keeps
/// a store notification from reading every body of the shown conversation.
final class RenderInputsTests: XCTestCase {
    private typealias F = ConversationFixtures

    func testSyncBookkeepingDoesNotChangeInputs() {
        let before = F.message("m1")
        var after = before
        after.providerVersion = "99"
        after.labelIDs = ["INBOX", "IMPORTANT"]
        after.folderID = "AAMk"
        after.sizeBytes = 4096
        after.inboxSection = .focused
        XCTAssertEqual(
            RenderInputs(messages: [before]) { _ in true },
            RenderInputs(messages: [after]) { _ in true }
        )
    }

    func testWhatTheCardsShowChangesInputs() {
        let base = F.message("m1", isRead: false)
        let rendered = RenderInputs(messages: [base]) { _ in true }
        var read = base
        read.isRead = true
        XCTAssertNotEqual(rendered, RenderInputs(messages: [read]) { _ in true }, "the unread dot")
        var starred = base
        starred.isStarred = true
        XCTAssertNotEqual(rendered, RenderInputs(messages: [starred]) { _ in true }, "the star")
        XCTAssertNotEqual(rendered, RenderInputs(messages: [base]) { _ in false }, "a body arriving")
        XCTAssertNotEqual(rendered, RenderInputs(messages: [base, F.message("m2")]) { _ in true }, "a new message")
        XCTAssertNotEqual(rendered, RenderInputs(messages: [F.message("m1", subject: "Re: Engines", isRead: false)]) { _ in true })
        var blind = base
        blind.bcc = [F.carol]
        XCTAssertNotEqual(rendered, RenderInputs(messages: [blind]) { _ in true }, "Bcc shows in the expanded recipients")
        var draft = base
        draft.roles = [.drafts]
        XCTAssertNotEqual(rendered, RenderInputs(messages: [draft]) { _ in true }, "a draft renders read-only")
    }

    func testOrderAndVisibilityFollowTheBuilder() {
        let older = F.message("a", date: F.utc(2025, 1, 1))
        let newer = F.message("b", date: F.utc(2025, 1, 2))
        let spam = F.message("s", roles: [.spam])
        let inputs = RenderInputs(messages: [newer, spam, older]) { _ in true }
        XCTAssertEqual(inputs.messages.map(\.id.providerID), ["a", "b"])
        XCTAssertTrue(inputs.hasBody(older.id))
        XCTAssertFalse(inputs.hasBody(spam.id), "a message that is not rendered has no body to speak of")
    }

    func testRefreshProbesOnlyBodiesTheSlotNeverHad() {
        let hydrated = F.message("m1", date: F.utc(2025, 1, 1))
        let pending = F.message("m2", date: F.utc(2025, 1, 2))
        let rendered = RenderInputs(messages: [hydrated, pending]) { $0 == hydrated.id }
        XCTAssertTrue(rendered.hasBody(hydrated.id))
        XCTAssertFalse(rendered.hasBody(pending.id))

        var probed: [MessageID] = []
        let unchanged = rendered.refreshed(with: [hydrated, pending]) { id in
            probed.append(id)
            return false
        }
        XCTAssertEqual(probed, [pending.id], "a body the slot already rendered is never read back")
        XCTAssertEqual(unchanged, rendered)

        probed = []
        let arrived = rendered.refreshed(with: [hydrated, pending]) { id in
            probed.append(id)
            return true
        }
        XCTAssertEqual(probed, [pending.id])
        XCTAssertNotEqual(arrived, rendered)
        XCTAssertTrue(arrived.hasBody(pending.id))

        let newcomer = F.message("m3", date: F.utc(2025, 1, 3))
        probed = []
        _ = rendered.refreshed(with: [hydrated, pending, newcomer]) { id in
            probed.append(id)
            return false
        }
        XCTAssertEqual(probed, [pending.id, newcomer.id], "a message the slot has not seen is probed")
    }

    func testEmptyInputsAreStaleAgainstAnything() {
        let fresh = RenderInputs.empty.refreshed(with: [F.message("m1")]) { _ in false }
        XCTAssertNotEqual(fresh, RenderInputs.empty)
        XCTAssertEqual(RenderInputs.empty.refreshed(with: []) { _ in false }, RenderInputs.empty)
    }

    /// Mark-read and star change only the header of a card; the slot is patched with the flags instead of
    /// re-reading, re-scanning and re-sending every body of the thread.
    func testFlagOnlyChangesBecomePatches() {
        let messages = [F.message("m1", date: F.utc(2025, 1, 1), isRead: false), F.message("m2", date: F.utc(2025, 1, 2), isRead: false)]
        let rendered = RenderInputs(messages: messages) { _ in true }
        var read = messages
        read[0].isRead = true
        read[1].isStarred = true
        let patches = rendered.flagPatches(to: RenderInputs(messages: read) { _ in true })
        XCTAssertEqual(patches, [
            RenderPayload.FlagPatch(id: RenderPayload.messageKey(for: messages[0].id), isUnread: false, isStarred: false),
            RenderPayload.FlagPatch(id: RenderPayload.messageKey(for: messages[1].id), isUnread: true, isStarred: true),
        ])
        var renamed = read
        renamed[0].subject = "Other"
        XCTAssertNil(rendered.flagPatches(to: RenderInputs(messages: renamed) { _ in true }), "anything else needs a payload")
        XCTAssertNil(rendered.flagPatches(to: RenderInputs(messages: read) { _ in false }), "a body arriving needs a payload")
        XCTAssertNil(rendered.flagPatches(to: RenderInputs(messages: Array(read.prefix(1))) { _ in true }))
    }
}
