import XCTest
@testable import SSCore

final class AccountLabelsTests: XCTestCase {
    private func account(_ id: String, _ email: String, kind: ProviderKind = .gmail, monogram: String? = nil) -> Account {
        Account(id: AccountID(id), kind: kind, email: email, displayName: "Alex Morgan", colorHex: "#000000",
                addedAt: Date(timeIntervalSince1970: 0), monogram: monogram)
    }

    func testMonogramIsTheRegistrableLabelsFirstLetter() {
        let accounts = [account("a", "alex@contoso.com", kind: .microsoft), account("b", "alex@fabrikam.co.uk", kind: .microsoft)]
        let monograms = AccountLabels.monograms(for: accounts)
        XCTAssertEqual(monograms[AccountID("a")], "C")
        XCTAssertEqual(monograms[AccountID("b")], "F")
    }

    func testConsumerDomainsUseTheProviderLetter() {
        let accounts = [account("a", "alex@gmail.com"), account("b", "alex@hotmail.com", kind: .microsoft)]
        let monograms = AccountLabels.monograms(for: accounts)
        XCTAssertEqual(monograms[AccountID("a")], "G")
        XCTAssertEqual(monograms[AccountID("b")], "O")
    }

    func testCollidingConsumerAccountsAddTheLocalPartsLetter() {
        let accounts = [account("a", "alex@gmail.com"), account("b", "morgan@googlemail.com")]
        let monograms = AccountLabels.monograms(for: accounts)
        XCTAssertEqual(monograms[AccountID("a")], "Ga")
        XCTAssertEqual(monograms[AccountID("b")], "Gm")
    }

    func testCollidingOrganisationsUseTwoLettersOfTheLabel() {
        let accounts = [account("a", "alex@contoso.com"), account("b", "alex@cobalt.com")]
        let monograms = AccountLabels.monograms(for: accounts)
        XCTAssertEqual(monograms[AccountID("a")], "Co")
        XCTAssertEqual(monograms[AccountID("b")], "Co")
        let demo = [account("a", "alex@demo-gmail.test"), account("b", "alex@demo-outlook.test", kind: .microsoft)]
        let demoMonograms = AccountLabels.monograms(for: demo)
        XCTAssertEqual(demoMonograms[AccountID("a")], "Dg")
        XCTAssertEqual(demoMonograms[AccountID("b")], "Do")
    }

    func testTypedMonogramWinsAndTheDerivedOneStaysThePlaceholder() {
        let accounts = [account("a", "alex@contoso.com", monogram: "Ab"), account("b", "alex@northwind.test")]
        XCTAssertEqual(AccountLabels.monograms(for: accounts)[AccountID("a")], "Ab")
        XCTAssertEqual(AccountLabels.derivedMonograms(for: accounts)[AccountID("a")], "C")
        XCTAssertEqual(AccountLabels.monograms(for: accounts)[AccountID("b")], "N")
    }

    func testATypedLetterTakenByAnotherAccountMakesTheDerivedOneTwoLetters() {
        let accounts = [account("a", "alex@contoso.com", monogram: "N"), account("b", "alex@northwind.test")]
        XCTAssertEqual(AccountLabels.monograms(for: accounts)[AccountID("b")], "No")
    }

    func testNames() {
        XCTAssertEqual(AccountLabels.name(for: account("a", "alex@contoso.com")), "Contoso")
        XCTAssertEqual(AccountLabels.name(for: account("a", "alex@fabrikam.co.uk")), "Fabrikam")
        XCTAssertEqual(AccountLabels.name(for: account("a", "alex.morgan@gmail.com")), "Personal")
        XCTAssertEqual(AccountLabels.name(for: account("a", "alex@demo-outlook.test")), "Demo Outlook")
    }
}
