import XCTest
@testable import SSCore

/// Monograms, tile letters and names (spec §4.2). One helper serves the rail, the list, the reader, the composer,
/// Settings and notifications, so these cases are the whole contract for every surface.
final class AccountLabelsTests: XCTestCase {
    private func account(_ id: String, _ email: String, kind: ProviderKind = .microsoft, monogram: String? = nil,
                         added: TimeInterval = 0, displayName: String = "Alex Morgan") -> Account {
        Account(id: AccountID(id), kind: kind, email: email, displayName: displayName, addedAt: Date(timeIntervalSince1970: added), monogram: monogram)
    }

    private func monograms(_ accounts: [Account]) -> [String] {
        let result = AccountLabels.monograms(for: accounts)
        return accounts.map { result[$0.id] ?? "" }
    }

    // MARK: Domains

    func testRegistrableLabel() {
        XCTAssertEqual(AccountLabels.registrableLabel(of: "contoso.com"), "contoso")
        XCTAssertEqual(AccountLabels.registrableLabel(of: "mail.contoso.com"), "contoso")
        XCTAssertEqual(AccountLabels.registrableLabel(of: "fabrikam.co.uk"), "fabrikam")
        XCTAssertEqual(AccountLabels.registrableLabel(of: "mail.fabrikam.co.uk"), "fabrikam")
        XCTAssertEqual(AccountLabels.registrableLabel(of: "localhost"), "localhost")
        XCTAssertEqual(AccountLabels.domain(of: "Alex@Contoso.COM"), "contoso.com")
    }

    // MARK: Names

    func testNames() {
        XCTAssertEqual(AccountLabels.name(for: account("a", "alex@contoso.com")), "Contoso")
        XCTAssertEqual(AccountLabels.name(for: account("a", "alex@mail.fabrikam.co.uk")), "Fabrikam")
        XCTAssertEqual(AccountLabels.name(for: account("a", "alex@localhost")), "Localhost")
        XCTAssertEqual(AccountLabels.name(for: account("a", "demo@demo-outlook.test")), "Demo Outlook")
    }

    func testConsumerAddressesAreNamedForTheirProvider() {
        XCTAssertEqual(AccountLabels.name(for: account("a", "alex.morgan@gmail.com", kind: .gmail)), "Gmail")
        XCTAssertEqual(AccountLabels.name(for: account("a", "alex@googlemail.com", kind: .gmail)), "Gmail")
        XCTAssertEqual(AccountLabels.name(for: account("a", "alex@outlook.com")), "Outlook")
        XCTAssertEqual(AccountLabels.name(for: account("a", "alex@hotmail.co.uk")), "Outlook")
        XCTAssertEqual(AccountLabels.name(for: account("a", "alex@live.com")), "Outlook")
    }

    func testSenderTitle() {
        XCTAssertEqual(AccountLabels.senderTitle(for: account("a", "alex@contoso.test")), "Alex Morgan <alex@contoso.test>")
        XCTAssertEqual(AccountLabels.senderTitle(for: account("a", "alex@contoso.test", displayName: "  ")), "alex@contoso.test")
    }

    // MARK: Monograms

    func testDomainLettersAndProviderLetters() {
        XCTAssertEqual(AccountLabels.letter(for: "alex@contoso.com"), "C")
        XCTAssertEqual(AccountLabels.letter(for: "alex@fabrikam.co.uk"), "F")
        XCTAssertEqual(AccountLabels.letter(for: "alex@gmail.com"), "G")
        XCTAssertEqual(AccountLabels.letter(for: "alex@googlemail.com"), "G")
        XCTAssertEqual(AccountLabels.letter(for: "alex@hotmail.com"), "O")
        XCTAssertEqual(AccountLabels.letter(for: "alex@live.com"), "O")
        XCTAssertEqual(AccountLabels.letter(for: "alex@outlook.fr"), "O")
    }

    func testDistinctLettersStaySingle() {
        let accounts = [account("1", "alex@contoso.com"), account("2", "alex@gmail.com", kind: .gmail), account("3", "a@fabrikam.co.uk")]
        XCTAssertEqual(monograms(accounts), ["C", "G", "F"])
    }

    func testCollidingConsumerAccountsAddTheLocalPartsLetter() {
        XCTAssertEqual(monograms([account("1", "alex@gmail.com", kind: .gmail), account("2", "maria@googlemail.com", kind: .gmail)]),
                       ["Ga", "Gm"])
    }

    func testCollidingCustomDomainsTakeTheLabelsFirstTwoLetters() {
        XCTAssertEqual(monograms([account("1", "a@contoso.com"), account("2", "b@cloudy.io")]), ["Co", "Cl"])
    }

    func testLabelsSharingAPrefixSplitWhereTheyDiffer() {
        XCTAssertEqual(monograms([account("1", "a@contoso.com"), account("2", "b@cobalt.com")]), ["Cn", "Cb"])
        XCTAssertEqual(monograms([account("1", "alex@demo-gmail.test", kind: .gmail), account("2", "alex@demo-outlook.test")]),
                       ["Dg", "Do"])
    }

    func testEveryDerivedMonogramIsUniqueEvenForIdenticalAddresses() {
        let twins = [account("1", "alex@gmail.com", kind: .gmail), account("2", "alex@gmail.com", kind: .gmail)]
        XCTAssertEqual(Set(monograms(twins).map { $0.lowercased() }).count, 2)
        let sameDomain = [account("1", "alex@contoso.com"), account("2", "sam@contoso.com")]
        XCTAssertEqual(monograms(sameDomain), ["Ca", "Cs"], "one domain: the local parts tell them apart")
    }

    func testTheResultDoesNotDependOnTheCallersOrder() {
        // Two Gmail addresses with the same initial: the older account keeps the spec's form.
        let alex = account("b", "alex@gmail.com", kind: .gmail, added: 1)
        let anna = account("a", "anna@gmail.com", kind: .gmail, added: 2)
        XCTAssertEqual(AccountLabels.monograms(for: [alex, anna]), AccountLabels.monograms(for: [anna, alex]))
        XCTAssertEqual(AccountLabels.monogram(for: alex, among: [anna, alex]), "Ga")
        XCTAssertEqual(AccountLabels.monogram(for: anna, among: [anna, alex]), "Gn")
    }

    // MARK: Typed monograms

    func testTypedMonogramWinsAndTheDerivedOneStaysThePlaceholder() {
        let accounts = [account("a", "alex@contoso.com", monogram: "Ab"), account("b", "alex@northwind.test")]
        XCTAssertEqual(monograms(accounts), ["Ab", "N"])
        XCTAssertEqual(AccountLabels.derivedMonogram(for: accounts[0], among: accounts), "C")
    }

    func testATypedLetterTakenFromAnotherAccountMakesTheDerivedOneTwoLetters() {
        let accounts = [account("a", "a@northwind.com", monogram: "C"), account("b", "b@contoso.com")]
        XCTAssertEqual(monograms(accounts), ["C", "Co"])
        // Cleared, the first account would derive N; the typed C still counts as taken for the other.
        XCTAssertEqual(AccountLabels.derivedMonogram(for: accounts[0], among: accounts), "N")
        XCTAssertEqual(AccountLabels.derivedMonogram(for: accounts[1], among: accounts), "Co")
    }

    func testATypedMonogramPushesOnlyTheCollidingAccountsToTwoLetters() {
        let accounts = [account("1", "a@contoso.com", monogram: "Me"), account("2", "b@contoso.org"), account("3", "c@cloudy.io")]
        let result = monograms(accounts)
        XCTAssertEqual(result[0], "Me")
        XCTAssertNotEqual(result[1].lowercased(), result[2].lowercased())
        XCTAssertEqual(result[1].count, 2)
    }

    func testAStaleCopyInTheSetGivesWayToTheAccountAsked() {
        let stored = account("a", "alex@contoso.com")
        var edited = stored
        edited.monogram = "Xy"
        XCTAssertEqual(AccountLabels.monogram(for: edited, among: [stored, account("b", "b@fabrikam.com")]), "Xy")
    }

    // MARK: Tile letters

    func testTileLettersAreTheShownMonogramsFirstLetter() {
        let accounts = [account("1", "alex@gmail.com", kind: .gmail), account("2", "maria@gmail.com", kind: .gmail),
                        account("3", "alex@mail.fabrikam.co.uk"), account("4", "alex@hotmail.com", monogram: "pe")]
        let initials = AccountLabels.initials(for: accounts)
        XCTAssertEqual(accounts.map { initials[$0.id] }, ["G", "G", "F", "P"])
        XCTAssertEqual(AccountLabels.initial(ofMonogram: ""), "?")
    }

    func testABlankTypedMonogramIsDerived() {
        let accounts = [account("1", "alex@gmail.com", kind: .gmail, monogram: "  ")]
        XCTAssertEqual(monograms(accounts), ["G"])
    }
}
