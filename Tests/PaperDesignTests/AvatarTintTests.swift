import XCTest
@testable import PaperDesign

/// Spec §4.3: a sender's tint is FNV-1a 32-bit over the lowercased address, modulo the tint count.
final class AvatarTintTests: XCTestCase {
    func testHashIsFNV1a32ModuloTheTintCount() {
        // The published FNV-1a 32-bit vectors: "" → 0x811C9DC5, "a" → 0xE40C292C, "foobar" → 0xBF9CF968.
        XCTAssertEqual(Quire.AvatarTint.allCases.count, 8)
        XCTAssertEqual(Quire.avatarTintIndex(forAddress: ""), Int(0x811C_9DC5 % 8))
        XCTAssertEqual(Quire.avatarTintIndex(forAddress: "a"), Int(0xE40C_292C % 8))
        XCTAssertEqual(Quire.avatarTintIndex(forAddress: "foobar"), Int(0xBF9C_F968 % 8))
    }

    func testCaseNeverChangesTheFace() {
        XCTAssertEqual(Quire.avatarTintIndex(forAddress: "Priya.Raman@Example.COM"), Quire.avatarTintIndex(forAddress: "priya.raman@example.com"))
        XCTAssertEqual(Quire.avatarTintIndex(forAddress: "A"), Quire.avatarTintIndex(forAddress: "a"))
        XCTAssertEqual(Quire.avatarTint(forAddress: "foobar"), .clay)
    }
}
