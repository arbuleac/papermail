import AppKit
import PaperCore
@testable import PaperDesign
import XCTest
@testable import PaperApp

/// The rail's two states (spec §3.2, §5.2): its tiles alone, in a column under the traffic lights, or each tile as a row
/// with its name beside it. A row is in its tile's place, so nothing moves up or down between the two; View › Show Names
/// in Rail and a drag of the rail's edge switch between them, in one frame, and the window keeps the choice.
@MainActor
final class RailNamesTests: XCTestCase {
    private var pasteboards: [NSPasteboard] = []
    private var themeBefore = QuireEnvironment.theme
    private var overridesBefore = QuireEnvironment.shared.overrides
    private var textSizeBefore = QuireEnvironment.textSize

    override func setUp() {
        super.setUp()
        MainActor.assumeIsolated {
            // The drag's tracking loop reads NSApp's queue, which a test run that starts here has not made yet.
            _ = NSApplication.shared
            themeBefore = QuireEnvironment.theme
            overridesBefore = QuireEnvironment.shared.overrides
            textSizeBefore = QuireEnvironment.textSize
        }
    }

    override func tearDown() {
        MainActor.assumeIsolated {
            for pasteboard in pasteboards { pasteboard.releaseGlobally() }
            pasteboards = []
            QuireEnvironment.shared.setTheme(themeBefore)
            QuireEnvironment.shared.setOverrides(overridesBefore)
            QuireEnvironment.shared.setTextSize(textSizeBefore)
            // The split's autosave writes the test process's own defaults: forgotten, so later windows open as before.
            UserDefaults.standard.removeObject(forKey: "NSSplitView Subview Frames MainSplit")
        }
        super.tearDown()
    }

    // MARK: Helpers

    private let r = Quire.Layout.Rail.self

    private func layOut(_ harness: MainWindowHarness) -> AccountStripViewController {
        harness.controller.splitView.layoutSubtreeIfNeeded()
        let strip = harness.controller.strip
        strip.view.layoutSubtreeIfNeeded()
        return strip
    }

    private func showNames(_ shows: Bool, in harness: MainWindowHarness) -> AccountStripViewController {
        harness.controller.setRailNames(shows)
        return layOut(harness)
    }

    /// Every tile the rail shows, top to bottom: the folders, All Inboxes, the accounts and the pending tile.
    private func tiles(_ strip: AccountStripViewController) -> [AccountStripButton] {
        CursorRectRecorder.descendants(of: strip.view, as: AccountStripButton.self).filter { !$0.isHidden }
            .sorted { $0.convert($0.tileRect, to: strip.view).minY < $1.convert($1.tileRect, to: strip.view).minY }
    }

    private func utilities(_ strip: AccountStripViewController) throws -> (add: RailUtilityButton, settings: RailUtilityButton) {
        (try XCTUnwrap(strip.keyViews[2] as? RailUtilityButton), try XCTUnwrap(strip.keyViews[3] as? RailUtilityButton))
    }

    /// A utility's visual rect in rail coordinates.
    private func visual(_ button: RailUtilityButton, in strip: AccountStripViewController) throws -> NSRect {
        try XCTUnwrap(button.superview).convert(button.alignmentRect(forFrame: button.frame), to: strip.view)
    }

    /// The top edge of everything in the rail, in rail coordinates: what must not move between the two states.
    private func tops(_ strip: AccountStripViewController) throws -> [CGFloat] {
        let (add, settings) = try utilities(strip)
        return tiles(strip).map { $0.convert($0.tileRect, to: strip.view).minY } + strip.dividerRects.map(\.minY)
            + [try visual(add, in: strip).minY, try visual(settings, in: strip).minY]
    }

    private func addAccounts(_ count: Int, to harness: MainWindowHarness) throws {
        for n in 1...count {
            try harness.environment.store.upsertAccount(Account(id: AccountID("acct-extra-\(n)"), kind: .gmail, email: "alex@extra\(n).test",
                                                                displayName: "Alex Morgan", addedAt: Date(timeIntervalSince1970: Double(10 + n)),
                                                                inkSlot: 1 + n))
        }
        harness.controller.refreshAccounts()
    }

    /// The rail as drawn, tiles and all, in `appearance`; pixels are read in rail coordinates.
    private func render(_ strip: AccountStripViewController, appearance: NSAppearance.Name = .aqua) throws -> (NSPoint) -> NSColor? {
        let view = strip.view
        view.appearance = NSAppearance(named: appearance)
        view.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / view.bounds.width
        return { point in rep.colorAt(x: Int(point.x * scale), y: Int(point.y * scale))?.usingColorSpace(.sRGB) }
    }

    /// WCAG relative luminance.
    private func luminance(_ color: NSColor) -> CGFloat {
        func linear(_ c: CGFloat) -> CGFloat { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(color.redComponent) + 0.7152 * linear(color.greenComponent) + 0.0722 * linear(color.blueComponent)
    }

    private func contrast(_ a: NSColor, _ b: NSColor) -> CGFloat {
        let (la, lb) = (luminance(a), luminance(b))
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    /// The strongest contrast any pixel of `rect` (rail coordinates) has against `ground`: a line of text's ink.
    private func strongestContrast(in rect: NSRect, against ground: NSColor, pixel: (NSPoint) -> NSColor?) -> CGFloat {
        var strongest: CGFloat = 1
        for y in stride(from: rect.minY + 0.5, to: rect.maxY, by: 1) {
            for x in stride(from: rect.minX + 0.5, to: rect.maxX, by: 1) {
                if let color = pixel(NSPoint(x: x, y: y)) { strongest = max(strongest, contrast(color, ground)) }
            }
        }
        return strongest
    }

    private func mouse(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                         windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }

    /// Presses the rail's edge, drags through `offsets` (points from the press, towards the list) and lets go at the
    /// last; returns the states the split asked for on the way. The split's tracking loop reads the drag from the
    /// queue, so the drag is posted before the press that runs the loop.
    @discardableResult
    private func dragEdge(of harness: MainWindowHarness, through offsets: [CGFloat]) throws -> [Bool] {
        let window = try XCTUnwrap(harness.controller.window)
        let split = try XCTUnwrap(harness.controller.splitView as? HairlineSplitView)
        split.layoutSubtreeIfNeeded()
        let grab = try XCTUnwrap(split.railEdgeGrabRect, "the rail has an edge to press")
        let press = split.convert(NSPoint(x: grab.midX, y: grab.midY), to: nil)
        var asked: [Bool] = []
        let forward = split.onRailEdgeDrag
        split.onRailEdgeDrag = { showsNames in
            asked.append(showsNames)
            forward?(showsNames)
        }
        defer { split.onRailEdgeDrag = forward }
        // The drag goes behind whatever the queue holds. In the whole suite that is hundreds of AppKit events no test
        // pumps (the window server's, fetched by the first tracking loop), and drags queued behind them were dropped
        // while the release still arrived, so a there-and-back drag read as no drag. They go first: only this drag is
        // queued.
        while NSApp.nextEvent(matching: .any, until: nil, inMode: .default, dequeue: true) != nil {}
        for offset in offsets {
            NSApp.postEvent(try mouse(.leftMouseDragged, at: NSPoint(x: press.x + offset, y: press.y), in: window), atStart: false)
        }
        NSApp.postEvent(try mouse(.leftMouseUp, at: NSPoint(x: press.x + (offsets.last ?? 0), y: press.y), in: window), atStart: false)
        split.mouseDown(with: try mouse(.leftMouseDown, at: press, in: window))
        while NSApp.nextEvent(matching: [.leftMouseDragged, .leftMouseUp], until: nil, inMode: .eventTracking, dequeue: true) != nil {}
        return asked
    }

    // MARK: 1. The tiles under the lights

    /// The owner's report: the lights stood to the right of the tiles' column. Every tile's centre is the lights' centre.
    func testTheTilesColumnSitsUnderTheTrafficLights() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let window = try XCTUnwrap(harness.controller.window)
        let content = try XCTUnwrap(window.contentView)
        let chrome = QuireWindowChrome.metrics(of: window)
        let strip = layOut(harness)
        XCTAssertFalse(strip.showsNames, "the rail opens on its tiles alone")
        XCTAssertEqual(strip.railWidth, chrome.railWidth)
        XCTAssertEqual(harness.controller.railWidth, chrome.railWidth)
        XCTAssertEqual(chrome.railWidth, chrome.lightsStart + chrome.lightsEnd, accuracy: 1.01, "the leading inset, mirrored")
        let all = tiles(strip)
        XCTAssertGreaterThanOrEqual(all.count, 9, "the folders, All Inboxes and two accounts")
        for tile in all {
            let centre = tile.convert(NSPoint(x: tile.tileRect.midX, y: tile.tileRect.midY), to: content).x
            XCTAssertEqual(centre, chrome.lightsCenterX, accuracy: 0.5, "\(tile.accessibilityLabel() ?? "") under the lights' centre")
        }
        let (add, settings) = try utilities(strip)
        for button in [add, settings] {
            XCTAssertEqual(try visual(button, in: strip).midX, chrome.lightsCenterX, accuracy: 0.5)
            XCTAssertEqual(try visual(button, in: strip).size, NSSize(width: 28, height: 28))
        }
        for divider in strip.dividerRects {
            XCTAssertEqual(divider.midX, chrome.lightsCenterX, accuracy: 0.5)
            XCTAssertEqual(divider.width, r.dividerWidth)
        }
        // The width includes the rail's trailing hairline, the split's first divider.
        let split = harness.controller.splitView
        XCTAssertEqual(split.subviews[0].frame.width, chrome.railWidth - split.dividerThickness, accuracy: 0.01)
        XCTAssertEqual(split.subviews[1].frame.minX, chrome.railWidth, accuracy: 0.01)
    }

    // MARK: 3. Names

    func testNamesMakeEveryTileARowInItsPlace() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        var strip = layOut(harness)
        let before = try tops(strip)
        XCTAssertEqual(Array(before.prefix(6)), [62, 106, 150, 194, 238, 294], "the folders' places")
        let compact = strip.railWidth

        strip = showNames(true, in: harness)
        XCTAssertTrue(strip.showsNames)
        XCTAssertTrue(harness.controller.showsRailNames)
        XCTAssertEqual(strip.railWidth, r.namesWidth)
        XCTAssertEqual(r.namesWidth, 220)
        XCTAssertGreaterThan(r.namesWidth, compact)
        let split = harness.controller.splitView
        XCTAssertEqual(split.subviews[0].frame.width, r.namesWidth - split.dividerThickness, accuracy: 0.01)
        XCTAssertEqual(split.subviews[1].frame.minX, r.namesWidth, accuracy: 0.01)
        XCTAssertEqual(try tops(strip), before, "same rows, pitch and hairlines: nothing moves up or down")

        let rows = NSRect(x: r.rowInset, y: 0, width: r.namesWidth - 2 * r.rowInset, height: r.tile)
        for tile in tiles(strip) {
            XCTAssertTrue(tile.showsName)
            let row = tile.convert(tile.rowRect, to: strip.view)
            XCTAssertEqual(row.minX, rows.minX, "\(tile.name): the rail's width less the side inset")
            XCTAssertEqual(row.size, rows.size)
            let box = tile.convert(tile.tileRect, to: strip.view)
            XCTAssertEqual(box, NSRect(x: row.minX, y: row.minY, width: 38, height: 38), "the glyph's box at the row's leading end")
            XCTAssertEqual(tile.faceRect, tile.rowRect, "the ring and VoiceOver take the row")
            XCTAssertEqual(tile.hitRect, tile.rowRect.insetBy(dx: -3, dy: -3), "a click counts on the row, grown as the square was")
            XCTAssertEqual(tile.nameRect.minX, tile.tileRect.maxX + r.nameGap)
            XCTAssertEqual(tile.nameRect.midY, tile.rowRect.midY, accuracy: 0.5)
        }
        for divider in strip.dividerRects {
            XCTAssertEqual(divider.minX, rows.minX)
            XCTAssertEqual(divider.width, rows.width, "the hairlines take the rows' width")
        }
        let (add, settings) = try utilities(strip)
        for button in [add, settings] {
            XCTAssertTrue(button.showsName)
            let row = try visual(button, in: strip)
            XCTAssertEqual(row.minX, rows.minX)
            XCTAssertEqual(row.size, NSSize(width: rows.width, height: 28))
            // The symbol stays on the folders' line.
            XCTAssertEqual(button.convert(button.glyphRect, to: strip.view).midX, rows.minX + 19)
        }

        strip = showNames(false, in: harness)
        XCTAssertEqual(strip.railWidth, compact)
        XCTAssertEqual(split.subviews[0].frame.width, compact - split.dividerThickness, accuracy: 0.01)
        XCTAssertEqual(try tops(strip), before)
        for tile in tiles(strip) {
            XCTAssertEqual(tile.tileRect.midX, compact / 2, accuracy: 0.5, "a tile on the rail's centre again")
            XCTAssertEqual(tile.hitRect, tile.tileRect.insetBy(dx: -3, dy: -3))
        }
    }

    /// The words the title menu and the menus use, the pending account's state, and the utilities' own; tooltips still
    /// name the shortcut, and VoiceOver hears what it heard.
    func testNamesAreTheWordsTheAppAlreadyUses() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        harness.controller.applySignIn(SignInProgress(kind: .gmail, reconnecting: nil, subject: "Gmail"))
        let strip = showNames(true, in: harness)
        XCTAssertEqual(strip.folderTiles.map(\.name), ["Inbox", "Later", "Starred", "Sent", "Drafts", "Outbox", "Trash", "All Mail"])
        XCTAssertEqual(strip.folderTiles.map(\.name), TitleMenu.entries.map(\.title))
        XCTAssertEqual(strip.tile(for: .unified)?.name, "All Inboxes")
        let a = try XCTUnwrap(strip.tile(for: .account(ListTestSupport.accountA.id)))
        let b = try XCTUnwrap(strip.tile(for: .account(ListTestSupport.accountB.id)))
        XCTAssertEqual([a.name, b.name], ["Contoso · alex@contoso.test", "Fabrikam · alex@fabrikam.test"], "as the title menu lists them")
        let pending = try XCTUnwrap(tiles(strip).first { $0.content == .pending })
        XCTAssertEqual(pending.name, "Signing in…")
        XCTAssertTrue(pending.showsName, "a tile made while the names show is a row from the start")
        let (add, settings) = try utilities(strip)
        XCTAssertEqual([add.title, settings.title], ["Add Account", "Settings"])
        XCTAssertFalse(add.isEnabled, "Add waits while a sign-in runs, with its name")

        XCTAssertEqual(strip.folderTiles.map(\.toolTip), ["Inbox  G I", "Later  G L", "Starred  G S", "Sent  G T", "Drafts  G D", "Outbox  G O",
                                                         "Trash  G #", "All Mail  G A"])
        XCTAssertEqual(strip.tile(for: .unified)?.toolTip, "All Inboxes  ⌘0")
        XCTAssertEqual(a.toolTip, "Contoso · alex@contoso.test  ⌘1")
        XCTAssertEqual(settings.toolTip, "Settings  ⌘,")
        XCTAssertEqual(a.accessibilityLabel(), "Contoso, alex@contoso.test")
        XCTAssertEqual(strip.folderTiles[0].accessibilityLabel(), "Inbox")
        XCTAssertEqual(strip.folderTiles[0].accessibilityRole(), .radioButton)
        XCTAssertEqual([add.accessibilityLabel(), settings.accessibilityLabel()], ["Add Account", "Settings"])
        XCTAssertEqual(add.accessibilityRole(), .button)
        harness.controller.applySignIn(nil)
    }

    /// A tile's count hangs over its corner; a row's sits at its trailing end, centred on the row, and the name stops
    /// short of it. The words of the count are the same in both.
    func testACountSitsAtTheRowsTrailingEndAndTheNameStopsShortOfIt() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        var strip = layOut(harness)
        let inbox = strip.folderTiles[0]
        let starred = strip.folderTiles[2]
        harness.spin { inbox.unreadCount > 0 }
        let words = try XCTUnwrap(inbox.unreadBadgeText)
        var mark = try XCTUnwrap(inbox.markRect)
        XCTAssertEqual(mark.minY, inbox.tileRect.minY + r.badgeTop, "over the tile's corner")
        XCTAssertEqual(mark.maxX, inbox.tileRect.maxX - r.badgeTrailing)
        XCTAssertNil(starred.markRect, "only Inbox, All Inboxes and the accounts carry a count")

        strip = showNames(true, in: harness)
        XCTAssertEqual(inbox.unreadBadgeText, words)
        mark = try XCTUnwrap(inbox.markRect)
        XCTAssertEqual(mark.midY, inbox.rowRect.midY, accuracy: 0.5, "centred on the row")
        XCTAssertEqual(mark.maxX, inbox.rowRect.maxX - r.rowTrailing, "at the row's trailing end")
        XCTAssertEqual(mark.size, QuireBadge.size(for: .unread(inbox.unreadCount)), "the badge's own size")
        XCTAssertEqual(inbox.nameRect.maxX, mark.minX - r.nameCountGap, "the name stops short of the count")
        XCTAssertEqual(starred.nameRect.maxX, starred.rowRect.maxX - r.rowTrailing, "with no count the name runs to the trailing inset")
        for tile in tiles(strip) {
            XCTAssertGreaterThan(tile.nameRect.width, 60, "\(tile.name): room for a name")
            if let mark = tile.markRect { XCTAssertFalse(mark.intersects(tile.nameRect), tile.name) }
        }

        // Drawn: the count's fill where the mark is, the name's ink in its line box, and nothing of either on the tile.
        let pixel = try render(strip)
        let ground = try XCTUnwrap(pixel(NSPoint(x: starred.frame.minX + starred.rowRect.maxX - 20, y: starred.frame.minY + starred.rowRect.midY)))
        let starredName = starred.convert(starred.nameRect, to: strip.view)
        XCTAssertGreaterThan(strongestContrast(in: starredName, against: ground, pixel: pixel), 4.5, "“Starred” is drawn, in ink that reads")
        let countPoint = inbox.convert(NSPoint(x: mark.minX + 3, y: mark.midY), to: strip.view)
        let raised = try XCTUnwrap(pixel(inbox.convert(NSPoint(x: mark.minX - 6, y: mark.midY), to: strip.view)))
        XCTAssertGreaterThan(contrast(try XCTUnwrap(pixel(countPoint)), raised), 3, "the count's fill on the selected row")

        // A needs-sign-in account shows its attention mark in the count's place.
        let account = try XCTUnwrap(strip.tile(for: .account(ListTestSupport.accountB.id)))
        account.status = .needsSignIn
        let attention = try XCTUnwrap(account.markRect)
        XCTAssertEqual(attention.midY, account.rowRect.midY, accuracy: 0.5)
        XCTAssertEqual(attention.maxX, account.rowRect.maxX - r.rowTrailing)
        account.status = .firstSync
        account.layoutSubtreeIfNeeded()
        let spinner = try XCTUnwrap(account.markRect)
        XCTAssertEqual(spinner.midY, account.rowRect.midY, accuracy: 0.5, "the first download's spinner too")
        XCTAssertEqual(spinner.midX, attention.midX, accuracy: 0.5)
        XCTAssertEqual(account.nameRect.maxX, spinner.minX - r.nameCountGap)
    }

    /// Selection, hover, a press, a drop and the pending account, drawn: the selected folder's ground is the raised tile
    /// stretched to the row, the name follows the glyph's ink, in every theme, both appearances and Increase Contrast.
    func testARowsStatesReadInEveryThemeAndAppearance() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        harness.controller.applySignIn(SignInProgress(kind: .gmail, reconnecting: nil, subject: "Gmail"))
        let strip = showNames(true, in: harness)
        let inbox = strip.folderTiles[0]
        let starred = strip.folderTiles[2]
        let sent = strip.folderTiles[3]
        let trash = strip.folderTiles[6]
        let pending = try XCTUnwrap(tiles(strip).first { $0.content == .pending })
        let (add, settings) = try utilities(strip)
        XCTAssertTrue(inbox.isSelected)
        starred.displayState = .hover
        sent.displayState = .pressed
        trash.isDropTarget = true
        defer {
            starred.displayState = nil
            sent.displayState = nil
            trash.isDropTarget = false
            harness.controller.applySignIn(nil)
        }
        let looks: [NSAppearance.Name] = [.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua]
        for theme in QuireTheme.allCases {
            QuireEnvironment.shared.setTheme(theme)
            for look in looks {
                let pixel = try render(strip, appearance: look)
                func name(_ tile: AccountStripButton) -> NSRect { tile.convert(tile.nameRect, to: strip.view) }
                /// The row's ground, sampled past the name's end where nothing else is drawn.
                func ground(_ tile: AccountStripButton) throws -> NSColor {
                    try XCTUnwrap(pixel(tile.convert(NSPoint(x: tile.rowRect.maxX - 6, y: tile.rowRect.midY), to: strip.view)))
                }
                let spine = try XCTUnwrap(pixel(NSPoint(x: 4, y: 300)))
                let label = "\(theme.rawValue) \(look.rawValue)"
                XCTAssertNotEqual(try ground(inbox), spine, "\(label): the selected folder's row is raised")
                XCTAssertNotEqual(try ground(starred), spine, "\(label): the hover wash takes the row")
                XCTAssertNotEqual(try ground(sent), try ground(starred), "\(label): a press reads apart from hover")
                XCTAssertEqual(try ground(trash), try ground(sent), "\(label): a drop target reads as a press")
                XCTAssertEqual(try ground(strip.folderTiles[4]), spine, "\(label): a row at rest has no ground")
                for tile in [inbox, starred, sent, trash, strip.folderTiles[4], pending] {
                    // The pending account's `ink3` passes 4.5 as a token (`DesignContrastTests`); drawn at 1×, where no
                    // pixel of a 13 pt regular letter is all ink, it is held to 3.
                    XCTAssertGreaterThanOrEqual(strongestContrast(in: name(tile), against: try ground(tile), pixel: pixel),
                                                tile === pending ? 3 : 4.5, "\(label): “\(tile.name)” reads on its ground")
                }
                for button in [add, settings] {
                    let row = try visual(button, in: strip)
                    let words = NSRect(x: row.minX + 38 + r.nameGap, y: row.midY - 9, width: 90, height: 18)
                    // Add is disabled while the sign-in runs: its name is dimmed, as its symbol, and still shows.
                    XCTAssertGreaterThanOrEqual(strongestContrast(in: words, against: spine, pixel: pixel), button === add ? 1.3 : 4.5,
                                                "\(label): “\(button.title)”")
                }
            }
        }
        strip.view.appearance = nil
    }

    /// The names are chrome: Text size moves the list, the reader and the composer, never the rail.
    func testTextSizeLeavesTheRowsAsTheyAre() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        var strip = showNames(true, in: harness)
        let before = tiles(strip).map { $0.convert($0.nameRect, to: strip.view) }
        let places = try tops(strip)
        for size in QuireFont.TextSize.allCases {
            QuireEnvironment.shared.setTextSize(size)
            strip = layOut(harness)
            XCTAssertEqual(tiles(strip).map { $0.convert($0.nameRect, to: strip.view) }, before, "\(size)")
            XCTAssertEqual(try tops(strip), places, "\(size)")
            XCTAssertEqual(RailRow.name("Inbox", selected: false, color: .black).attribute(.font, at: 0, effectiveRange: nil) as? NSFont,
                           QuireFont.font(.body), "\(size): `body` at Default")
        }
        XCTAssertEqual(RailRow.name("Inbox", selected: true, color: .black).attribute(.font, at: 0, effectiveRange: nil) as? NSFont,
                       QuireFont.font(.bodyMedium), "the selected row's name is a step heavier")
    }

    func testTogglingKeepsTheSelectionTheScrollAndTheListsWidth() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        try addAccounts(6, to: harness)
        var strip = layOut(harness)
        XCTAssertEqual(strip.accounts.count, 8)
        XCTAssertTrue(harness.controller.perform(.goTo(.sent)))
        strip.selectShortcut(8)
        let offset = strip.accountScrollOffset
        XCTAssertGreaterThan(offset, 0, "the eighth account is scrolled into view")
        let split = harness.controller.splitView
        split.layoutSubtreeIfNeeded()
        let list = split.subviews[1].frame.width
        let reader = split.subviews[2].frame.width
        let clip = strip.accountClipFrame
        let chosen = try XCTUnwrap(strip.tile(for: .account(AccountID("acct-extra-6"))))

        for shows in [true, false, true] {
            strip = showNames(shows, in: harness)
            XCTAssertEqual(strip.scope, .account(AccountID("acct-extra-6")), "names \(shows)")
            XCTAssertEqual(strip.mailboxView, .sent)
            XCTAssertEqual(harness.list.query.view, .sent)
            XCTAssertTrue(chosen.isSelected)
            XCTAssertEqual(strip.folderTiles.map(\.isSelected), [false, false, false, true, false, false, false, false])
            XCTAssertEqual(strip.accountScrollOffset, offset, "names \(shows): the accounts stay scrolled where they were")
            XCTAssertEqual(strip.accountClipFrame.minY, clip.minY)
            XCTAssertEqual(strip.accountClipFrame.height, clip.height)
            XCTAssertEqual(strip.accountClipFrame.width, strip.railWidth, "the clip takes the rail's width")
            XCTAssertTrue(strip.accountClipFrame.contains(chosen.convert(chosen.tileRect, to: strip.view)), "the chosen account still shows")
            XCTAssertNotNil(strip.clipEdges.top, "and the clipped edge keeps its hairline")
            XCTAssertEqual(split.subviews[1].frame.width, list, accuracy: 0.01, "names \(shows): the list keeps its width")
            let wider = shows ? r.namesWidth - QuireWindowChrome.metrics(of: try XCTUnwrap(harness.controller.window)).railWidth : 0
            XCTAssertEqual(split.subviews[2].frame.width, reader - wider, accuracy: 0.01, "the reader takes the change")
        }
    }

    /// ⌘1…⌘9, ↑/↓ and a click on a row's far end work on rows as they do on tiles.
    func testRowsAnswerClicksKeysAndShortcuts() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let strip = showNames(true, in: harness)
        strip.selectShortcut(2)
        XCTAssertEqual(strip.scope, .account(ListTestSupport.accountB.id))
        strip.selectShortcut(0)
        XCTAssertEqual(strip.scope, .unified)
        // A click counts along the whole row: on the name, well outside the square a tile has.
        let drafts = strip.folderTiles[4]
        let onName = drafts.convert(NSPoint(x: drafts.nameRect.midX, y: drafts.nameRect.midY), to: strip.view)
        XCTAssertTrue(strip.view.hitTest(strip.view.convert(onName, to: strip.view.superview)) === drafts)
        drafts.performClick(nil)
        XCTAssertEqual(harness.list.query.view, .drafts)
        drafts.onArrow?(-1)
        XCTAssertEqual(harness.list.query.view, .sent, "↑ steps to the row above")
        XCTAssertTrue(strip.keyViews[0] === strip.folderTiles[3], "one Tab stop for the folders: the current view's row")
        XCTAssertEqual(strip.keyViews.count, 4)
        // Between two account rows, 6 pt belong to neither, as between their tiles.
        let a = try XCTUnwrap(strip.tile(for: .account(ListTestSupport.accountA.id)))
        let b = try XCTUnwrap(strip.tile(for: .account(ListTestSupport.accountB.id)))
        XCTAssertEqual(b.convert(b.hitRect, to: strip.view).minY - a.convert(a.hitRect, to: strip.view).maxY, r.accountPitch - r.tileHit)
    }

    /// Rows dragged from the list drop on a folder's row, anywhere along it.
    func testRowsDroppedOnAFoldersRowActAsOnItsTile() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let strip = showNames(true, in: harness)
        let trash = strip.folderTiles[6]
        let sent = strip.folderTiles[3]
        let id = harness.list.conversations[0].id
        let index = try XCTUnwrap(harness.list.conversations.firstIndex { $0.id == id })
        let row = try XCTUnwrap(harness.list.layout.row(ofConversation: index))
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()
        pasteboards.append(pasteboard)
        pasteboard.writeObjects([try XCTUnwrap(harness.list.tableView(harness.list.tableView, pasteboardWriterForRow: row))])
        let info = FakeDraggingInfo(pasteboard: pasteboard, source: harness.list.tableView, mask: [.copy, .move])

        // Over the name's far end, 150 pt from the glyph: a tile's square would be nowhere near.
        info.draggingLocation = sent.convert(NSPoint(x: sent.rowRect.maxX - 8, y: sent.rowRect.midY), to: nil)
        XCTAssertTrue(strip.view.draggingEntered(info).isEmpty, "Sent takes no drop, as a tile or a row")
        info.draggingLocation = trash.convert(NSPoint(x: trash.rowRect.maxX - 8, y: trash.rowRect.midY), to: nil)
        XCTAssertFalse(strip.view.draggingUpdated(info).isEmpty)
        XCTAssertTrue(trash.isDropTarget, "the row lights under the drag")
        XCTAssertTrue(strip.view.performDragOperation(info))
        strip.view.draggingEnded(info)
        XCTAssertFalse(trash.isDropTarget)
        harness.spin { !harness.list.conversations.contains { $0.id == id } }
        XCTAssertFalse(harness.list.conversations.contains { $0.id == id }, "trashed, as # does")
    }

    // MARK: The choice

    func testTheChoiceIsKeptAndAHiddenRailKeepsIt() throws {
        let settings = ListTestSupport.settings()
        XCTAssertFalse(settings.showsRailNames, "off until asked for")
        var harness = try MainWindowHarness(settings: settings)
        let controller = harness.controller
        XCTAssertFalse(controller.showsRailNames)
        controller.toggleRailNames(nil)
        XCTAssertTrue(controller.showsRailNames)
        XCTAssertTrue(settings.showsRailNames, "kept in the app's settings")

        // Hiding the rail is another matter: the masthead goes where it always went, and the rail comes back with names.
        controller.toggleAccountStrip(nil)
        let split = controller.splitView
        split.layoutSubtreeIfNeeded()
        XCTAssertTrue(split.isSubviewCollapsed(split.subviews[0]))
        XCTAssertTrue(controller.showsRailNames, "a hidden rail keeps the state it had")
        XCTAssertTrue(settings.showsRailNames)
        let header = controller.listPane.header
        XCTAssertEqual(header.mastheadX, QuireWindowChrome.metrics(of: try XCTUnwrap(controller.window)).mastheadMinimalX,
                       "the minimal masthead clears the lights, whatever the rail's width was")
        controller.toggleAccountStrip(nil)
        split.layoutSubtreeIfNeeded()
        XCTAssertFalse(split.isSubviewCollapsed(split.subviews[0]))
        XCTAssertEqual(split.subviews[0].frame.width, r.namesWidth - split.dividerThickness, accuracy: 0.01, "back with its names")
        XCTAssertEqual(header.mastheadX, Quire.Layout.ListHeader.mastheadX)
        harness.close()

        // The next window opens as this one was left.
        harness = try MainWindowHarness(settings: settings)
        defer { harness.close() }
        let strip = layOut(harness)
        XCTAssertTrue(harness.controller.showsRailNames)
        XCTAssertTrue(strip.showsNames)
        XCTAssertEqual(harness.controller.splitView.subviews[0].frame.width, r.namesWidth - harness.controller.splitView.dividerThickness,
                       accuracy: 0.01)
        XCTAssertTrue(tiles(strip).allSatisfy(\.showsName))
        // A drag still held follows the pointer without saving; only its end, or the menu, keeps a choice.
        harness.controller.setRailNames(false, keeping: false)
        XCTAssertFalse(harness.controller.showsRailNames)
        XCTAssertTrue(settings.showsRailNames)
        harness.controller.setRailNames(false)
        XCTAssertFalse(settings.showsRailNames)
    }

    func testTheSettingHasItsOwnDefaultsKey() throws {
        let suite = "PaperAppTests.RailNames.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertFalse(AppSettings(defaults: defaults).showsRailNames)
        XCTAssertNil(defaults.persistentDomain(forName: suite)?["showsRailNames"], "reading writes nothing")
        let settings = AppSettings(defaults: defaults)
        settings.showsRailNames = true
        XCTAssertEqual(defaults.persistentDomain(forName: suite)?["showsRailNames"] as? Bool, true)
        XCTAssertTrue(AppSettings(defaults: defaults).showsRailNames, "the next launch reads it")
        settings.showsDayColumn = false
        XCTAssertTrue(AppSettings(defaults: defaults).showsRailNames, "apart from the window's other choices")
    }

    /// View › Show Names in Rail, beside Hide Account Rail, retitled by what shows, and off while the rail is hidden.
    func testTheViewMenuShowsAndHidesTheNames() throws {
        let previous = (MainMenuController.shared, NSApp.windowsMenu, NSApp.helpMenu)
        defer { (MainMenuController.shared, NSApp.windowsMenu, NSApp.helpMenu) = previous }
        let bar = MainMenu.build(appDelegate: AppDelegate(options: LaunchOptions(arguments: ["Paper"])))
        let view = try XCTUnwrap(bar.items.compactMap(\.submenu).first { $0.title == "View" })
        let index = try XCTUnwrap(view.items.firstIndex { $0.action == #selector(MainWindowController.toggleRailNames(_:)) })
        let item = view.items[index]
        XCTAssertEqual(view.items[index - 1].action, #selector(MainWindowController.toggleAccountStrip(_:)), "next to Hide Account Rail")
        XCTAssertEqual(item.title, "Show Names in Rail")
        XCTAssertEqual(item.keyEquivalent, "", "no key: none on the key table is free that says it")
        XCTAssertNil(item.target, "the main window answers it")

        let harness = try MainWindowHarness()
        defer { harness.close() }
        let controller = harness.controller
        XCTAssertTrue(controller.validateMenuItem(item))
        XCTAssertEqual(item.title, "Show Names in Rail")
        controller.toggleRailNames(item)
        XCTAssertTrue(controller.showsRailNames)
        XCTAssertTrue(controller.validateMenuItem(item))
        XCTAssertEqual(item.title, "Hide Names in Rail")
        controller.toggleAccountStrip(nil)
        XCTAssertFalse(controller.validateMenuItem(item), "a hidden rail has no names to show or hide")
        XCTAssertEqual(item.title, "Hide Names in Rail", "and still says what it kept")
        controller.toggleAccountStrip(nil)
        controller.toggleRailNames(item)
        XCTAssertFalse(controller.showsRailNames)
        XCTAssertTrue(controller.validateMenuItem(item))
        XCTAssertEqual(item.title, "Show Names in Rail")
    }

    /// The narrowest window still holds the rail with its names, the narrowest list and the narrowest reader.
    func testTheNarrowestWindowHoldsTheNames() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let window = try XCTUnwrap(harness.controller.window)
        let split = harness.controller.splitView
        // The list at its widest, in a window that then shrinks to its minimum: the list gives way, never the rail.
        window.setContentSize(NSSize(width: 1500, height: 700))
        split.setPosition(QuireWindowChrome.metrics(of: window).railWidth + 480, ofDividerAt: 1)
        split.layoutSubtreeIfNeeded()
        _ = showNames(true, in: harness)
        window.setContentSize(QuireWindowChrome.minimumSize)
        split.layoutSubtreeIfNeeded()
        XCTAssertEqual(window.contentView?.bounds.width, 960)
        XCTAssertEqual(split.subviews[0].frame.width, r.namesWidth - split.dividerThickness, accuracy: 0.01)
        XCTAssertGreaterThanOrEqual(split.subviews[1].frame.width, Quire.Layout.List.minWidth - 0.01, "the list keeps its minimum")
        XCTAssertGreaterThanOrEqual(split.subviews[2].frame.width, Quire.Layout.Window.readerMinWidth - 0.01, "the reader keeps its 400 pt")
        XCTAssertEqual(split.subviews[2].frame.maxX, 960, accuracy: 0.01, "and nothing runs off the window")

        // The other way round: the narrowest window with the list as wide as it lets it be, then the names.
        _ = showNames(false, in: harness)
        split.setPosition(QuireWindowChrome.metrics(of: window).railWidth + 480, ofDividerAt: 1)
        split.layoutSubtreeIfNeeded()
        let widest = split.subviews[1].frame.width
        XCTAssertGreaterThan(widest, Quire.Layout.List.minWidth + 50, "the list took what the tile rail leaves it")
        _ = showNames(true, in: harness)
        XCTAssertEqual(split.subviews[0].frame.width, r.namesWidth - split.dividerThickness, accuracy: 0.01)
        XCTAssertLessThan(split.subviews[1].frame.width, widest, "the list gives way to the names")
        XCTAssertGreaterThanOrEqual(split.subviews[1].frame.width, Quire.Layout.List.minWidth - 0.01)
        XCTAssertGreaterThanOrEqual(split.subviews[2].frame.width, Quire.Layout.Window.readerMinWidth - 0.01)
        XCTAssertEqual(split.subviews[2].frame.maxX, 960, accuracy: 0.01)
    }

    // MARK: The edge

    func testTheDragDecision() {
        let compact = RailEdgeDrag(showsNames: false, compactWidth: 98, namesWidth: 220)
        XCTAssertFalse(compact.showsNames(atOffset: 0))
        XCTAssertFalse(compact.showsNames(atOffset: 60))
        XCTAssertFalse(compact.showsNames(atOffset: 61), "exactly halfway is not past it")
        XCTAssertTrue(compact.showsNames(atOffset: 61.5))
        XCTAssertTrue(compact.showsNames(atOffset: 400), "far past the names' width")
        XCTAssertFalse(compact.showsNames(atOffset: -300), "the other way does nothing: the rail has no third width")

        let names = RailEdgeDrag(showsNames: true, compactWidth: 98, namesWidth: 220)
        XCTAssertTrue(names.showsNames(atOffset: 0))
        XCTAssertTrue(names.showsNames(atOffset: -61), "exactly halfway is not past it")
        XCTAssertFalse(names.showsNames(atOffset: -61.5))
        XCTAssertFalse(names.showsNames(atOffset: -500))
        XCTAssertTrue(names.showsNames(atOffset: 300))

        // Another release's rail: the halfway point follows its width.
        let older = RailEdgeDrag(showsNames: false, compactWidth: 92, namesWidth: 220)
        XCTAssertFalse(older.showsNames(atOffset: 64))
        XCTAssertTrue(older.showsNames(atOffset: 64.5))
    }

    /// A press on the rail's edge dragged past halfway switches the rail, live, and back if the pointer comes back; the
    /// release keeps what shows, one of the two widths, and saves the choice once.
    func testDraggingTheEdgeSwitchesTheRailLive() throws {
        let settings = ListTestSupport.settings()
        let harness = try MainWindowHarness(settings: settings)
        defer { harness.close() }
        let controller = harness.controller
        let split = try XCTUnwrap(controller.splitView as? HairlineSplitView)
        let compact = QuireWindowChrome.metrics(of: try XCTUnwrap(controller.window)).railWidth
        let half = (r.namesWidth - compact) / 2
        _ = layOut(harness)
        func paneWidth() -> CGFloat {
            split.layoutSubtreeIfNeeded()
            return split.subviews[0].frame.width + split.dividerThickness
        }

        XCTAssertEqual(try dragEdge(of: harness, through: [10, half - 1, half]), [], "not past halfway: nothing")
        XCTAssertFalse(controller.showsRailNames)
        XCTAssertEqual(paneWidth(), compact, accuracy: 0.01)
        XCTAssertEqual(try dragEdge(of: harness, through: [-40, -90]), [], "a tile rail has nowhere narrower to go")
        XCTAssertEqual(paneWidth(), compact, accuracy: 0.01)

        XCTAssertEqual(try dragEdge(of: harness, through: [20, half + 1, 150]), [true], "past halfway: the names, once")
        XCTAssertTrue(controller.showsRailNames)
        XCTAssertTrue(settings.showsRailNames, "the release keeps the choice")
        XCTAssertEqual(paneWidth(), r.namesWidth, accuracy: 0.01)

        XCTAssertEqual(try dragEdge(of: harness, through: [-20, -half]), [], "back less than halfway: the names stay")
        XCTAssertEqual(paneWidth(), r.namesWidth, accuracy: 0.01)
        XCTAssertEqual(try dragEdge(of: harness, through: [-half - 1, -10]), [false, true], "there and back in one drag")
        XCTAssertTrue(controller.showsRailNames, "the release leaves what shows")
        XCTAssertTrue(settings.showsRailNames)
        XCTAssertEqual(paneWidth(), r.namesWidth, accuracy: 0.01)

        XCTAssertEqual(try dragEdge(of: harness, through: [-30, -half - 4]), [false])
        XCTAssertFalse(controller.showsRailNames)
        XCTAssertFalse(settings.showsRailNames)
        XCTAssertEqual(paneWidth(), compact, accuracy: 0.01, "one of the two widths, never one between")

        // A hidden rail has no edge: the divider at the window's edge is AppKit's.
        controller.toggleAccountStrip(nil)
        split.layoutSubtreeIfNeeded()
        XCTAssertNil(split.railEdgeGrabRect)
        controller.toggleAccountStrip(nil)
    }

    /// The edge takes the press over the 6 pt the list's edge has and shows the resize pointer, alone; rows take the
    /// hand along their whole length, the pending row and a waiting Add the arrow.
    func testTheEdgesPointerAndTheRowsPointers() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let window = try XCTUnwrap(harness.controller.window)
        window.setContentSize(NSSize(width: 1280, height: 800))
        let split = try XCTUnwrap(harness.controller.splitView as? HairlineSplitView)
        for shows in [false, true] {
            let strip = showNames(shows, in: harness)
            window.layoutIfNeeded()
            let grab = try XCTUnwrap(split.railEdgeGrabRect)
            let hairline = split.subviews[0].frame.maxX
            XCTAssertGreaterThanOrEqual(grab.width, Quire.Layout.Window.dividerHit)
            XCTAssertEqual(grab.midX, hairline + split.dividerThickness / 2, accuracy: 0.01, "around the rail's hairline")
            XCTAssertEqual(grab.height, split.bounds.height)
            XCTAssertEqual(grab.width, try XCTUnwrap(split.dividerGrabRect(after: 1)).width, "names \(shows): the grab area the list's edge has")
            let superview = try XCTUnwrap(split.superview)
            for x in [grab.minX + 0.5, grab.midX, grab.maxX - 0.5] {
                XCTAssertTrue(split.hitTest(superview.convert(NSPoint(x: x, y: 300), from: split)) === split, "names \(shows): a press at \(x) is the edge's")
            }
            XCTAssertFalse(split.hitTest(superview.convert(NSPoint(x: grab.minX - 6, y: 300), from: split)) === split, "beside it, the rail's")

            let recorder = CursorRectRecorder(window)
            for x in [grab.minX + 0.5, grab.midX, grab.maxX - 0.5] {
                let atEdge = recorder.cursors(at: split.convert(NSPoint(x: x, y: 300), to: nil))
                XCTAssertEqual(atEdge.count, 1, "names \(shows): the edge's own pointer alone at \(x), not AppKit's with it")
                XCTAssertFalse(atEdge.contains { $0 === NSCursor.pointingHand || $0 === NSCursor.arrow || $0 === NSCursor.iBeam }, "a resize pointer")
            }
            // The list's edge keeps AppKit's pointer, over the same width.
            let listEdge = try XCTUnwrap(split.dividerGrabRect(after: 1))
            XCTAssertEqual(recorder.cursors(at: split.convert(NSPoint(x: listEdge.midX, y: 300), to: nil)).count, 1)
            let edges = recorder.rects(of: split).map(\.rect).filter { !$0.isEmpty }
            XCTAssertEqual(edges.count, 2, "one pointer for each edge")
            XCTAssertEqual(Set(edges.map(\.width)), [grab.width])
            let all = tiles(strip)
            for tile in all {
                XCTAssertEqual(recorder.cursors(atCentreOf: tile.hitRect, in: tile), [.pointingHand], "\(tile.name)")
                if shows {
                    let onName = NSRect(x: tile.nameRect.maxX - 4, y: tile.rowRect.midY, width: 0, height: 0)
                    XCTAssertEqual(recorder.cursors(atCentreOf: onName, in: tile), [.pointingHand], "\(tile.name): along the row")
                }
            }
            assertDisjoint(all.flatMap { recorder.rects(of: $0).map(\.rect) } + recorder.rects(of: split).map(\.rect))
            let (add, settings) = try utilities(strip)
            for button in [add, settings] {
                XCTAssertEqual(recorder.cursors(atCentreOf: button.hitRect, in: button), [.pointingHand], button.title)
            }
        }

        let strip = harness.controller.strip
        strip.setSignIn(active: true, adding: true, reconnecting: nil)
        window.layoutIfNeeded()
        let pending = try XCTUnwrap(tiles(strip).first { $0.content == .pending })
        let add = try utilities(strip).add
        let recorder = CursorRectRecorder(window)
        XCTAssertEqual(recorder.cursors(atCentreOf: pending.hitRect, in: pending), [.arrow], "the pending row does nothing")
        XCTAssertEqual(recorder.cursors(atCentreOf: add.hitRect, in: add), [.arrow], "Add waits while a sign-in runs")
        strip.setSignIn(active: false, adding: false, reconnecting: nil)
    }

    private func assertDisjoint(_ rects: [NSRect], file: StaticString = #filePath, line: UInt = #line) {
        let rects = rects.filter { !$0.isEmpty }
        for (index, first) in rects.enumerated() {
            for second in rects.dropFirst(index + 1) where !first.intersection(second).isEmpty {
                XCTFail("\(first) and \(second) overlap", file: file, line: line)
            }
        }
    }
}
