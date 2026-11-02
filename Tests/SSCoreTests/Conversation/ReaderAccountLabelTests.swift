import XCTest
@testable import SSCore

/// The kicker's account name and the quick reply's face monogram (spec §4.2): the face must be the rail's face.
final class ReaderAccountLabelTests: XCTestCase {
    private func account(_ email: String, _ id: String, monogram: String? = nil) -> Account {
        Account(id: AccountID(id), kind: .gmail, email: email, displayName: "", colorHex: "#000000",
                addedAt: Date(timeIntervalSince1970: 0), monogram: monogram)
    }

    func testNamesFollowTheDomain() {
        XCTAssertEqual(ReaderAccountLabel.name(of: account("alex@contoso.com", "1")), "Contoso")
        XCTAssertEqual(ReaderAccountLabel.name(of: account("alex@mail.fabrikam.co.uk", "1")), "Fabrikam")
        XCTAssertEqual(ReaderAccountLabel.name(of: account("alex@gmail.com", "1")), "Gmail")
        XCTAssertEqual(ReaderAccountLabel.name(of: account("alex@hotmail.com", "1")), "Outlook")
        XCTAssertEqual(ReaderAccountLabel.name(of: account("demo@demo-outlook.test", "1")), "Demo Outlook")
    }

    func testMonogramIsTheRegistrableLabelsFirstLetter() {
        let contoso = account("alex@contoso.com", "1")
        let fabrikam = account("alex@fabrikam.co.uk", "2")
        let gmail = account("alex@gmail.com", "3")
        let all = [contoso, fabrikam, gmail]
        XCTAssertEqual(ReaderAccountLabel.monogram(of: contoso, among: all), "C")
        XCTAssertEqual(ReaderAccountLabel.monogram(of: fabrikam, among: all), "F")
        XCTAssertEqual(ReaderAccountLabel.monogram(of: gmail, among: all), "G")
    }

    func testCollisionsBecomeTwoLetters() {
        let first = account("alex@gmail.com", "1")
        let second = account("morgan@gmail.com", "2")
        XCTAssertEqual(ReaderAccountLabel.monogram(of: first, among: [first, second]), "Ga")
        XCTAssertEqual(ReaderAccountLabel.monogram(of: second, among: [first, second]), "Gm")

        // The demo's two custom domains share "D" and "De": the first letter where the labels differ splits them.
        let outlook = account("demo@demo-outlook.test", "3")
        let gmailDemo = account("demo@demo-gmail.test", "4")
        XCTAssertEqual(ReaderAccountLabel.monogram(of: outlook, among: [outlook, gmailDemo]), "Do")
        XCTAssertEqual(ReaderAccountLabel.monogram(of: gmailDemo, among: [outlook, gmailDemo]), "Dg")

        let contoso = account("a@contoso.com", "5")
        let cobalt = account("b@cobalt.com", "6")
        XCTAssertEqual(ReaderAccountLabel.monogram(of: contoso, among: [contoso, cobalt]), "Cn")
        XCTAssertEqual(ReaderAccountLabel.monogram(of: cobalt, among: [contoso, cobalt]), "Cb")
    }

    func testATypedMonogramWinsAndTakesItsLetter() {
        let typed = account("a@northwind.com", "1", monogram: "C")
        let contoso = account("b@contoso.com", "2")
        XCTAssertEqual(ReaderAccountLabel.monogram(of: typed, among: [typed, contoso]), "C")
        XCTAssertEqual(ReaderAccountLabel.monogram(of: contoso, among: [typed, contoso]), "Co")
    }
}
