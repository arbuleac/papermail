import XCTest
@testable import PaperCore

final class AddressListParserTests: XCTestCase {
    func testQuotedNameWithCommaStaysOneEntry() {
        let parsed = AddressListParser.parse("\"Doe, John\" <john@example.com>")
        XCTAssertEqual(parsed, [EmailAddress(name: "Doe, John", address: "john@example.com")])
    }

    func testUnquotedNameAndAngleAddress() {
        let parsed = AddressListParser.parse("John Doe <john@example.com>")
        XCTAssertEqual(parsed, [EmailAddress(name: "John Doe", address: "john@example.com")])
    }

    func testBareAddresses() {
        XCTAssertEqual(AddressListParser.parse("john@example.com"), [EmailAddress(address: "john@example.com")])
        XCTAssertEqual(AddressListParser.parse("<john@example.com>"), [EmailAddress(address: "john@example.com")])
        XCTAssertEqual(AddressListParser.parse("mailto:john@example.com"), [EmailAddress(address: "john@example.com")])
    }

    func testCommaSemicolonAndNewlineSeparatedLists() {
        let input = "a@example.com, \"Bee, B\" <b@example.com>; c@example.com\nD <d@example.com>"
        let parsed = AddressListParser.parse(input)
        XCTAssertEqual(parsed.map(\.address), ["a@example.com", "b@example.com", "c@example.com", "d@example.com"])
        XCTAssertEqual(parsed.map(\.name), [nil, "Bee, B", nil, "D"])
    }

    func testCommentStyleAndNameWithoutBrackets() {
        XCTAssertEqual(AddressListParser.parse("john@example.com (John Doe)"), [EmailAddress(name: "John Doe", address: "john@example.com")])
        XCTAssertEqual(AddressListParser.parse("John Doe john@example.com"), [EmailAddress(name: "John Doe", address: "john@example.com")])
    }

    func testEscapedQuotesInNames() {
        let parsed = AddressListParser.parse("\"Say \\\"hi\\\"\" <q@example.com>")
        XCTAssertEqual(parsed, [EmailAddress(name: "Say \"hi\"", address: "q@example.com")])
    }

    func testInvalidInputIsKeptButFlagged() {
        let parsed = AddressListParser.parse("bob, a@b, @example.com, two@@example.com, ok@example.com, john@exa mple.com")
        XCTAssertEqual(parsed.count, 6)
        let invalid = AddressListParser.invalidEntries(in: parsed).map(\.address)
        XCTAssertEqual(invalid, ["bob", "a@b", "@example.com", "two@@example.com", "john@exa"])
        XCTAssertEqual(AddressListParser.validAddresses(in: "bob, ok@example.com").map(\.address), ["ok@example.com"])
    }

    func testWindowsLineBreaksSeparateEntries() {
        XCTAssertEqual(AddressListParser.parse("a@example.com\r\nb@example.com").map(\.address), ["a@example.com", "b@example.com"])
    }

    // MARK: Formatting

    func testFormatRoundTripsThroughParse() {
        let names = ["Doe, John", "A; B", "Say \"hi\"", "Back\\slash", "O'Brien", "'Quoted'", "(Parens)", "John Q. Public", "Jürgen Müller", "Line\nbreak"]
        for name in names {
            let address = EmailAddress(name: name, address: "person@example.com")
            let formatted = AddressListParser.format(address)
            XCTAssertEqual(AddressListParser.parse(formatted), [address], "\(name) -> \(formatted)")
            // Formatted entries survive being listed together, which is what the pasteboard carries.
            XCTAssertEqual(AddressListParser.parse([formatted, "other@example.com"].joined(separator: ", ")), [address, EmailAddress(address: "other@example.com")], formatted)
        }
    }

    func testFormatQuotesOnlyWhenNeeded() {
        XCTAssertEqual(AddressListParser.format(EmailAddress(name: "Doe, John", address: "john@example.com")), "\"Doe, John\" <john@example.com>")
        XCTAssertEqual(AddressListParser.format(EmailAddress(name: "John Doe", address: "john@example.com")), "John Doe <john@example.com>")
        XCTAssertEqual(AddressListParser.format(EmailAddress(name: "Say \"hi\"", address: "q@example.com")), "\"Say \\\"hi\\\"\" <q@example.com>")
        XCTAssertEqual(AddressListParser.format(EmailAddress(address: "john@example.com")), "john@example.com")
        XCTAssertEqual(AddressListParser.format(EmailAddress(name: "", address: "john@example.com")), "john@example.com")
        XCTAssertEqual(AddressListParser.format(EmailAddress(name: "john@example.com", address: "john@example.com")), "john@example.com")
    }

    // MARK: Entries for a quote-blind splitter

    func testEntriesReportThePiecesAQuoteBlindSplitterMakes() {
        let entries = AddressListParser.entries(in: "a@x.com; \"Last, First\" <lf@x.com>,\n\"A; B\" <ab@x.com>")
        XCTAssertEqual(entries, [
            AddressListParser.Entry(text: "a@x.com", pieces: ["a@x.com"]),
            AddressListParser.Entry(text: "\"Last, First\" <lf@x.com>", pieces: ["\"Last", "First\" <lf@x.com>"]),
            AddressListParser.Entry(text: "\"A; B\" <ab@x.com>", pieces: ["\"A", "B\" <ab@x.com>"]),
        ])
        XCTAssertEqual(AddressListParser.entries(in: " , ;\n"), [])
    }

    func testBlankInputYieldsNothing() {
        XCTAssertEqual(AddressListParser.parse(""), [])
        XCTAssertEqual(AddressListParser.parse(" ,, ;\n"), [])
    }

    func testValidation() {
        XCTAssertTrue(AddressListParser.isValid("john.doe+tag@sub.example.co.uk"))
        XCTAssertTrue(AddressListParser.isValid("jürgen@bücher.example"))
        XCTAssertFalse(AddressListParser.isValid("john..doe@example.com"))
        XCTAssertFalse(AddressListParser.isValid(".john@example.com"))
        XCTAssertFalse(AddressListParser.isValid("john@-example.com"))
        XCTAssertFalse(AddressListParser.isValid("john@example"))
        XCTAssertFalse(AddressListParser.isValid("john@example.c"))
        XCTAssertFalse(AddressListParser.isValid("john@127.0.0.1"))
        XCTAssertFalse(AddressListParser.isValid(""))
    }
}
