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
        after.bcc = [F.carol]
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
}
