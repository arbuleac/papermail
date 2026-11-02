import AppKit
import XCTest
@testable import SSDesign

/// Avatar initials, tint stability, face cache keys and the ring geometry (spec §4.3, §5.7, §5.29).
@MainActor
final class AvatarRendererTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        QuireTestEnvironment.forceDefaults()
    }

    override func tearDown() async throws {
        QuireTestEnvironment.reset()
        try await super.tearDown()
    }

    private let en = Locale(identifier: "en_US")

    func testInitialsTakeTheFirstAndLastWordOfTheName() {
        XCTAssertEqual(QuireAvatarRenderer.initials(displayName: "Ben Carter", address: "ben@contoso.test", locale: en), "BC")
        XCTAssertEqual(QuireAvatarRenderer.initials(displayName: "Priya Raman", address: "x@y.test", locale: en), "PR")
        XCTAssertEqual(QuireAvatarRenderer.initials(displayName: "Maria de la Cruz", address: "m@x.test", locale: en), "MC", "first and last word")
        XCTAssertEqual(QuireAvatarRenderer.initials(displayName: "Forge", address: "noreply@forge.test", locale: en), "F")
        XCTAssertEqual(QuireAvatarRenderer.initials(displayName: "  ", address: "diego@x.test", locale: en), "D", "a blank name falls back")
        XCTAssertEqual(QuireAvatarRenderer.initials(displayName: "\"Tom\" (Hughes)", address: "t@x.test", locale: en), "TH", "punctuation is skipped")
        XCTAssertEqual(QuireAvatarRenderer.initials(displayName: "élodie roux", address: "e@x.test", locale: en), "ÉR", "uppercased")
        XCTAssertEqual(QuireAvatarRenderer.initials(displayName: "Carter, Ben", address: "b@x.test", locale: en), "CB")
    }

    func testWithoutANameTheFirstAlphanumericOfTheAddress() {
        XCTAssertEqual(QuireAvatarRenderer.initials(displayName: nil, address: "ada.lovelace@x.test", locale: en), "A",
                       "one letter: the address has no words to take a second from")
        XCTAssertEqual(QuireAvatarRenderer.initials(displayName: nil, address: "_9lives@x.test", locale: en), "9")
        XCTAssertEqual(QuireAvatarRenderer.initials(displayName: nil, address: "", locale: en), "?")
    }

    func testTintIsStableAndCaseInsensitive() {
        let a = QuireAvatarRenderer.tint(forAddress: "Priya@Example.test")
        XCTAssertEqual(a, QuireAvatarRenderer.tint(forAddress: "priya@example.test"))
        XCTAssertEqual(a, Quire.avatarTint(forAddress: "PRIYA@EXAMPLE.TEST"))
        for _ in 0..<3 { XCTAssertEqual(QuireAvatarRenderer.tint(forAddress: "priya@example.test"), a, "no per-process seed") }
        let tints = Set(["ben@contoso.test", "priya@example.test", "diego@x.test", "a@b.c", "theo@x.test", "linda@x.test", "rachel@x.test", "forge@x.test"]
            .map { QuireAvatarRenderer.tint(forAddress: $0) })
        XCTAssertGreaterThan(tints.count, 2, "addresses spread across the tints")
    }

    func testSizes() {
        XCTAssertEqual(QuireAvatarRenderer.sizes, [24, 30, 36])
        XCTAssertEqual(QuireAvatarRenderer.sizes.map(QuireAvatarRenderer.initialsSize), [10, 12.5, 15])
        XCTAssertEqual(QuireAvatarRenderer.monogramSize(for: "C", diameter: 30), 14)
        XCTAssertEqual(QuireAvatarRenderer.monogramSize(for: "Ga", diameter: 30), 12)
        XCTAssertEqual(QuireAvatarRenderer.monogramSize(for: "C", diameter: 24), 11)
        XCTAssertEqual(QuireAvatarRenderer.monogramSize(for: "Ga", diameter: 24), 10)
        XCTAssertEqual(QuireFont.monogramFont(diameter: 20).pointSize, 10, "never below 10 pt")
    }

    func testFaceCacheKeyCoversEnvironmentSizeInitialsAndTint() {
        let light = QuireMode.light.appearance
        let dark = QuireMode.dark.appearance
        let key = QuireAvatarRenderer.cacheKey(initials: "BC", tint: .slate, diameter: 30, appearance: light)
        XCTAssertTrue(key.hasPrefix(QuireEnvironment.cacheKey(for: light)))
        XCTAssertNotEqual(key, QuireAvatarRenderer.cacheKey(initials: "BC", tint: .slate, diameter: 30, appearance: dark))
        XCTAssertNotEqual(key, QuireAvatarRenderer.cacheKey(initials: "BC", tint: .slate, diameter: 36, appearance: light))
        XCTAssertNotEqual(key, QuireAvatarRenderer.cacheKey(initials: "BK", tint: .slate, diameter: 30, appearance: light))
        XCTAssertNotEqual(key, QuireAvatarRenderer.cacheKey(initials: "BC", tint: .sea, diameter: 30, appearance: light))
        QuireEnvironment.shared.setOverrides(.init(isGraphite: false, increaseContrast: true, reduceMotion: false, reduceTransparency: false))
        XCTAssertNotEqual(key, QuireAvatarRenderer.cacheKey(initials: "BC", tint: .slate, diameter: 30, appearance: light), "contrast")
        QuireEnvironment.shared.setOverrides(.init(isGraphite: true, increaseContrast: false, reduceMotion: false, reduceTransparency: false))
        XCTAssertNotEqual(key, QuireAvatarRenderer.cacheKey(initials: "BC", tint: .slate, diameter: 30, appearance: light), "Graphite")
        QuireTestEnvironment.forceDefaults()
        XCTAssertEqual(key, QuireAvatarRenderer.cacheKey(initials: "BC", tint: .slate, diameter: 30, appearance: light))
        XCTAssertNotEqual(QuireAvatarRenderer.accountCacheKey(monogram: "C", slot: 0, diameter: 30, appearance: light),
                          QuireAvatarRenderer.accountCacheKey(monogram: "C", slot: 1, diameter: 30, appearance: light))
    }

    func testFacesAreCachedRingLessAndPerMode() {
        let renderer = QuireAvatarRenderer()
        let light = QuireMode.light.appearance
        let face = renderer.face(initials: "PR", tint: .heather, diameter: 30, appearance: light)
        XCTAssertTrue(face === renderer.face(initials: "PR", tint: .heather, diameter: 30, appearance: light), "a cache hit")
        XCTAssertTrue(face === renderer.cachedFace(initials: "PR", tint: .heather, diameter: 30, appearance: light))
        XCTAssertEqual(face.size, NSSize(width: 30, height: 30), "the face only: the ring is drawn by the row")
        let dark = renderer.face(initials: "PR", tint: .heather, diameter: 30, appearance: QuireMode.dark.appearance)
        XCTAssertFalse(face === dark)

        // The face is the tint's face colour, with the corners left clear for the row's fill.
        let rep = NSBitmapImageRep(cgImage: face.cgImage(forProposedRect: nil, context: nil, hints: nil)!)
        XCTAssertEqual(rep.pixelsWide, 60, "rendered at 2×")
        XCTAssertEqual(ColorLib.rgb2hex(ComponentSnapshot.rgba(of: rep, x: rep.pixelsWide / 2, y: 3)), "#E6DEEE", "Heather face in Light")
        XCTAssertEqual(ComponentSnapshot.rgba(of: rep, x: 0, y: 0).a, 0, accuracy: 0.01, "corners clear for the row's fill")
    }

    func testAsynchronousFaceLandsOnTheMainThreadOnce() {
        let renderer = QuireAvatarRenderer()
        let appearance = QuireMode.light.appearance
        let landed = expectation(description: "face rendered")
        landed.expectedFulfillmentCount = 2
        let images = ImageBox()
        let first = renderer.face(initials: "TN", tint: .fern, diameter: 24, appearance: appearance) { image in
            XCTAssertTrue(Thread.isMainThread)
            images.items.append(image)
            landed.fulfill()
        }
        let second = renderer.face(initials: "TN", tint: .fern, diameter: 24, appearance: appearance) { image in
            images.items.append(image)
            landed.fulfill()
        }
        XCTAssertNil(first)
        XCTAssertNil(second)
        wait(for: [landed], timeout: 5)
        XCTAssertEqual(images.items.count, 2)
        XCTAssertTrue(images.items[0] === images.items[1], "one render for every caller")
        XCTAssertTrue(renderer.cachedFace(initials: "TN", tint: .fern, diameter: 24, appearance: appearance) === images.items[0])
    }

    func testRingSitsOutsideATwoPointGap() {
        let face = NSRect(x: 24, y: 19, width: 30, height: 30)
        XCTAssertEqual(QuireAvatarRenderer.ringBounds(around: face), NSRect(x: 20, y: 15, width: 38, height: 38), "the 38 pt avatar box")
        let view = RingView(frame: NSRect(x: 0, y: 0, width: 60, height: 60))
        let snapshot = ComponentSnapshot.render(view, mode: .light, surface: .qSelWash)
        // The face spans 15…45 around x = 30: the gap (the row's fill) lies 15–17 pt from the centre, the ring 17–19.
        XCTAssertTrue(snapshot.matches(expected("selWash", mode: .light), at: NSPoint(x: 30 - 16, y: 30)), "gap is the row's fill")
        XCTAssertTrue(snapshot.matches(TokenResolver.resolve("account:Persimmon", .light), at: NSPoint(x: 30 - 18, y: 30)), "ring")
        XCTAssertTrue(snapshot.matches(expected("selWash", mode: .light), at: NSPoint(x: 30 - 20.5, y: 30)), "outside the ring")
    }
}

/// Collects images delivered on the main thread.
@MainActor
private final class ImageBox: @unchecked Sendable {
    var items: [NSImage] = []
}

/// Draws a 30 pt face at the centre with the account ring of slot 0 around it.
@MainActor
final class RingView: NSView {
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        let face = NSRect(x: 15, y: 15, width: 30, height: 30)
        QuireAvatarRenderer.drawFace(initials: "PR", tint: .heather, in: face)
        QuireAvatarRenderer.drawRing(around: face, accountSlot: 0)
    }
}
