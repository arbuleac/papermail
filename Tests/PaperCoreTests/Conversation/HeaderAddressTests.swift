import XCTest
@testable import PaperCore

/// The positions the shell names an address by (spec §5.14, “Copying an address”), read back to the stored address as the
/// payload lists it, and what a copy writes, says and searches for.
final class HeaderAddressTests: XCTestCase {
    typealias F = ConversationFixtures
    private let own: Set<String> = ["me@example.com"]

    func testThePositionTheShellSendsReadsBackAndNothingElseDoes() {
        XCTAssertEqual(HeaderAddress("cc:2"), HeaderAddress(field: .cc, index: 2))
        XCTAssertEqual(HeaderAddress("from:0"), .sender)
        XCTAssertEqual(HeaderAddress(field: .bcc, index: 11).value, "bcc:11")
        for value in ["", "cc", "cc:", ":1", "cc:-1", "cc:1.5", "cc:٣", "cc: 1", "reply:0", "from:1", "to:1:2", "TO:1", "to:9999999",
                      "ben@contoso.test"] {
            XCTAssertNil(HeaderAddress(value), value)
        }
    }

    /// From, To and Cc index the stored lists; Bcc counts only on mail the user sent, as the payload builds the list; past
    /// the end, or an entry with no address, names nothing.
    func testAPositionReadsTheStoredList() {
        var received = F.message("m1", from: F.ada, to: [F.me, F.bob], cc: [F.carol, EmailAddress(name: "Group", address: "")])
        received.bcc = [EmailAddress(address: "hidden@example.com")]
        XCTAssertEqual(HeaderAddress.sender.address(in: received, ownAddresses: own), F.ada)
        XCTAssertEqual(HeaderAddress(field: .to, index: 1).address(in: received, ownAddresses: own), F.bob)
        XCTAssertEqual(HeaderAddress(field: .cc, index: 0).address(in: received, ownAddresses: own), F.carol)
        XCTAssertNil(HeaderAddress(field: .cc, index: 1).address(in: received, ownAddresses: own), "an empty group is no target")
        XCTAssertNil(HeaderAddress(field: .to, index: 2).address(in: received, ownAddresses: own), "past the end")
        XCTAssertNil(HeaderAddress(field: .bcc, index: 0).address(in: received, ownAddresses: own), "someone else's Bcc")

        var sent = F.message("m2", from: EmailAddress(name: "Me", address: "ME@example.com"), to: [F.ada])
        sent.bcc = [F.carol]
        XCTAssertEqual(HeaderAddress(field: .bcc, index: 0).address(in: sent, ownAddresses: own), F.carol, "the user's own, in any case")
        let nobody = F.message("m3", from: nil)
        XCTAssertNil(HeaderAddress.sender.address(in: nobody, ownAddresses: own))

        // The payload's list and the positions agree: the shell's `to:1` is the payload's second To.
        let payload = F.builder.build(messages: [received], bodies: [:], accounts: F.accounts)
        let fields = payload.messages[0].recipients
        XCTAssertEqual(fields.map(\.label), ["To", "Cc"], "no Bcc on someone else's mail")
        XCTAssertEqual(fields[0].people[1].address, HeaderAddress(field: .to, index: 1).address(in: received, ownAddresses: own)?.address)
    }

    /// The address alone, or as the composer's tokens copy it; Copy Name and Address only where the header gives a name.
    func testWhatACopyWritesAndSays() {
        let quoted = EmailAddress(name: "Carter, Ben", address: "ben@contoso.test")
        XCTAssertEqual(HeaderAddress.text(of: F.ada, form: .address), "ada@example.com")
        XCTAssertEqual(HeaderAddress.text(of: F.ada, form: .nameAndAddress), "Ada Lovelace <ada@example.com>")
        XCTAssertEqual(HeaderAddress.text(of: quoted, form: .nameAndAddress), "\"Carter, Ben\" <ben@contoso.test>")
        XCTAssertTrue(HeaderAddress.hasName(F.ada))
        XCTAssertFalse(HeaderAddress.hasName(EmailAddress(address: "x@y.io")))
        XCTAssertFalse(HeaderAddress.hasName(EmailAddress(name: "  ", address: "x@y.io")))
        XCTAssertFalse(HeaderAddress.hasName(EmailAddress(name: "x@y.io", address: "x@y.io")), "a name that is the address")
        XCTAssertEqual(HeaderAddress.announcement(of: F.ada, form: .address), "Copied ada@example.com.")
        XCTAssertEqual(HeaderAddress.announcement(of: F.ada, form: .nameAndAddress), "Copied Ada Lovelace, ada@example.com.")
        XCTAssertEqual(HeaderAddress.announcement(of: EmailAddress(address: "x@y.io"), form: .nameAndAddress), "Copied x@y.io.")
    }

    /// Show Mail from This Person searches with the operator the field already knows, quoted only when it must be.
    func testTheSearchForAPersonsMail() {
        XCTAssertEqual(HeaderAddress.fromQuery("ben@contoso.test"), "from:ben@contoso.test")
        XCTAssertEqual(HeaderAddress.fromQuery("odd name@contoso.test"), "from:\"odd name@contoso.test\"")
        XCTAssertEqual(SearchQuery(parsing: HeaderAddress.fromQuery("ben@contoso.test"))?.terms.map(\.kind), [.from("ben@contoso.test")],
                       "one term the field already parses")
        XCTAssertEqual(SearchQuery(parsing: HeaderAddress.fromQuery("odd name@contoso.test"))?.terms.map(\.kind),
                       [.from("odd name@contoso.test")])
    }
}
