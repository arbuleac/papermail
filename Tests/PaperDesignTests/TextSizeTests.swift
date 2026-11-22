import AppKit
import XCTest
@testable import PaperDesign

/// Text size (spec §4.15): every role moves by the step, size and line height together, never below 11 pt; twins
/// keep sharing their role's line; monograms never move; fonts and paragraph styles are cached per size and never
/// handed to another; rows, skeleton rows and their marks follow the tables of §4.15; the environment carries the
/// size and announces a change once.
final class TextSizeTests: XCTestCase {
    private let sizes = QuireFont.TextSize.allCases

    override func tearDown() {
        QuireEnvironment.shared.setTextSize(.default)
        QuireTestEnvironment.reset()
        super.tearDown()
    }

    // MARK: The setting

    func testTheFourSizesNameTheirStepsInOrder() {
        XCTAssertEqual(sizes, [.small, .default, .large, .larger])
        XCTAssertEqual(sizes.map(\.delta), [-1, 0, 1, 2])
        XCTAssertEqual(sizes.map(\.delta), Quire.TextSize.deltas)
        XCTAssertEqual(sizes.map(\.title), ["Small", "Default", "Large", "Larger"])
        XCTAssertEqual(sizes.map(\.rawValue), ["small", "default", "large", "larger"], "the saved values never change")
        XCTAssertEqual(sizes.map(\.larger), [.default, .large, .larger, nil])
        XCTAssertEqual(sizes.map(\.smaller), [nil, .small, .default, .large])
    }

    // MARK: The step

    func testEveryRoleMovesByTheStepNeverBelowTheFloor() {
        for role in QuireFont.Role.allCases {
            for size in sizes {
                let step = role.step(at: size)
                if role.spec.size == 0 {
                    XCTAssertEqual(step, 0, "\(role): monograms follow the face's diameter")
                    continue
                }
                if role.spec.size + CGFloat(size.delta) < 11 {
                    XCTAssertEqual(step, 0, "\(role) at \(size): held at the 11 pt floor")
                } else {
                    XCTAssertEqual(step, CGFloat(size.delta), "\(role) at \(size)")
                }
                XCTAssertGreaterThanOrEqual(role.size(at: size), 11, "\(role) at \(size): no text below 11 pt")
                XCTAssertEqual(role.size(at: size), role.size + step)
                XCTAssertEqual(role.lineHeight(at: size), role.lineHeight + step, "\(role) at \(size): the leading stays")
                XCTAssertEqual(role.tracking, role.spec.tracking)
            }
            XCTAssertEqual(role.size(at: .default), role.size)
            XCTAssertEqual(role.lineHeight(at: .default), role.lineHeight)
        }
        XCTAssertEqual(QuireFont.Role.meta.size(at: .small), 11, "meta keeps 11 pt at Small")
        XCTAssertEqual(QuireFont.Role.meta.lineHeight(at: .small), 14)
        XCTAssertEqual(QuireFont.Role.snippet.size(at: .small), 11, "12 pt roles reach the floor")
        XCTAssertEqual(QuireFont.Role.reading.size(at: .larger), 17)
        XCTAssertEqual(QuireFont.Role.reading.lineHeight(at: .larger), 26)
    }

    func testTwinsAndVariantsKeepSharingTheirLineAtEverySize() {
        for role in QuireFont.Role.allCases {
            for size in sizes {
                if let twin = role.twin, role.spec.size > 0 {
                    XCTAssertEqual(twin.lineHeight(at: size), role.lineHeight(at: size), "\(role) and \(twin) at \(size)")
                }
                if let base = role.spec.variantOf {
                    XCTAssertEqual(role.size(at: size), base.size(at: size), "\(role) at \(size)")
                    XCTAssertEqual(role.lineHeight(at: size), base.lineHeight(at: size), "\(role) at \(size)")
                }
            }
        }
    }

    func testFontsAndStylesAreTheRolesAtTheSizeAndCachedPerSize() {
        for role in QuireFont.Role.allCases where role.spec.size > 0 {
            var seen: [NSFont] = []
            for size in sizes {
                let font = QuireFont.font(role, textSize: size)
                XCTAssertEqual(font.pointSize, role.size(at: size), "\(role) at \(size)")
                XCTAssertTrue(font === QuireFont.font(role, textSize: size), "\(role) at \(size): cached")
                if role.step(at: size) != 0 {
                    XCTAssertFalse(seen.contains { $0 === font }, "\(role) at \(size): never another size's font")
                }
                seen.append(font)
                let style = QuireFont.paragraphStyle(role, textSize: size)
                XCTAssertEqual(style.minimumLineHeight, role.lineHeight(at: size))
                XCTAssertEqual(style.maximumLineHeight, role.lineHeight(at: size))
                let natural = NSLayoutManager().defaultLineHeight(for: font)
                XCTAssertEqual(QuireFont.baselineOffset(role, textSize: size), (role.lineHeight(at: size) - natural) / 2, accuracy: 1e-9)
            }
            XCTAssertTrue(QuireFont.font(role) === QuireFont.font(role, textSize: .default), "\(role): Default unless asked")
        }
        let unread = QuireFont.font(.subject, unread: true, textSize: .larger)
        XCTAssertEqual(unread.pointSize, 16)
        XCTAssertEqual(QuireFont.fontWeight(600), .semibold)
        let attributes = QuireFont.attributes(.sender, color: .black, textSize: .large)
        XCTAssertEqual((attributes[.font] as? NSFont)?.pointSize, 14)
        XCTAssertEqual((attributes[.paragraphStyle] as? NSParagraphStyle)?.minimumLineHeight, 17)
    }

    /// The Font setting and Text size compose: a New York role under SF Pro is its twin at the size.
    func testTheTwinUnderSFProTakesTheSize() {
        QuireEnvironment.shared.setTypeface(.sfPro)
        defer { QuireEnvironment.shared.setTypeface(.newYork) }
        let font = QuireFont.font(.subject, textSize: .larger)
        XCTAssertFalse(font.fontName.localizedCaseInsensitiveContains("NewYork"))
        XCTAssertEqual(font.pointSize, QuireFont.Role.subjectSans.size(at: .larger))
        XCTAssertEqual(QuireFont.paragraphStyle(.subjectSans, textSize: .larger).minimumLineHeight, 20)
    }

    // MARK: Rows

    /// The tables of spec §4.15, and Default is `layout.row` / `layout.rowCompact` exactly.
    func testRowsFollowTheTables() {
        let standard: [(height: CGFloat, sender: CGFloat, senderH: CGFloat, subject: CGFloat, subjectH: CGFloat, snippet: CGFloat,
                        snippetH: CGFloat, avatar: CGFloat, pip: CGFloat, rule: CGFloat)] = [
            (64, 9, 15, 25, 17, 43, 14, 13, 12.5, 48),
            (68, 10, 16, 27, 18, 46, 15, 15, 14, 52),
            (72, 11, 17, 29, 19, 49, 16, 17, 15.5, 56),
            (76, 12, 18, 31, 20, 52, 17, 19, 17, 60),
        ]
        for (size, row) in zip(sizes, standard) {
            let m = QuireRowMetrics.standard(size)
            XCTAssertEqual(m.height, row.height, "\(size)")
            XCTAssertEqual(m.senderY, row.sender, "\(size)")
            XCTAssertEqual(m.senderHeight, row.senderH, "\(size)")
            XCTAssertEqual(m.subjectY, row.subject, "\(size)")
            XCTAssertEqual(m.subjectHeight, row.subjectH, "\(size)")
            XCTAssertEqual(m.snippetY, row.snippet, "\(size)")
            XCTAssertEqual(m.snippetHeight, row.snippetH, "\(size)")
            XCTAssertEqual(m.avatarBoxY, row.avatar, "\(size)")
            XCTAssertEqual(m.pipY, row.pip, "\(size)")
            XCTAssertEqual(m.marginRuleY, 8)
            XCTAssertEqual(m.marginRuleHeight, row.rule, "\(size)")
            XCTAssertEqual(m.textX, Quire.Layout.Row.textX)
            XCTAssertEqual(m.separatorX, Quire.Layout.Row.separatorX)
            XCTAssertFalse(m.isCompact)
        }
        let compact: [(height: CGFloat, sender: CGFloat, line2: CGFloat, pip: CGFloat, rule: CGFloat)] = [
            (44, 6, 23, 10, 32), (48, 7, 25, 11.5, 36), (52, 8, 27, 13, 40), (56, 9, 29, 14.5, 44),
        ]
        for (size, row) in zip(sizes, compact) {
            let m = QuireRowMetrics.compact(size)
            XCTAssertEqual(m.height, row.height, "\(size)")
            XCTAssertEqual(m.senderY, row.sender, "\(size)")
            XCTAssertEqual(m.subjectY, row.line2, "\(size)")
            XCTAssertEqual(m.pipY, row.pip, "\(size)")
            XCTAssertEqual(m.marginRuleY, 6)
            XCTAssertEqual(m.marginRuleHeight, row.rule, "\(size)")
            XCTAssertEqual(m.textX, Quire.Layout.RowCompact.textX)
            XCTAssertTrue(m.isCompact)
        }
        XCTAssertEqual(sizes.map { Int(QuireRowMetrics.standard($0).height) }, Quire.TextSize.rowHeights)
        XCTAssertEqual(sizes.map { Int(QuireRowMetrics.compact($0).height) }, Quire.TextSize.rowCompactHeights)

        let row = Quire.Layout.Row.self
        let m = QuireRowMetrics.standard(.default)
        XCTAssertEqual([m.height, m.marginRuleY, m.marginRuleHeight, m.pipY, m.avatarBoxY, m.senderY, m.senderHeight, m.subjectY,
                        m.subjectHeight, m.snippetY, m.snippetHeight],
                       [row.height, row.marginRuleY, row.marginRuleHeight, row.pipY, row.avatarBoxY, row.senderY, row.senderHeight,
                        row.subjectY, row.subjectHeight, row.snippetY, row.snippetHeight])
        let c = QuireRowMetrics.compact(.default)
        let compactRow = Quire.Layout.RowCompact.self
        XCTAssertEqual([c.height, c.marginRuleY, c.marginRuleHeight, c.pipY, c.senderY, c.subjectY],
                       [compactRow.height, compactRow.marginRuleY, compactRow.marginRuleHeight, compactRow.pipY, compactRow.senderY,
                        compactRow.line2Y])
    }

    /// The marks keep their sizes and stay centred: the face in the row, the pip on the sender line (half a point
    /// above its centre, as at Default), the margin rule's inset on both ends.
    func testTheMarksStayCentredOnWhatTheyMark() {
        let row = Quire.Layout.Row.self
        for size in sizes {
            let m = QuireRowMetrics.standard(size)
            XCTAssertEqual(m.avatarBoxY * 2 + row.avatarBox, m.height, "\(size): the face is centred")
            XCTAssertEqual(m.pipY + row.pip / 2, m.senderY + m.senderHeight / 2 - 0.5, "\(size): the pip on the sender line")
            XCTAssertEqual(m.marginRuleY * 2 + m.marginRuleHeight, m.height, "\(size)")
            let c = QuireRowMetrics.compact(size)
            XCTAssertEqual(c.pipY + row.pip / 2, c.senderY + c.senderHeight / 2, "\(size): the compact pip on the sender line")
            XCTAssertEqual(c.marginRuleY * 2 + c.marginRuleHeight, c.height, "\(size)")
            XCTAssertEqual(c.height - (c.subjectY + c.subjectHeight), c.senderY - 2, "\(size): a compact row's pads move together")
        }
    }

    /// Skeleton rows take the row's height; their bars stay centred on the lines they stand for, at their own sizes,
    /// and the circle on the row.
    @MainActor
    func testSkeletonRowsFollowTheirRows() {
        let rect = NSRect(x: 0, y: 0, width: 360, height: 100)
        let atDefault = QuireSkeleton.shapes(.row(index: 2), in: rect)
        let compactAtDefault = QuireSkeleton.shapes(.compactRow(index: 2), in: rect)
        for size in sizes {
            let m = QuireRowMetrics.standard(size)
            XCTAssertEqual(QuireSkeleton.height(of: .row(index: 0), textSize: size), m.height)
            XCTAssertEqual(QuireSkeleton.height(of: .compactRow(index: 0), textSize: size), QuireRowMetrics.compact(size).height)
            let shapes = QuireSkeleton.shapes(.row(index: 2), in: rect, textSize: size)
            XCTAssertEqual(shapes.count, atDefault.count)
            XCTAssertEqual(shapes[0].rect.midY, m.height / 2, "\(size): the circle is centred on the row")
            let lineCentres = [m.senderY + m.senderHeight / 2, m.senderY + m.senderHeight / 2, m.subjectY + m.subjectHeight / 2,
                               m.snippetY + m.snippetHeight / 2]
            let defaultCentres = [18.0, 18.0, 36.0, 53.5] as [CGFloat]
            for (index, shape) in shapes.dropFirst().enumerated() {
                let base = atDefault[index + 1].rect
                XCTAssertEqual(shape.rect.size, base.size, "\(size): bar \(index) keeps its size")
                XCTAssertEqual(shape.rect.midY - lineCentres[index], base.midY - defaultCentres[index], accuracy: 0.001,
                               "\(size): bar \(index) keeps its place on its line")
            }
            let compact = QuireSkeleton.shapes(.compactRow(index: 2), in: rect, textSize: size)
            let c = QuireRowMetrics.compact(size)
            XCTAssertEqual(compact[0].rect.midY - (c.senderY + c.senderHeight / 2), compactAtDefault[0].rect.midY - 15, accuracy: 0.001)
            XCTAssertEqual(compact[2].rect.midY - (c.subjectY + c.subjectHeight / 2), compactAtDefault[2].rect.midY - 34, accuracy: 0.001)
        }
        let view = QuireSkeleton(.row(index: 0))
        view.textSize = .larger
        XCTAssertEqual(view.intrinsicContentSize.height, 76)
    }

    // MARK: The environment

    func testTheEnvironmentCarriesTheSizeAndAnnouncesItOnce() {
        let environment = QuireEnvironment.shared
        environment.setTextSize(.default)
        let before = QuireEnvironment.cacheKey(for: NSAppearance(named: .aqua)!)
        var posts = 0
        let token = NotificationCenter.default.addObserver(forName: QuireEnvironment.didChangeNotification, object: nil, queue: nil) { _ in
            posts += 1
        }
        defer { NotificationCenter.default.removeObserver(token) }
        environment.setTextSize(.larger)
        environment.setTextSize(.larger)
        XCTAssertEqual(posts, 1, "a change is announced once; setting it again is none")
        XCTAssertEqual(QuireEnvironment.textSize, .larger)
        XCTAssertEqual(QuireEnvironment.cacheKey(for: NSAppearance(named: .aqua)!), before,
                       "faces never draw again for a size; the surfaces that ask for one key on it themselves")
        environment.refresh()
        XCTAssertEqual(QuireEnvironment.textSize, .larger, "re-reading the system settings keeps the app's size")
        environment.setOverrides(.init(textSize: .small))
        XCTAssertEqual(QuireEnvironment.textSize, .small, "an override wins")
        environment.setOverrides(.init())
        XCTAssertEqual(QuireEnvironment.textSize, .larger)
        environment.setTextSize(.default)
        XCTAssertEqual(QuireEnvironment.cacheKey(for: NSAppearance(named: .aqua)!), before)
    }

    /// Fonts at every size, built from other threads while the size changes, are always the size asked for.
    func testFontsBuiltOffTheMainThreadAreTheSizeAskedFor() {
        let group = DispatchGroup()
        let failures = LockedCache<Int, Bool>()
        for index in 0..<64 {
            group.enter()
            DispatchQueue.global().async {
                let size = QuireFont.TextSize.allCases[index % 4]
                let role = QuireFont.Role.allCases.filter { $0.spec.size > 0 }[index % 20]
                if QuireFont.font(role, textSize: size).pointSize != role.size(at: size) { _ = failures.value(for: index) { true } }
                group.leave()
            }
        }
        QuireEnvironment.shared.setTextSize(.large)
        XCTAssertEqual(group.wait(timeout: .now() + 10), .success)
        XCTAssertEqual(failures.count, 0)
    }
}
