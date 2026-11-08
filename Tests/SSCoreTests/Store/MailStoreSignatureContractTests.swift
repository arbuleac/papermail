import XCTest
import SSCore

/// The `MailStoring` contract for an account's signature (roadmap Q1.5, docs/DATA-MODEL.md `accounts.signature`): a
/// local setting on the account row, like the monogram. Written as an extension so `SQLiteMailStoreContractTests`
/// inherits every case and both stores are held to the same semantics.
extension MailStoreContractTests {
    private var signatureHTML: String { "<div><p><b>Alex Morgan</b></p><p>Contoso · <a href=\"https://contoso.test\">contoso.test</a></p></div>" }

    private func storedSignature(_ id: AccountID) throws -> String? {
        try XCTUnwrap(try store.accounts().first { $0.id == id }).signature
    }

    func testSignatureIsEmptyByDefaultAndRoundTrips() throws {
        XCTAssertEqual(try store.accounts().map(\.signature), [nil, nil], "empty by default")

        try store.setSignature(signatureHTML, for: accountA)
        XCTAssertEqual(try storedSignature(accountA), signatureHTML)
        XCTAssertNil(try storedSignature(accountB), "one account's signature is its own")

        try store.setSignature("  \n" + signatureHTML + "\n ", for: accountA)
        XCTAssertEqual(try storedSignature(accountA), signatureHTML, "only the white space around it goes")
        try store.setSignature(" \n\t", for: accountA)
        XCTAssertNil(try storedSignature(accountA), "blank means none")
        try store.setSignature(signatureHTML, for: accountA)
        try store.setSignature(nil, for: accountA)
        XCTAssertNil(try storedSignature(accountA))

        XCTAssertThrowsError(try store.setSignature(signatureHTML, for: AccountID("nobody"))) { error in
            guard case StoreError.notFound = error else { return XCTFail("expected notFound, got \(error)") }
        }
    }

    /// Re-saving an account it read (what a profile refresh or any other rewrite of the row does) keeps its signature,
    /// as it keeps its monogram; the other local settings and the sync state are left as they were.
    func testRewritingTheAccountRowKeepsItsSignature() throws {
        try store.setSignature(signatureHTML, for: accountA)
        try store.setMonogram("Ax", for: accountA)
        try store.setSyncCursor("cursor-1", for: accountA)

        var refreshed = try XCTUnwrap(try store.accounts().first { $0.id == accountA })
        refreshed.displayName = "Alex Morgan (Contoso)"
        refreshed.email = "alex@contoso.test"
        try store.upsertAccount(refreshed)
        let reread = try XCTUnwrap(try store.accounts().first { $0.id == accountA })
        XCTAssertEqual(reread.displayName, "Alex Morgan (Contoso)")
        XCTAssertEqual(reread.signature, signatureHTML, "the signature survives the rewrite")
        XCTAssertEqual(reread.monogram, "Ax")
        XCTAssertEqual(try store.syncCursor(for: accountA), "cursor-1")

        // An upsert carries the field, normalized like the setter.
        refreshed.signature = "  <div><p>Changed</p></div>  "
        try store.upsertAccount(refreshed)
        XCTAssertEqual(try storedSignature(accountA), "<div><p>Changed</p></div>")
        refreshed.signature = " "
        try store.upsertAccount(refreshed)
        XCTAssertNil(try storedSignature(accountA))
    }

    func testRemovingTheAccountRemovesItsSignature() throws {
        try store.setSignature(signatureHTML, for: accountA)
        try store.setSignature("<div><p>Bea</p></div>", for: accountB)
        try store.deleteAccount(accountA)
        XCTAssertEqual(try store.accounts().map(\.id), [accountB])
        XCTAssertEqual(try storedSignature(accountB), "<div><p>Bea</p></div>")

        // The same mailbox added again starts with none: the signature went with the row.
        try store.upsertAccount(account(accountA, email: "a@example.com", addedAt: base))
        XCTAssertNil(try storedSignature(accountA))
    }
}
