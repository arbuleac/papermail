import AppKit
import SwiftUI
import XCTest
@testable import SSDesign

/// `QuireSpinner` against spec §5.37 and `QuireAvatarView` against §4.3 and §5.29.
@MainActor
final class SpinnerAndAvatarTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        QuireTestEnvironment.forceDefaults()
    }

    override func tearDown() async throws {
        QuireTestEnvironment.reset()
        try await super.tearDown()
    }

    // MARK: Spinner

    func testSpinnerSizesAndStrokes() {
        XCTAssertEqual(QuireSpinnerSize.allCases.map(\.diameter), [12, 16, 32])
        XCTAssertEqual(QuireSpinnerSize.allCases.map(\.stroke), [1.5, 2, 3])
        for size in QuireSpinnerSize.allCases {
            let host = SwiftUIHost(QuireSpinner(size, delay: 0))
            XCTAssertEqual(host.hostingView.fittingSize, CGSize(width: size.diameter, height: size.diameter), size.rawValue)
            host.close()
        }
    }

    func testSpinnerTurnsOncePerSpinnerTurn() {
        let start = Date(timeIntervalSinceReferenceDate: 0)
        XCTAssertEqual(QuireSpinner.angle(at: start), 0)
        XCTAssertEqual(QuireSpinner.angle(at: start.addingTimeInterval(Quire.Motion.spinnerTurn / 4)), 90, accuracy: 1e-6, "linear")
        XCTAssertEqual(QuireSpinner.angle(at: start.addingTimeInterval(Quire.Motion.spinnerTurn * 1.5)), 180, accuracy: 1e-6)
        XCTAssertEqual(Quire.Motion.spinnerTurn, 0.9)
    }

    func testRenderedArcIsThreeQuartersInItsColour() {
        // A large spinner at a fixed phase: the ring of the arc is ink3 for ¾ of the turn and open for ¼.
        let size = QuireSpinnerSize.large
        let view = QuireSpinnerArc(size: size, angle: 0).foregroundStyle(Color.qInk3)
            .frame(width: size.diameter, height: size.diameter).padding(4).background(Color.qSheet)
        let host = SwiftUIHost(view)
        let rep = host.render()
        let center = CGPoint(x: 4 + size.diameter / 2, y: 4 + size.diameter / 2)
        let radius = size.diameter / 2 - size.stroke / 2
        var drawn = 0
        let samples = 72
        for i in 0..<samples {
            let a = Double(i) / Double(samples) * 2 * .pi + .pi / Double(samples)
            let p = CGPoint(x: center.x + radius * cos(a), y: center.y + radius * sin(a))
            let c = rep.srgb(at: p)
            let ink = TokenResolver.resolve("ink3", .light)
            if max(abs(c.r - ink.r), abs(c.g - ink.g), abs(c.b - ink.b)) < 0.15 { drawn += 1 }
        }
        XCTAssertEqual(Double(drawn) / Double(samples), Quire.Layout.Progress.spinnerArc, accuracy: 0.05)
        host.close()
    }

    func testSpinnerWaitsOutItsDelay() {
        let view = QuireSpinner(.large, color: .qInk).padding(4).background(Color.qSheet)
        let host = SwiftUIHost(view)
        func ringIsVisible() -> Bool {
            let rep = host.render(settle: 0)
            // Sample the whole circle: once shown, ¾ of it is ink.
            var inked = 0
            for i in 0..<16 {
                let a = Double(i) / 16 * 2 * .pi
                let c = rep.srgb(at: CGPoint(x: 4 + 16 + 14.5 * cos(a), y: 4 + 16 + 14.5 * sin(a)))
                if c.r < 0.5 { inked += 1 }
            }
            return inked >= 8
        }
        XCTAssertFalse(ringIsVisible(), "not drawn before dur.spinnerDelay")
        host.settle(Quire.Motion.spinnerDelay + Quire.Motion.quick + 0.15)
        XCTAssertTrue(ringIsVisible(), "drawn once the delay and the fade have passed")
        host.close()
    }

    // MARK: Avatar

    func testAvatarLayoutSizeIsTheFaceAndTheRingDrawsOutside() {
        for diameter in Quire.Layout.Avatar.sizes {
            let host = SwiftUIHost(QuireAvatarView(initials: "BC", address: "ben@contoso.test", diameter: diameter, ringInk: 1))
            XCTAssertEqual(host.hostingView.fittingSize, CGSize(width: diameter, height: diameter), "the ring never moves layout")
            host.close()
        }
        let view = QuireAvatarView(accountMonogram: "C", ink: 0).padding(10).background(Color.qSheet)
        let host = SwiftUIHost(view)
        let rep = host.render()
        let face = Quire.Layout.Settings.accountFace
        let midY = 10 + face / 2
        let ink = TokenResolver.resolve("account:Persimmon", .light)
        XCTAssertColor(rep.srgb(at: CGPoint(x: 10 - 3, y: midY)), ink, "the 2 pt ring, 2–4 pt outside the face")
        XCTAssertColor(rep.srgb(at: CGPoint(x: 10 - 1, y: midY)), TokenResolver.resolve("sheet", .light), "the 2 pt gap is the surface beneath")
        XCTAssertColor(rep.srgb(at: CGPoint(x: 10 - 5, y: midY)), TokenResolver.resolve("sheet", .light), "nothing beyond 4 pt")
        // The face: the ink at rail.faceAlpha over sheet.
        var wash = TokenResolver.resolve("account:Persimmon", .light)
        wash.a = Double(Quire.Layout.Rail.faceAlpha)
        XCTAssertColor(rep.srgb(at: CGPoint(x: 10 + 4, y: midY)), ColorLib.over(wash, TokenResolver.resolve("sheet", .light)), "account face wash")
        host.close()
    }

    func testSenderFaceTakesItsTintInEveryMode() {
        let address = "priya@fabrikam.test"
        let tint = Quire.avatarTint(forAddress: address)
        for mode in QuireMode.allCases {
            QuireEnvironment.shared.setOverrides(.pinned(mode))
            let host = SwiftUIHost(QuireAvatarView(initials: "PR", address: address, diameter: 36), mode: mode)
            let rep = host.render()
            XCTAssertColor(rep.srgb(at: CGPoint(x: 5, y: 18)), TokenResolver.resolve("avatarFace:\(tint.name)", mode), "\(mode)")
            host.close()
        }
    }

    func testMonogramSizes() {
        // Sender initials: 0.42 × d, never under 10 (spec §5.29).
        XCTAssertEqual(QuireAvatarView.monogramFont(face: .sender(tint: .clay), monogram: "AM", diameter: 24).pointSize, 10)
        XCTAssertEqual(QuireAvatarView.monogramFont(face: .sender(tint: .clay), monogram: "AM", diameter: 30).pointSize, 12.5)
        XCTAssertEqual(QuireAvatarView.monogramFont(face: .sender(tint: .clay), monogram: "AM", diameter: 36).pointSize, 15)
        // Account monograms: 14 / 12 on 30 pt, 11 / 10 on 24 pt.
        XCTAssertEqual(QuireAvatarView.monogramFont(face: .account(slot: 0), monogram: "C", diameter: 30).pointSize, 14)
        XCTAssertEqual(QuireAvatarView.monogramFont(face: .account(slot: 0), monogram: "Ga", diameter: 30).pointSize, 12)
        XCTAssertEqual(QuireAvatarView.monogramFont(face: .account(slot: 0), monogram: "C", diameter: 24).pointSize, 11)
        XCTAssertEqual(QuireAvatarView.monogramFont(face: .account(slot: 0), monogram: "Ga", diameter: 24).pointSize, 10)
        // New York Semibold in both.
        let font = QuireAvatarView.monogramFont(face: .account(slot: 0), monogram: "C", diameter: 30)
        XCTAssertEqual(font.fontDescriptor.object(forKey: .family) as? String,
                       QuireFont.monogramFont(diameter: 30).fontDescriptor.object(forKey: .family) as? String)
        XCTAssertTrue(font.fontName.lowercased().contains("newyork") || font.familyName?.lowercased().contains("new york") == true,
                      font.fontName)
    }
}
