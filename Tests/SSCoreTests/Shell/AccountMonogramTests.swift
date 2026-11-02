import XCTest
@testable import SSCore

final class AccountMonogramTests: XCTestCase {
    private func account(_ id: String, _ email: String, kind: ProviderKind = .microsoft, monogram: String? = nil) -> Account {
        Account(id: AccountID(id), kind: kind, email: email, displayName: "Alex Morgan", colorHex: "#000000",
                addedAt: Date(timeIntervalSince1970: 0), monogram: monogram)
    }

    func testRegistrableLabel() {
        XCTAssertEqual(AccountMonogram.registrableLabel(of: "contoso.com"), "contoso")
        XCTAssertEqual(AccountMonogram.registrableLabel(of: "mail.contoso.com"), "contoso")
        XCTAssertEqual(AccountMonogram.registrableLabel(of: "fabrikam.co.uk"), "fabrikam")
        XCTAssertEqual(AccountMonogram.registrableLabel(of: "localhost"), "localhost")
    }

    func testDomainLettersAndProviderLetters() {
        XCTAssertEqual(AccountMonogram.letter(for: "alex@contoso.com"), "C")
        XCTAssertEqual(AccountMonogram.letter(for: "alex@fabrikam.co.uk"), "F")
        XCTAssertEqual(AccountMonogram.letter(for: "alex@gmail.com"), "G")
        XCTAssertEqual(AccountMonogram.letter(for: "alex@googlemail.com"), "G")
        XCTAssertEqual(AccountMonogram.letter(for: "alex@hotmail.com"), "O")
        XCTAssertEqual(AccountMonogram.letter(for: "alex@live.com"), "O")
    }

    func testNames() {
        XCTAssertEqual(AccountMonogram.name(for: account("a", "alex@contoso.com")), "Contoso")
        XCTAssertEqual(AccountMonogram.name(for: account("a", "alex@gmail.com", kind: .gmail)), "Gmail")
        XCTAssertEqual(AccountMonogram.name(for: account("a", "alex@outlook.com")), "Outlook")
    }

    func testDistinctLettersStaySingle() {
        let accounts = [account("1", "alex@contoso.com"), account("2", "alex@gmail.com", kind: .gmail), account("3", "a@fabrikam.com")]
        let monograms = AccountMonogram.monograms(for: accounts)
        XCTAssertEqual(monograms[AccountID("1")], "C")
        XCTAssertEqual(monograms[AccountID("2")], "G")
        XCTAssertEqual(monograms[AccountID("3")], "F")
    }

    func testTwoGmailAccountsTakeTheLocalPartInitial() {
        let accounts = [account("1", "alex@gmail.com", kind: .gmail), account("2", "maria@gmail.com", kind: .gmail)]
        let monograms = AccountMonogram.monograms(for: accounts)
        XCTAssertEqual(monograms[AccountID("1")], "Ga")
        XCTAssertEqual(monograms[AccountID("2")], "Gm")
    }

    func testTwoCustomDomainsTakeTheLabelsFirstTwoLetters() {
        let accounts = [account("1", "a@contoso.com"), account("2", "b@cloudy.io")]
        let monograms = AccountMonogram.monograms(for: accounts)
        XCTAssertEqual(monograms[AccountID("1")], "Co")
        XCTAssertEqual(monograms[AccountID("2")], "Cl")
    }

    func testLabelsSharingAPrefixSplitWhereTheyDiffer() {
        let accounts = [account("1", "alex@demo-gmail.test", kind: .gmail), account("2", "alex@demo-outlook.test")]
        let monograms = AccountMonogram.monograms(for: accounts)
        XCTAssertEqual(monograms[AccountID("1")], "Dg")
        XCTAssertEqual(monograms[AccountID("2")], "Do")
    }

    func testTypedMonogramWinsAndPushesTheOtherToTwoLetters() {
        let accounts = [account("1", "a@contoso.com", monogram: "Me"), account("2", "b@contoso.org"), account("3", "c@cloudy.io")]
        let monograms = AccountMonogram.monograms(for: accounts)
        XCTAssertEqual(monograms[AccountID("1")], "Me")
        XCTAssertNotEqual(monograms[AccountID("2")]?.lowercased(), monograms[AccountID("3")]?.lowercased())
        XCTAssertEqual(monograms[AccountID("2")]?.count, 2)
    }

    func testEveryMonogramIsUniqueEvenForIdenticalAddresses() {
        let accounts = [account("1", "alex@gmail.com", kind: .gmail), account("2", "alex@gmail.com", kind: .gmail)]
        let monograms = AccountMonogram.monograms(for: accounts)
        XCTAssertEqual(Set(monograms.values.map { $0.lowercased() }).count, 2)
    }
}
