import Foundation
import SSCore
import XCTest
@testable import SSGmail

final class AddressParserTests: XCTestCase {
    func testNameAndAddress() {
        XCTAssertEqual(AddressParser.parse("Ada Lovelace <ada@example.com>"), [EmailAddress(name: "Ada Lovelace", address: "ada@example.com")])
    }

    func testQuotedNameWithComma() {
        XCTAssertEqual(AddressParser.parse("\"Lovelace, Ada\" <ada@example.com>"), [EmailAddress(name: "Lovelace, Ada", address: "ada@example.com")])
    }

    func testBareAndBracketedAddresses() {
        XCTAssertEqual(AddressParser.parse("ada@example.com"), [EmailAddress(name: nil, address: "ada@example.com")])
        XCTAssertEqual(AddressParser.parse("<ada@example.com>"), [EmailAddress(name: nil, address: "ada@example.com")])
        XCTAssertEqual(AddressParser.parse("  ada@example.com  "), [EmailAddress(name: nil, address: "ada@example.com")])
    }

    func testCommaSeparatedListWithMixedForms() {
        let parsed = AddressParser.parse("\"Doe, John\" <john@example.com>, Jane <jane@example.com>,bob@example.com , <carol@example.com>")
        XCTAssertEqual(parsed, [
            EmailAddress(name: "Doe, John", address: "john@example.com"),
            EmailAddress(name: "Jane", address: "jane@example.com"),
            EmailAddress(name: nil, address: "bob@example.com"),
            EmailAddress(name: nil, address: "carol@example.com"),
        ])
    }

    func testEscapedQuoteInsideQuotedName() {
        XCTAssertEqual(AddressParser.parse("\"John \\\"JD\\\" Doe\" <jd@example.com>"), [EmailAddress(name: "John \"JD\" Doe", address: "jd@example.com")])
    }

    func testCommentsAreIgnored() {
        XCTAssertEqual(AddressParser.parse("ada@example.com (Ada Lovelace)"), [EmailAddress(name: nil, address: "ada@example.com")])
        XCTAssertEqual(AddressParser.parse("Ada (the first) <ada@example.com>"), [EmailAddress(name: "Ada", address: "ada@example.com")])
    }

    func testGroupSyntax() {
        XCTAssertEqual(AddressParser.parse("undisclosed-recipients:;"), [])
        XCTAssertEqual(AddressParser.parse("Team: ada@example.com, bob@example.com;"), [
            EmailAddress(name: nil, address: "ada@example.com"),
            EmailAddress(name: nil, address: "bob@example.com"),
        ])
    }

    func testEncodedWordNamesAreDecoded() {
        XCTAssertEqual(AddressParser.parse("=?UTF-8?B?QWRhIEzDtnZlbGFjZQ==?= <ada@example.com>"), [EmailAddress(name: "Ada L\u{F6}velace", address: "ada@example.com")])
        XCTAssertEqual(AddressParser.parse("=?ISO-8859-1?Q?Jos=E9_Mu=F1oz?= <jose@example.com>"), [EmailAddress(name: "Jos\u{E9} Mu\u{F1}oz", address: "jose@example.com")])
    }

    func testNameWithoutBracketsIsSplitOnLastToken() {
        XCTAssertEqual(AddressParser.parse("Ada Lovelace ada@example.com"), [EmailAddress(name: "Ada Lovelace", address: "ada@example.com")])
    }

    func testSingleQuotedNameIsUnwrapped() {
        XCTAssertEqual(AddressParser.parse("'Ada' <ada@example.com>"), [EmailAddress(name: "Ada", address: "ada@example.com")])
    }

    func testRouteIsStripped() {
        XCTAssertEqual(AddressParser.parse("<@relay.example.com:ada@example.com>"), [EmailAddress(name: nil, address: "ada@example.com")])
    }

    func testEmptyAndJunkInput() {
        XCTAssertEqual(AddressParser.parse(""), [])
        XCTAssertEqual(AddressParser.parse("   ,  , "), [])
        XCTAssertEqual(AddressParser.parse("<>"), [])
        XCTAssertNil(AddressParser.first(""))
    }

    func testFirstReturnsTheLeadingMailbox() {
        XCTAssertEqual(AddressParser.first("a@example.com, b@example.com"), EmailAddress(name: nil, address: "a@example.com"))
    }

    func testCommaInsideAngleBracketsDoesNotSplit() {
        XCTAssertEqual(AddressParser.parse("Weird <\"a,b\"@example.com>, c@example.com").count, 2)
    }
}
