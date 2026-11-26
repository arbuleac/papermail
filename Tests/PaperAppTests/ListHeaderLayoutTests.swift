import AppKit
import PaperCore
import PaperDesign
import XCTest
@testable import PaperApp

/// The list header is one 52 pt line (spec §5.3, §5.6): the masthead, the search field and compose share the
/// traffic lights' centre line; the search field takes the free width and keeps its minimum while the narrowed
/// address truncates; the masthead is the title menu only in minimal mode.
@MainActor
final class ListHeaderLayoutTests: XCTestCase {
    private let h = Quire.Layout.ListHeader.self

    /// A control's visual rect in the header's coordinates.
    private func visual(_ control: QuireControl, in header: ListHeaderView) -> NSRect {
        control.superview?.convert(control.alignmentRect(forFrame: control.frame), to: header) ?? .zero
    }

    private func header(_ harness: MainWindowHarness) -> ListHeaderView {
        let header = harness.controller.listPane.header
        header.superview?.layoutSubtreeIfNeeded()
        header.layoutSubtreeIfNeeded()
        return header
    }

    func testOneRowOnTheTrafficLightsLine() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let header = header(harness)
        XCTAssertEqual(header.frame.height, 52)
        XCTAssertEqual(Quire.Layout.ListHeader.height, Quire.Layout.Window.titlebarZone, "the header is the title-bar zone")
        XCTAssertEqual(harness.list.view.frame.minY, 52, "the list starts under the one row")
        let masthead = visual(header.masthead, in: header)
        let search = visual(header.search, in: header)
        let compose = visual(header.compose, in: header)
        for (name, rect) in [("masthead", masthead), ("search", search), ("compose", compose)] {
            XCTAssertEqual(rect.midY, 26, accuracy: 0.5, "\(name) on y = 26")
        }
        XCTAssertEqual(search.height, 26)
        XCTAssertEqual(compose.size, NSSize(width: 28, height: 28))
        XCTAssertEqual(compose.maxX, header.bounds.width - 12, accuracy: 0.5)
        // Search runs from the masthead (+ 12) to compose (− 8).
        XCTAssertEqual(search.minX, masthead.maxX - h.mastheadHitPad + h.searchGap, accuracy: 0.5)
        XCTAssertEqual(search.maxX, compose.minX - h.searchComposeGap, accuracy: 0.5)
        XCTAssertGreaterThanOrEqual(search.width, h.searchMinWidth)
        XCTAssertEqual(masthead.minX + h.mastheadHitPad, 16, "the masthead text starts at 16 beside the rail")
    }

    func testTheAddressTruncatesFirstSoSearchKeepsItsMinimum() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let header = header(harness)
        header.address = "a"
        header.layoutSubtreeIfNeeded()
        XCTAssertEqual(header.addressWidths.shown, header.addressWidths.natural, "a short address shows whole")
        XCTAssertGreaterThan(visual(header.search, in: header).width, h.searchMinWidth)

        header.address = "alexandra.morgan-whitfield@consolidated-holdings.example.test"
        header.layoutSubtreeIfNeeded()
        let search = visual(header.search, in: header)
        XCTAssertEqual(search.width, h.searchMinWidth, accuracy: 0.5, "the field keeps its 140 pt")
        XCTAssertGreaterThan(header.addressWidths.shown, 0)
        XCTAssertLessThan(header.addressWidths.shown, header.addressWidths.natural, "the address gives way")
        let masthead = visual(header.masthead, in: header)
        XCTAssertEqual(masthead.width, header.masthead.intrinsicContentSize.width, "the masthead never truncates")
        XCTAssertEqual(search.maxX, visual(header.compose, in: header).minX - h.searchComposeGap, accuracy: 0.5)

        // With less than 40 pt of it left the address drops out whole and the field takes the room.
        header.setFrameSize(NSSize(width: 300, height: 52))
        header.layoutSubtreeIfNeeded()
        XCTAssertEqual(header.addressWidths.shown, 0)
        let wide = visual(header.search, in: header)
        XCTAssertEqual(wide.minX, masthead.maxX - h.mastheadHitPad + h.searchGap, accuracy: 0.5)
        XCTAssertGreaterThan(wide.width, h.searchMinWidth)
        header.address = nil
    }

    /// The Demo tag steps off the line before the field goes below its minimum, and the address, which gives way
    /// first, stays off with it: minimal mode, the dot and the Demo tag on the default list width.
    func testTheDemoTagStepsOffBeforeTheFieldGoesBelowItsMinimum() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let header = header(harness)
        header.showsDemoTag = true
        header.layoutSubtreeIfNeeded()
        XCTAssertFalse(header.demoTag.isHidden, "beside the rail the tag fits")
        let tag = visual(header.demoTag, in: header)
        XCTAssertEqual(visual(header.search, in: header).minX, tag.maxX + h.searchGap, accuracy: 0.5)

        header.mastheadX = h.mastheadMinimalX26
        header.masthead.isMenu = true
        header.showsNewMailDot = true
        header.address = "alex@contoso.test"
        header.accountName = "Contoso"
        header.setFrameSize(NSSize(width: Quire.Layout.List.defaultWidth, height: 52))
        header.layoutSubtreeIfNeeded()
        XCTAssertTrue(header.demoTag.isHidden, "the tag steps off the line whole")
        XCTAssertFalse(harness.controller.listPane.keyViews.contains { $0 === header.demoTag }, "and out of the Tab order")
        XCTAssertEqual(header.addressWidths.shown, 0, "the address stays off while the tag is")
        let search = visual(header.search, in: header)
        let dotEnd = visual(header.masthead, in: header).maxX - h.mastheadHitPad + h.minimalDotGap + h.minimalDotSize
        XCTAssertEqual(search.minX, dotEnd + h.searchGap, accuracy: 0.5, "the field starts after the dot")
        XCTAssertLessThan(search.width, h.searchMinWidth, "only the masthead and the dot hold it below its minimum")
        // The placeholder names the account instead, whole: “Search Contoso” where it fits, else the name alone.
        XCTAssertEqual(header.search.placeholder, header.search.fitsPlaceholder("Search Contoso") ? "Search Contoso" : "Contoso")
        header.accountName = "Demo Gmail"
        header.layoutSubtreeIfNeeded()
        XCTAssertFalse(header.search.fitsPlaceholder("Search Demo Gmail"))
        XCTAssertEqual(header.search.placeholder, "Demo Gmail", "a cut “Search Demo…” would not tell the demo accounts apart")
        XCTAssertEqual(header.search.textField.accessibilityLabel(), "Demo Gmail")
        XCTAssertFalse(header.search.showsKeycap, "having given up its “Search”, the field does not show the hint instead")

        // A wider list has room for the tag again.
        header.setFrameSize(NSSize(width: Quire.Layout.List.maxWidth, height: 52))
        header.layoutSubtreeIfNeeded()
        XCTAssertFalse(header.demoTag.isHidden)
        XCTAssertGreaterThanOrEqual(visual(header.search, in: header).width, h.searchMinWidth)
    }

    /// Every view name, beside the rail and in minimal mode (both masthead positions), with and without the dot, the
    /// Demo tag and an address, at the list's minimum, default and maximum width: the field never starts before the
    /// cluster ends, keeps at least its own height, and goes below its minimum only when nothing but the masthead,
    /// its chevron and the dot are left on the line.
    /// Focused, the field widens over the cluster to where the masthead text starts and the cluster fades under it, so a
    /// long query has room; compose and the field's height stay, and focus leaving gives the cluster back (§5.6).
    func testTheFocusedFieldWidensOverTheClusterAndGivesItBack() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let header = header(harness)
        let window = try XCTUnwrap(header.window)
        header.showsDemoTag = true
        header.address = "alex@contoso.test"
        header.accountName = "Contoso"
        header.layoutSubtreeIfNeeded()
        let rest = visual(header.search, in: header)
        let compose = visual(header.compose, in: header)
        let masthead = visual(header.masthead, in: header)
        XCTAssertGreaterThan(rest.minX, masthead.maxX, "at rest the field sits after the cluster")

        XCTAssertTrue(window.makeFirstResponder(header.search.textField))
        // The frame glides there (AppKit steps an animated view frame to its end), so let the glide run its course.
        ListTestSupport.spin(for: Quire.Motion.standard + 0.3)
        XCTAssertTrue(header.isSearchExpanded)
        let focused = visual(header.search, in: header)
        XCTAssertEqual(focused.minX, header.mastheadX, accuracy: 0.5, "it starts where the masthead text starts")
        XCTAssertEqual(focused.maxX, rest.maxX, accuracy: 0.5, "it still ends before compose")
        XCTAssertEqual(focused.height, rest.height)
        XCTAssertEqual(visual(header.compose, in: header), compose, "compose does not move")
        XCTAssertEqual(header.masthead.alphaValue, 0, "the masthead fades under it")
        XCTAssertEqual(header.demoTag.alphaValue, 0, "so does the Demo tag")
        XCTAssertEqual(header.search.placeholder, "Search Contoso", "with the address covered, the placeholder names the account")

        XCTAssertTrue(window.makeFirstResponder(harness.list.tableView))
        ListTestSupport.spin(for: Quire.Motion.standard + 0.3)
        XCTAssertFalse(header.isSearchExpanded)
        XCTAssertEqual(visual(header.search, in: header), rest, "focus leaving gives the cluster back")
        XCTAssertEqual(header.masthead.alphaValue, 1)
        XCTAssertEqual(header.demoTag.alphaValue, 1)
    }

    /// The usual narrowed state: the address on the line and “Search Inbox” at rest. Widening covers the address, so
    /// the placeholder names the account while the field edits, which AppKit applies by restarting the editing
    /// session. That restart is no focus change: read as one, the field stayed wide after the keyboard had gone.
    func testANarrowedFieldGivesTheClusterBackWhenFocusLeaves() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let header = header(harness)
        let window = try XCTUnwrap(header.window)
        header.address = "alex@contoso.test"
        header.accountName = "Contoso"
        header.searchPlaceholder = "Search Inbox"
        header.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(header.addressWidths.shown, 0, "the address shows at rest")
        XCTAssertEqual(header.search.placeholder, "Search Inbox")
        let rest = visual(header.search, in: header)

        XCTAssertTrue(window.makeFirstResponder(header.search.textField))
        ListTestSupport.spin(for: Quire.Motion.standard + 0.3)
        XCTAssertEqual(header.search.placeholder, "Search Contoso")
        XCTAssertTrue(header.search.hasKeyboardFocus)
        XCTAssertTrue(header.isSearchExpanded, "the new placeholder is no focus change")
        XCTAssertTrue(harness.list.searchFieldHasFocus, "so the list still shows the offer's ↩")
        XCTAssertTrue(header.masthead.isHidden, "faded, the masthead takes no click, Tab stop or VoiceOver focus")
        XCTAssertFalse(harness.controller.listPane.keyViews.contains { $0 === header.masthead })

        // A scope change while the field edits changes the placeholder again.
        header.address = "sam@fabrikam.test"
        header.accountName = "Fabrikam"
        header.layoutSubtreeIfNeeded()
        XCTAssertEqual(header.search.placeholder, "Search Fabrikam")
        XCTAssertTrue(header.isSearchExpanded)
        XCTAssertTrue(harness.list.searchFieldHasFocus)

        XCTAssertTrue(window.makeFirstResponder(harness.list.tableView))
        ListTestSupport.spin(for: Quire.Motion.standard + 0.3)
        XCTAssertFalse(header.isSearchExpanded)
        XCTAssertFalse(harness.list.searchFieldHasFocus)
        XCTAssertEqual(visual(header.search, in: header).maxX, rest.maxX, accuracy: 0.5)
        XCTAssertGreaterThan(visual(header.search, in: header).minX, visual(header.masthead, in: header).maxX,
                             "focus leaving gives the cluster back")
        XCTAssertFalse(header.masthead.isHidden)
        XCTAssertEqual(header.masthead.alphaValue, 1)
        XCTAssertEqual(header.search.placeholder, "Search Inbox", "with the address back on the line")
    }

    /// Under Reduce Motion the width snaps at once and only the cluster cross-fades (§4.10).
    func testUnderReduceMotionTheWidthSnapsAndTheClusterCrossFades() throws {
        let environment = QuireEnvironment.shared
        let saved = environment.overrides
        defer { environment.setOverrides(saved) }
        var overrides = saved
        overrides.reduceMotion = true
        environment.setOverrides(overrides)
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let header = header(harness)
        let window = try XCTUnwrap(header.window)
        header.layoutSubtreeIfNeeded()
        let rest = visual(header.search, in: header)

        XCTAssertTrue(window.makeFirstResponder(header.search.textField))
        XCTAssertEqual(visual(header.search, in: header).minX, header.mastheadX, accuracy: 0.5, "no glide: it is there at once")
        ListTestSupport.spin(for: Quire.Motion.reducedFade + 0.3)
        XCTAssertEqual(header.masthead.alphaValue, 0)
        XCTAssertTrue(header.masthead.isHidden)

        XCTAssertTrue(window.makeFirstResponder(harness.list.tableView))
        XCTAssertEqual(visual(header.search, in: header), rest, "and back at once")
        XCTAssertFalse(header.masthead.isHidden, "the masthead is back before it fades in")
        ListTestSupport.spin(for: Quire.Motion.reducedFade + 0.3)
        XCTAssertEqual(header.masthead.alphaValue, 1)
    }

    /// Whether “Search <account>” fits is measured at the width the field glides to, not the frame it is leaving:
    /// focused it names the account in full where that fits, and back at rest it reads as it did, never cut.
    func testThePlaceholderIsMeasuredAtTheWidthTheFieldGlidesTo() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let header = header(harness)
        let window = try XCTUnwrap(header.window)
        header.showsDemoTag = true
        header.address = "alex@contoso.test"
        header.accountName = "Contoso Holdings Group"
        header.layoutSubtreeIfNeeded()
        let restPlaceholder = header.search.placeholder
        XCTAssertEqual(header.search.fitsPlaceholder("Search Contoso Holdings Group"), restPlaceholder == "Search Contoso Holdings Group")

        XCTAssertTrue(window.makeFirstResponder(header.search.textField))
        ListTestSupport.spin(for: Quire.Motion.standard + 0.3)
        XCTAssertTrue(header.search.fitsPlaceholder("Search Contoso Holdings Group"), "the widened field has room for it")
        XCTAssertEqual(header.search.placeholder, "Search Contoso Holdings Group")

        XCTAssertTrue(window.makeFirstResponder(harness.list.tableView))
        ListTestSupport.spin(for: Quire.Motion.standard + 0.3)
        XCTAssertEqual(header.search.placeholder, restPlaceholder, "back at rest it reads as it did")
    }

    func testTheFieldNeverCoversTheCluster() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let header = header(harness)
        let widths = [Quire.Layout.List.minWidth, Quire.Layout.List.defaultWidth, Quire.Layout.List.maxWidth]
        for (x, isMenu) in [(h.mastheadX, false), (h.mastheadMinimalX, true), (h.mastheadMinimalX26, true)] {
            for width in widths {
                for dot in isMenu ? [false, true] : [false] {
                    for demo in [false, true] {
                        for address in [nil, "alexandra.morgan@consolidated-holdings.example.test"] {
                            for entry in TitleMenu.entries {
                                header.mastheadX = x
                                header.masthead.isMenu = isMenu
                                header.showsNewMailDot = dot
                                header.showsDemoTag = demo
                                header.address = address
                                header.accountName = address == nil ? nil : "Consolidated Holdings"
                                header.masthead.title = entry.title
                                header.setFrameSize(NSSize(width: width, height: 52))
                                header.layoutSubtreeIfNeeded()
                                let line = "\(entry.title) x \(x) width \(width) dot \(dot) demo \(demo) address \(address != nil)"
                                let search = visual(header.search, in: header)
                                let compose = visual(header.compose, in: header)
                                var clusterEnd = visual(header.masthead, in: header).maxX - h.mastheadHitPad
                                if dot { clusterEnd += h.minimalDotGap + h.minimalDotSize }
                                let tagWidth = header.demoTag.intrinsicContentSize.width
                                let tagShown = !header.demoTag.isHidden
                                XCTAssertEqual(tagShown && !demo, false, line)
                                if tagShown {
                                    let tag = visual(header.demoTag, in: header)
                                    XCTAssertEqual(tag.minX, clusterEnd + h.demoTagGap, accuracy: 0.5, line)
                                    clusterEnd = tag.maxX
                                }
                                if header.addressWidths.shown > 0 { clusterEnd += h.addressGap + header.addressWidths.shown }
                                XCTAssertGreaterThanOrEqual(search.minX, clusterEnd + h.searchGap - 0.5, "never under the cluster: \(line)")
                                XCTAssertEqual(search.maxX, compose.minX - h.searchComposeGap, accuracy: 0.5, line)
                                XCTAssertGreaterThanOrEqual(search.width, h.searchHeight, line)
                                if tagShown || header.addressWidths.shown > 0 {
                                    XCTAssertGreaterThanOrEqual(search.width, h.searchMinWidth - 0.5, "kept beside the tag or address: \(line)")
                                }
                                if demo && !tagShown {
                                    let withTag = search.maxX - (clusterEnd + h.demoTagGap + tagWidth + h.searchGap)
                                    XCTAssertLessThan(withTag, h.searchMinWidth, "the tag steps off only to keep the minimum: \(line)")
                                    XCTAssertEqual(header.addressWidths.shown, 0, "the address gives way first: \(line)")
                                }
                                if address != nil && header.addressWidths.shown == 0 {
                                    let scoped = "Search Consolidated Holdings"
                                    let expected = header.search.fitsPlaceholder(scoped) ? scoped : "Consolidated Holdings"
                                    XCTAssertEqual(header.search.placeholder, expected, "the account is named: \(line)")
                                    if expected != scoped { XCTAssertFalse(header.search.showsKeycap, line) }
                                } else {
                                    XCTAssertEqual(header.search.placeholder, header.searchPlaceholder, line)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    /// Narrowed through the rail: beside it the address shows and the placeholder is the view's; in minimal mode the
    /// address has no room at the default width, so the placeholder names the account.
    func testTheNarrowedAccountStaysOnScreen() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let controller = harness.controller
        let tile = try XCTUnwrap(controller.strip.tile(for: .account(ListTestSupport.accountA.id)))
        tile.performClick(nil)
        harness.spin { controller.listPane.header.address != nil }
        let header = header(harness)
        XCTAssertEqual(header.bounds.width, Quire.Layout.List.defaultWidth, accuracy: 1, "the default list width")
        XCTAssertEqual(header.address, "alex@contoso.test")
        XCTAssertGreaterThan(header.addressWidths.shown, 0, "beside the rail the address shows")
        XCTAssertEqual(header.search.placeholder, "Search Inbox")

        controller.toggleAccountStrip(nil)
        header.layoutSubtreeIfNeeded()
        XCTAssertEqual(header.addressWidths.shown, 0)
        XCTAssertEqual(header.search.placeholder, "Search Contoso", "the account is still named on the line")
        XCTAssertEqual(header.search.textField.accessibilityLabel(), "Search Contoso")
        _ = controller.perform(.goTo(.starred))
        header.layoutSubtreeIfNeeded()
        XCTAssertTrue(["Search Contoso", "Contoso"].contains(header.search.placeholder), "in every view: \(header.search.placeholder)")

        controller.toggleAccountStrip(nil)
        header.layoutSubtreeIfNeeded()
        XCTAssertEqual(header.search.placeholder, "Search Starred", "the address is back, and the view's placeholder with it")
        controller.strip.tile(for: .unified)?.performClick(nil)
        header.layoutSubtreeIfNeeded()
        XCTAssertNil(header.accountName)
        XCTAssertEqual(header.search.placeholder, "Search Starred")
    }

    func testBesideTheRailTheMastheadIsAPlainTitle() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let header = header(harness)
        let masthead = header.masthead
        XCTAssertFalse(masthead.isMenu)
        XCTAssertNil(masthead.hitTest(NSPoint(x: masthead.frame.midX, y: masthead.frame.midY)), "a click drags the window")
        XCTAssertFalse(masthead.canBecomeKeyView)
        XCTAssertFalse(harness.controller.listPane.keyViews.contains { $0 === masthead }, "no Tab stop")
        XCTAssertEqual(masthead.accessibilityRole(), NSAccessibility.Role(rawValue: "AXHeading"))
        XCTAssertEqual(masthead.accessibilityLabel(), "Inbox")
        let plainWidth = masthead.intrinsicContentSize.width
        masthead.isMenu = true
        XCTAssertGreaterThan(masthead.intrinsicContentSize.width, plainWidth, "only the menu carries the chevron")
        masthead.isMenu = false
    }

    func testMinimalModeKeepsTheTitleMenuWithTheFoldersAndAccounts() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let controller = harness.controller
        controller.toggleAccountStrip(nil)
        let header = header(harness)
        XCTAssertTrue(header.masthead.isMenu)
        // Past the lights, where it stood while the rail was only as wide as they needed: the rail's width, wider since
        // its tiles took the lights' centre, does not move it.
        let chrome = QuireWindowChrome.metrics(of: try XCTUnwrap(controller.window))
        XCTAssertEqual(header.mastheadX, chrome.mastheadMinimalX)
        XCTAssertEqual(header.mastheadX, chrome.lightsClearX + h.mastheadMinimalGap)
        XCTAssertLessThan(header.mastheadX, controller.strip.railWidth, "not the rail's width")
        XCTAssertTrue(controller.listPane.keyViews.first === header.masthead, "the title menu is a Tab stop again")
        XCTAssertEqual(header.masthead.accessibilityRole(), .menuButton)
        // Search and compose keep the line.
        XCTAssertEqual(visual(header.search, in: header).midY, 26, accuracy: 0.5)
        XCTAssertEqual(visual(header.compose, in: header).maxX, header.bounds.width - 12, accuracy: 0.5)

        let model = try XCTUnwrap(controller.listPane.titleMenuModel?())
        XCTAssertTrue(model.showsAccounts)
        let action = #selector(NSResponder.noResponder(for:))
        let menu = TitleMenu.build(model, target: self, viewAction: action, scopeAction: action)
        // View items carry their G-sequence after a tab.
        let titles = menu.items.filter { !$0.isSeparatorItem }.map { $0.title.components(separatedBy: "\t")[0] }
        XCTAssertEqual(Array(titles.prefix(6)), ["Inbox", "Starred", "Sent", "Drafts", "Trash", "All Mail"])
        XCTAssertEqual(titles[6], "All Inboxes")
        XCTAssertEqual(titles.count, 6 + 1 + 2, "the views, All Inboxes and both accounts")

        controller.toggleAccountStrip(nil)
        XCTAssertFalse(header.masthead.isMenu, "the rail is back: a plain title again")
        XCTAssertEqual(header.mastheadX, 16)
    }
}
