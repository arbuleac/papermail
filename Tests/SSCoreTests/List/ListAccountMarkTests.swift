import XCTest
@testable import SSCore

/// The account initial tile's letter and the account name in row labels (spec §4.2, monograms).
final class ListAccountMarkTests: XCTestCase {
    func testInitialsFromTheDomain() {
        XCTAssertEqual(ListAccountMark.initial(email: "alex@contoso.com", monogram: nil), "C")
        XCTAssertEqual(ListAccountMark.initial(email: "alex@mail.fabrikam.co.uk", monogram: nil), "F")
        XCTAssertEqual(ListAccountMark.initial(email: "alex@gmail.com", monogram: nil), "G")
        XCTAssertEqual(ListAccountMark.initial(email: "alex@googlemail.com", monogram: nil), "G")
        XCTAssertEqual(ListAccountMark.initial(email: "alex@hotmail.com", monogram: nil), "O")
        XCTAssertEqual(ListAccountMark.initial(email: "alex@live.com", monogram: nil), "O")
    }

    func testAnEditedMonogramWins() {
        XCTAssertEqual(ListAccountMark.initial(email: "alex@gmail.com", monogram: "pe"), "P")
        XCTAssertEqual(ListAccountMark.initial(email: "alex@gmail.com", monogram: "  "), "G", "a blank monogram is derived")
    }

    func testNames() {
        XCTAssertEqual(ListAccountMark.name(email: "alex@contoso.com"), "Contoso")
        XCTAssertEqual(ListAccountMark.name(email: "alex@fabrikam.co.uk"), "Fabrikam")
        XCTAssertEqual(ListAccountMark.name(email: "alex@gmail.com"), "Gmail")
        XCTAssertEqual(ListAccountMark.name(email: "alex@outlook.com"), "Outlook")
        XCTAssertEqual(ListAccountMark.name(email: "alex@localhost"), "Localhost")
    }
}
