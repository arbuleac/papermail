import XCTest
@testable import PaperCore

final class PKCETests: XCTestCase {
    func testChallengeMatchesRFC7636AppendixB() {
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        XCTAssertEqual(PKCE.challenge(for: verifier), "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        XCTAssertEqual(PKCE(verifier: verifier).challenge, "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        XCTAssertEqual(PKCE.method, "S256")
    }

    func testGeneratedVerifierIsUnreservedAndLongEnough() {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let pkce = PKCE()
        XCTAssertEqual(pkce.verifier.count, 43)
        XCTAssertTrue(pkce.verifier.unicodeScalars.allSatisfy(allowed.contains))
        XCTAssertEqual(pkce.challenge, PKCE.challenge(for: pkce.verifier))
        XCTAssertNotEqual(PKCE().verifier, pkce.verifier)
    }

    func testBase64URLDropsPaddingAndUsesURLAlphabet() {
        XCTAssertEqual(Data([0xfb, 0xff]).base64URLEncodedString(), "-_8")
        XCTAssertEqual(Data("f".utf8).base64URLEncodedString(), "Zg")
    }
}
