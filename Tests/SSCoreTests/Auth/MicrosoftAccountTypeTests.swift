import Foundation
import SSCore
import XCTest

final class MicrosoftAccountTypeTests: XCTestCase {
    func testEachTypeSignsInThroughItsOwnAudience() {
        XCTAssertEqual(MicrosoftAccountType.personal.tenant(configured: "common"), "consumers")
        XCTAssertEqual(MicrosoftAccountType.workOrSchool.tenant(configured: "common"), "organizations")
        XCTAssertEqual(MicrosoftAccountType.workOrSchool.tenant(configured: nil), "organizations")
        XCTAssertEqual(MicrosoftAccountType.workOrSchool.tenant(configured: " consumers "), "organizations")
        XCTAssertEqual(MicrosoftAccountType.workOrSchool.tenant(configured: "contoso.com"), "contoso.com", "one organisation named in Settings")
    }

    func testAStoredTenantSaysWhichTypeItSignsInAs() {
        XCTAssertNil(MicrosoftAccountType(tenant: nil))
        XCTAssertNil(MicrosoftAccountType(tenant: "common"))
        XCTAssertEqual(MicrosoftAccountType(tenant: "consumers"), .personal)
        XCTAssertEqual(MicrosoftAccountType(tenant: "9188040d-6c67-4c5b-b112-36a304b66dad"), .personal)
        XCTAssertEqual(MicrosoftAccountType(tenant: "organizations"), .workOrSchool)
        XCTAssertEqual(MicrosoftAccountType(tenant: "contoso.com"), .workOrSchool)
    }

    /// Tokens saved before the choice existed have no tenant and keep the configured one; a refresh keeps the tenant.
    func testTokensRememberTheirTenantAndOldOnesHaveNone() throws {
        let old = #"{"accessToken":"a","refreshToken":"r","expiresAt":0,"scope":"Mail.ReadWrite"}"#
        let decoded = try JSONDecoder().decode(OAuthTokens.self, from: Data(old.utf8))
        XCTAssertNil(decoded.tenant)
        let tokens = OAuthTokens(accessToken: "a", refreshToken: "r", expiresAt: Date(timeIntervalSince1970: 0), scope: nil, tenant: "organizations")
        let roundTrip = try JSONDecoder().decode(OAuthTokens.self, from: JSONEncoder().encode(tokens))
        XCTAssertEqual(roundTrip.tenant, "organizations")
    }
}
