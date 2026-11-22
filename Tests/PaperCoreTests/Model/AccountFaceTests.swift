import XCTest
@testable import PaperCore

/// How the face choice is kept (`accounts.face`, Quire §5.55): NULL, `monogram` or `paper:<id>`, and anything else reads
/// as automatic, so a value from a later version still draws a face.
final class AccountFaceTests: XCTestCase {
    func testStoredValuesRoundTrip() {
        let faces: [AccountFace] = [.automatic, .monogram, .paper("fox"), .paper("curly-hair")]
        XCTAssertEqual(faces.map(\.storedValue), [nil, "monogram", "paper:fox", "paper:curly-hair"])
        for face in faces {
            XCTAssertEqual(AccountFace(storedValue: face.storedValue), face)
        }
    }

    func testUnreadableValuesAreAutomatic() {
        for value in ["", "paper:", "paper", "photo:me.png", "Monogram", "fox"] {
            XCTAssertEqual(AccountFace(storedValue: value), .automatic, value)
        }
        XCTAssertNil(AccountFace.paper("").storedValue)
        XCTAssertEqual(AccountFace.normalized(.paper("")), .automatic)
        XCTAssertEqual(AccountFace.normalized(.paper("owl")), .paper("owl"))
    }

    func testCodableIsTheStoredString() throws {
        let encoded = try JSONEncoder().encode([AccountFace.automatic, .monogram, .paper("owl")])
        XCTAssertEqual(String(decoding: encoded, as: UTF8.self), #"[null,"monogram","paper:owl"]"#)
        XCTAssertEqual(try JSONDecoder().decode([AccountFace].self, from: Data(#"[null,"monogram","paper:owl","hologram"]"#.utf8)),
                       [.automatic, .monogram, .paper("owl"), .automatic])
    }

    func testAnAccountStartsAutomatic() {
        let account = Account(id: AccountID("a"), kind: .gmail, email: "a@example.com", displayName: "A", addedAt: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(account.face, .automatic)
    }
}
