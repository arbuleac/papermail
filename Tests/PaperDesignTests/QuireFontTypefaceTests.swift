import AppKit
import SwiftUI
import XCTest
@testable import PaperDesign

/// The Font setting (spec §4.4): under SF Pro every New York role is set in its sans twin whatever the text,
/// monograms in `monogramSans`; under New York nothing changes, the script fallback included. Caches can never
/// hand back the other face after a switch.
final class QuireFontTypefaceTests: XCTestCase {
    override func setUp() {
        super.setUp()
        QuireEnvironment.shared.setTypeface(.newYork)
    }

    override func tearDown() {
        QuireEnvironment.shared.setTypeface(.newYork)
        QuireTestEnvironment.reset()
        super.tearDown()
    }

    private let serifRoles = QuireFont.Role.allCases.filter { $0.family == .serif }
    private let samples = ["Lisbon in March?", "Привет, Σοφία", "来週の議題", "مرحبا", "", "12:30 · 🙂"]

    private func isNewYork(_ font: NSFont) -> Bool {
        // The design shows in the PostScript name: New York is ".NewYork…".
        font.fontName.localizedCaseInsensitiveContains("NewYork")
    }

    private func weight(_ font: NSFont) -> CGFloat {
        let traits = font.fontDescriptor.object(forKey: .traits) as? [NSFontDescriptor.TraitKey: Any]
        return (traits?[.weight] as? NSNumber).map { CGFloat($0.doubleValue) } ?? 0
    }

    func testEveryNewYorkRoleHasATwinWithItsLineHeight() throws {
        XCTAssertEqual(Set(serifRoles), [.display, .headline, .masthead, .reading, .subject, .composeSubject, .aside, .monogram])
        for role in serifRoles {
            let twin = try XCTUnwrap(role.twin, role.rawValue)
            XCTAssertEqual(twin.family, .sf, role.rawValue)
            XCTAssertEqual(twin.spec.twinOf, role)
            XCTAssertEqual(twin.lineHeight, role.lineHeight, "\(role): twins keep the line height, so a switch moves nothing")
            XCTAssertEqual(twin.weight, role.weight, role.rawValue)
            XCTAssertEqual(twin.italic, role.italic, role.rawValue)
            XCTAssertEqual(twin.spec.unreadWeight, role.spec.unreadWeight, role.rawValue)
        }
        XCTAssertEqual(QuireFont.Role.monogramSans.spec.sizeRatio, 0.39)
        XCTAssertEqual(QuireFont.Role.monogramSans.spec.minSize, 10)
    }

    func testSFProSetsEveryNewYorkRoleInItsTwinForAnyText() throws {
        QuireEnvironment.shared.setTypeface(.sfPro)
        XCTAssertEqual(QuireEnvironment.typeface, .sfPro)
        for role in serifRoles {
            let twin = try XCTUnwrap(role.twin)
            XCTAssertEqual(QuireFont.resolvedRole(role), twin, role.rawValue)
            for text in samples {
                XCTAssertEqual(QuireFont.resolvedRole(role, for: text), twin, "\(role) \(text)")
            }
            guard role.size > 0 else { continue }
            let font = QuireFont.font(role)
            XCTAssertTrue(font === QuireFont.font(twin), role.rawValue)
            XCTAssertFalse(isNewYork(font), "\(role): \(font.fontName)")
            XCTAssertEqual(font.pointSize, twin.size, role.rawValue)
            XCTAssertTrue(QuireFont.font(role, for: "Agenda") === QuireFont.font(twin), role.rawValue)
            let string = QuireFont.attributedString("Agenda", role: role, color: .qInk)
            XCTAssertTrue(string.attribute(.font, at: 0, effectiveRange: nil) as? NSFont === QuireFont.font(twin), role.rawValue)
            let attributes = QuireFont.attributes(role, color: .qInk)
            XCTAssertTrue(attributes[.font] as? NSFont === QuireFont.font(twin), role.rawValue)
            XCTAssertEqual(attributes[.kern] as? CGFloat, twin.tracking == 0 ? nil : twin.tracking, "\(role): the twin's tracking")
            XCTAssertEqual(QuireFont.baselineOffset(role), QuireFont.baselineOffset(twin), role.rawValue)
            XCTAssertEqual(QuireFont.paragraphStyle(role).maximumLineHeight, role.lineHeight, role.rawValue)
        }
        // The unread weight survives the switch; SF Pro roles are untouched.
        XCTAssertTrue(QuireFont.font(.subject, unread: true) === QuireFont.font(.subjectSans, unread: true))
        XCTAssertEqual(weight(QuireFont.font(.subject, unread: true)), NSFont.Weight.semibold.rawValue, accuracy: 0.01)
        XCTAssertTrue(QuireFont.font(.aside).fontDescriptor.symbolicTraits.contains(.italic))
        for role in [QuireFont.Role.body, .sender, .badge, .mono, .meta, .writing] {
            XCTAssertEqual(QuireFont.resolvedRole(role), role)
            XCTAssertEqual(QuireFont.resolvedRole(role, for: "来週"), role)
        }
        // The static accessors and SwiftUI read the same cache.
        XCTAssertTrue(QuireFont.headline === QuireFont.font(.headlineSans))
        _ = Font.quire(.subject)
    }

    func testNewYorkKeepsTodaysBehaviourScriptFallbackIncluded() {
        XCTAssertEqual(QuireEnvironment.typeface, .newYork)
        for role in serifRoles {
            XCTAssertEqual(QuireFont.resolvedRole(role), role, role.rawValue)
            guard role.size > 0 else { continue }
            XCTAssertTrue(isNewYork(QuireFont.font(role)), "\(role): \(QuireFont.font(role).fontName)")
            XCTAssertEqual(QuireFont.resolvedRole(role, for: "Lisbon in March?"), role)
            XCTAssertEqual(QuireFont.resolvedRole(role, for: "Привет, Σοφία"), role)
            XCTAssertEqual(QuireFont.resolvedRole(role, for: "来週の議題"), role.twin, "\(role): New York lacks the script")
        }
        XCTAssertTrue(QuireFont.font(.reading, for: "Привет") === QuireFont.font(.reading))
        XCTAssertTrue(QuireFont.font(.reading, for: "مرحبا") === QuireFont.font(.readingSans))
        XCTAssertEqual(QuireFont.attributes(.display, color: .qInk)[.kern] as? CGFloat, -0.6)
        XCTAssertTrue(isNewYork(QuireFont.monogramFont(diameter: 30)))
        XCTAssertEqual(QuireFont.monogramSize(diameter: 30), 12.5)
        XCTAssertEqual(QuireFont.monogramSize(named: 14), 14)
        XCTAssertEqual(QuireAvatarRenderer.monogramSize(for: "C", diameter: 30), 14)
    }

    func testMonogramsAreTheSansTwinUnderSFPro() {
        QuireEnvironment.shared.setTypeface(.sfPro)
        XCTAssertEqual(QuireFont.resolvedRole(.monogram), .monogramSans)
        // 0.39 × d to the half point, never below 10 (spec §4.3, §5.29).
        XCTAssertEqual(QuireFont.monogramSize(diameter: 24), 10)
        XCTAssertEqual(QuireFont.monogramSize(diameter: 30), 11.5)
        XCTAssertEqual(QuireFont.monogramSize(diameter: 36), 14)
        let font = QuireFont.monogramFont(diameter: 30)
        XCTAssertFalse(isNewYork(font), font.fontName)
        XCTAssertEqual(font.pointSize, 11.5)
        XCTAssertEqual(weight(font), NSFont.Weight.semibold.rawValue, accuracy: 0.01)
        XCTAssertEqual(QuireAvatarRenderer.initialsSize(diameter: 36), 14)
        // Account monograms keep their optical size: the named sizes × 0.39 / 0.42, to the half point, min 10.
        XCTAssertEqual(QuireFont.monogramSize(named: 14), 13)
        XCTAssertEqual(QuireFont.monogramSize(named: 12), 11)
        XCTAssertEqual(QuireFont.monogramSize(named: 11), 10)
        XCTAssertEqual(QuireFont.monogramSize(named: 10), 10)
        XCTAssertEqual(QuireAvatarRenderer.monogramSize(for: "C", diameter: 30), 13)
        XCTAssertEqual(QuireAvatarRenderer.monogramSize(for: "Ga", diameter: 30), 11)
        XCTAssertEqual(QuireAvatarRenderer.monogramSize(for: "C", diameter: 24), 10)
        XCTAssertFalse(isNewYork(QuireFont.monogramFont(size: 13)))
        // SwiftUI faces, which pass the typeface they track.
        XCTAssertEqual(QuireAvatarView.monogramFont(face: .sender(tint: .clay), monogram: "AM", diameter: 30, typeface: .sfPro).pointSize, 11.5)
        XCTAssertEqual(QuireAvatarView.monogramFont(face: .account(slot: 0), monogram: "C", diameter: 30, typeface: .sfPro).pointSize, 13)
        XCTAssertFalse(isNewYork(QuireAvatarView.monogramFont(face: .account(slot: 0), monogram: "C", diameter: 30, typeface: .sfPro)))
        // An explicit typeface wins over the environment.
        XCTAssertTrue(isNewYork(QuireFont.monogramFont(diameter: 30, typeface: .newYork)))
        XCTAssertEqual(QuireAvatarView.monogramFont(face: .account(slot: 0), monogram: "C", diameter: 30, typeface: .newYork).pointSize, 14)
    }

    func testCacheKeysFollowTheTypeface() {
        QuireTestEnvironment.forceDefaults()
        let light = QuireMode.light.appearance
        let newYork = QuireEnvironment.cacheKey(for: light)
        let face = QuireAvatarRenderer.cacheKey(initials: "AM", tint: .sea, diameter: 30, appearance: light)
        let image = QuireAvatarRenderer.shared.face(initials: "AM", tint: .sea, diameter: 30, appearance: light)
        QuireEnvironment.shared.setTypeface(.sfPro)
        XCTAssertNotEqual(QuireEnvironment.cacheKey(for: light), newYork)
        XCTAssertNotEqual(QuireAvatarRenderer.cacheKey(initials: "AM", tint: .sea, diameter: 30, appearance: light), face)
        XCTAssertFalse(QuireAvatarRenderer.shared.face(initials: "AM", tint: .sea, diameter: 30, appearance: light) === image,
                       "a face drawn in New York is never served under SF Pro")
        QuireEnvironment.shared.setTypeface(.newYork)
        XCTAssertEqual(QuireEnvironment.cacheKey(for: light), newYork)
    }

    func testASwitchIsAnnouncedOnceAndSurvivesASystemRefresh() {
        QuireTestEnvironment.forceDefaults()
        let changed = expectation(forNotification: QuireEnvironment.didChangeNotification, object: QuireEnvironment.shared)
        QuireEnvironment.shared.setTypeface(.sfPro)
        wait(for: [changed], timeout: 1)
        XCTAssertEqual(QuireEnvironment.shared.snapshot.typeface, .sfPro)

        let quiet = expectation(forNotification: QuireEnvironment.didChangeNotification, object: QuireEnvironment.shared)
        quiet.isInverted = true
        QuireEnvironment.shared.setTypeface(.sfPro)
        QuireEnvironment.shared.refresh()
        wait(for: [quiet], timeout: 0.2)
        XCTAssertEqual(QuireEnvironment.typeface, .sfPro, "re-reading the system settings keeps the app's choice")

        // The gallery's override wins and gives the app's choice back when cleared.
        QuireEnvironment.shared.setOverrides(.init(isGraphite: false, increaseContrast: false, reduceMotion: false, reduceTransparency: false,
                                                   typeface: .newYork))
        XCTAssertEqual(QuireEnvironment.typeface, .newYork)
        QuireTestEnvironment.forceDefaults()
        XCTAssertEqual(QuireEnvironment.typeface, .sfPro)
    }

    func testFlippingBackAndForthNeverReturnsAStaleFont() {
        let roles = serifRoles.filter { $0.size > 0 }
        for _ in 0..<3 {
            for typeface in QuireFont.Typeface.allCases {
                QuireEnvironment.shared.setTypeface(typeface)
                let serif = typeface == .newYork
                for role in roles {
                    for unread in [false, true] {
                        XCTAssertEqual(isNewYork(QuireFont.font(role, unread: unread)), serif, "\(typeface) \(role)")
                    }
                    XCTAssertEqual(isNewYork(QuireFont.font(role, for: "Agenda")), serif, "\(typeface) \(role)")
                    let string = QuireFont.attributedString("Agenda", role: role, color: .qInk, unread: true)
                    XCTAssertEqual((string.attribute(.font, at: 0, effectiveRange: nil) as? NSFont).map(isNewYork), serif)
                    let offset = QuireFont.baselineOffset(role)
                    let expected = QuireFont.baselineOffset(for: QuireFont.font(role), lineHeight: role.lineHeight)
                    XCTAssertEqual(offset, expected, accuracy: 0.001, "\(typeface) \(role): the offset of the face set")
                }
                XCTAssertEqual(isNewYork(QuireFont.monogramFont(diameter: 30)), serif)
                XCTAssertEqual(isNewYork(QuireFont.monogramFont(size: 14)), serif)
            }
        }
    }

    func testFontsBuiltOffTheMainThreadFollowTheSwitch() {
        for typeface in [QuireFont.Typeface.sfPro, .newYork] {
            QuireEnvironment.shared.setTypeface(typeface)
            let done = expectation(description: "background fonts \(typeface)")
            done.expectedFulfillmentCount = 8
            let results = LockedResults()
            for i in 0..<8 {
                DispatchQueue.global().async {
                    let role = [QuireFont.Role.subject, .headline, .reading, .aside][i % 4]
                    let font = QuireFont.attributedString("Off main \(i)", role: role, color: .qInk)
                        .attribute(.font, at: 0, effectiveRange: nil) as? NSFont
                    results.append(font?.fontName ?? "")
                    done.fulfill()
                }
            }
            wait(for: [done], timeout: 10)
            XCTAssertEqual(results.all.count, 8)
            XCTAssertTrue(results.all.allSatisfy { $0.localizedCaseInsensitiveContains("NewYork") == (typeface == .newYork) },
                          "\(typeface): \(results.all)")
        }
    }
}

/// Font names collected from several queues.
private final class LockedResults: @unchecked Sendable {
    private var names: [String] = []
    private let lock = NSLock()

    func append(_ name: String) {
        lock.lock()
        names.append(name)
        lock.unlock()
    }

    var all: [String] {
        lock.lock()
        defer { lock.unlock() }
        return names
    }
}
