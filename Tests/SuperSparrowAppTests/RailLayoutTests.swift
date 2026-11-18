import AppKit
import SSCore
import SSDesign
import XCTest
@testable import SuperSparrowApp

/// The rail (spec §5.2): the six views as folder tiles at the top, with Later and the Outbox only while they hold
/// something, the account group anchored just above Add, and an account stack that scrolls in its own clip once folders
/// and accounts no longer fit.
@MainActor
final class RailLayoutTests: XCTestCase {
    private func layOut(_ harness: MainWindowHarness) -> AccountStripViewController {
        let strip = harness.controller.strip
        strip.view.layoutSubtreeIfNeeded()
        return strip
    }

    private func tileRect(_ tile: AccountStripButton, in strip: AccountStripViewController) -> NSRect {
        tile.convert(tile.tileRect, to: strip.view)
    }

    /// Add's 28 pt visual rect in rail coordinates (Add is the rail's third key view).
    private func addRect(_ strip: AccountStripViewController) throws -> NSRect {
        let add = try XCTUnwrap(strip.keyViews[2] as? QuireControl)
        let superview = try XCTUnwrap(add.superview)
        return superview.convert(add.alignmentRect(forFrame: add.frame), to: strip.view)
    }

    // MARK: Folders

    func testFolderTilesFollowTheTitleMenuInOrderAndPlace() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let strip = layOut(harness)
        XCTAssertEqual(strip.folderTiles.map(\.content), TitleMenu.entries.map { .folder(symbol: $0.symbol) })
        XCTAssertEqual(TitleMenu.entries.map(\.symbol), ["tray", "clock", "star", "paperplane", "doc", "tray.and.arrow.up", "trash", "archivebox"])
        XCTAssertEqual(strip.folderTiles.map(\.toolTip), ["Inbox  G I", "Later  G L", "Starred  G S", "Sent  G T", "Drafts  G D", "Outbox  G O",
                                                         "Trash  G #", "All Mail  G A"])
        // Nothing is snoozed and nothing waits to go: Later and the Outbox are hidden and the six views keep their places.
        // Inbox at 62, then a 44 pt pitch to Trash; All Mail below the folders' hairline at 294.
        let shown = strip.folderTiles.filter { !$0.isHidden }
        XCTAssertTrue(strip.folderTiles[1].isHidden)
        XCTAssertTrue(strip.folderTiles[5].isHidden)
        XCTAssertEqual(shown.map { tileRect($0, in: strip).minY }, [62, 106, 150, 194, 238, 294])
        for tile in shown {
            let rect = tileRect(tile, in: strip)
            XCTAssertEqual(rect.size, NSSize(width: 38, height: 38))
            XCTAssertEqual(rect.midX, strip.railWidth / 2, accuracy: 0.5, "centred on the whole rail")
        }
    }

    func testClickingAFolderSwitchesTheViewAsTheTitleMenuDoes() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let strip = layOut(harness)
        XCTAssertEqual(strip.folderTiles.map(\.isSelected), [true, false, false, false, false, false, false, false], "the Inbox to start")
        harness.controller.listPane.header.search.query = "project"
        harness.controller.listPane.header.search.onQueryChange?("project")

        strip.folderTiles[3].performClick(nil)
        XCTAssertEqual(harness.list.query.view, .sent)
        XCTAssertNil(harness.list.query.searchText, "picking a mailbox ends the search, as the title menu does")
        XCTAssertEqual(harness.controller.listPane.header.masthead.title, "Sent")
        XCTAssertEqual(strip.folderTiles.map(\.isSelected), [false, false, false, true, false, false, false, false])
        // The search field follows the masthead's new width.
        let header = harness.controller.listPane.header
        header.layoutSubtreeIfNeeded()
        let masthead = header.masthead.superview!.convert(header.masthead.alignmentRect(forFrame: header.masthead.frame), to: header)
        let search = header.search.superview!.convert(header.search.alignmentRect(forFrame: header.search.frame), to: header)
        XCTAssertEqual(search.minX, masthead.maxX - Quire.Layout.ListHeader.mastheadHitPad + Quire.Layout.ListHeader.searchGap, accuracy: 0.5)

        // The G-sequences are unchanged and move the folder selection with them.
        XCTAssertTrue(harness.controller.perform(.goTo(.all)))
        XCTAssertEqual(harness.list.query.view, .all)
        XCTAssertEqual(strip.folderTiles.map(\.isSelected), [false, false, false, false, false, false, false, true])
        strip.folderTiles[0].performClick(nil)
        XCTAssertEqual(harness.list.query.view, .inbox)
        XCTAssertEqual(harness.controller.listPane.header.masthead.title, "Inbox")
    }

    func testInboxCarriesTheScopesUnreadInboxCount() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let strip = layOut(harness)
        let unified = try XCTUnwrap(strip.tile(for: .unified))
        harness.spin { unified.unreadCount > 0 && strip.folderTiles[0].unreadCount == unified.unreadCount }
        XCTAssertGreaterThan(strip.folderTiles[0].unreadCount, 0)
        XCTAssertEqual(strip.folderTiles[0].unreadCount, unified.unreadCount, "all accounts: the unified Inbox count")
        XCTAssertEqual(strip.folderTiles.dropFirst().map(\.unreadCount), [0, 0, 0, 0, 0, 0, 0],
                       "only Inbox carries a count; Later and the Outbox never do")

        strip.selectShortcut(2)
        let account = try XCTUnwrap(strip.tile(for: .account(ListTestSupport.accountB.id)))
        XCTAssertNotEqual(account.unreadCount, unified.unreadCount, "the fixture's accounts differ from the total")
        XCTAssertEqual(strip.folderTiles[0].unreadCount, account.unreadCount, "narrowed: that account's Inbox count")
        strip.selectShortcut(0)
        XCTAssertEqual(strip.folderTiles[0].unreadCount, unified.unreadCount)
    }

    /// The view's selection is the raised tile alone; the scope's carries the margin rule, so the two read apart.
    func testASelectedFolderDrawsNoMarginRule() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let strip = layOut(harness)
        let unified = try XCTUnwrap(strip.tile(for: .unified))
        XCTAssertTrue(strip.folderTiles[0].isSelected)
        XCTAssertTrue(unified.isSelected)
        func ruleColumn(_ tile: AccountStripButton) -> NSColor? {
            tile.appearance = NSAppearance(named: .aqua)
            tile.windowKeyOverride = true
            guard let rep = tile.bitmapImageRepForCachingDisplay(in: tile.bounds) else { return nil }
            tile.cacheDisplay(in: tile.bounds, to: rep)
            let scale = CGFloat(rep.pixelsWide) / tile.bounds.width
            return rep.colorAt(x: Int(1 * scale), y: Int(tile.tileRect.midY * scale))
        }
        let folderPixel = try XCTUnwrap(ruleColumn(strip.folderTiles[0]))
        let unifiedPixel = try XCTUnwrap(ruleColumn(unified))
        XCTAssertLessThan(folderPixel.alphaComponent, 0.01, "nothing at x = 0 beside the selected folder")
        XCTAssertGreaterThan(unifiedPixel.alphaComponent, 0.9, "All Inboxes keeps its margin rule")
    }

    func testTabEntersTheFoldersOnTheCurrentViewThenTheAccounts() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let strip = layOut(harness)
        XCTAssertTrue(strip.keyViews[0] === strip.folderTiles[0])
        XCTAssertTrue(strip.keyViews[1] === strip.tile(for: .unified))
        XCTAssertEqual(strip.keyViews.count, 4, "folder, account, Add, Settings")
        _ = harness.controller.perform(.goTo(.drafts))
        XCTAssertTrue(strip.keyViews[0] === strip.folderTiles[4], "one Tab stop for the folders: the current view's")
    }

    // MARK: Accounts

    func testTheAccountGroupIsAnchoredJustAboveAdd() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let strip = layOut(harness)
        let height = strip.view.bounds.height
        let r = Quire.Layout.Rail.self
        let rects = strip.accountTileRects
        XCTAssertEqual(rects.count, 2)
        let add = try addRect(strip)
        XCTAssertEqual(add.minY, height - r.addTopFromBottom, accuracy: 0.5)
        // The last tile ends 6 pt inside the stack's clip, which ends 12 pt above Add.
        XCTAssertEqual(try XCTUnwrap(rects.last).maxY, add.minY - r.stackBottomGap - r.stackInset, accuracy: 0.5)
        XCTAssertEqual(rects[1].minY - rects[0].minY, r.accountPitch, accuracy: 0.5)
        let unified = tileRect(try XCTUnwrap(strip.tile(for: .unified)), in: strip)
        // All Inboxes, 16 pt, the hairline, 14 pt, the first account.
        XCTAssertEqual(rects[0].minY - unified.maxY, r.dividerGap + r.accountGap, accuracy: 0.5)
        XCTAssertEqual(strip.accountClipFrame.maxY, add.minY - r.stackBottomGap, accuracy: 0.5)
        let allMail = tileRect(try XCTUnwrap(strip.folderTiles.last), in: strip)
        XCTAssertGreaterThanOrEqual(unified.minY, allMail.maxY + r.groupGap, "never on the folders")
        XCTAssertNil(strip.clipEdges.top)
        XCTAssertNil(strip.clipEdges.bottom, "two accounts fit: nothing is clipped")
    }

    /// Without scrolling: one account at the 600 pt minimum, five at the default 800 pt, seven at 900 pt; while the
    /// Later tile or the Outbox tile shows, All Mail sits one pitch lower and each figure is one fewer, and while both do,
    /// two pitches lower and two fewer.
    func testCapacityBeforeTheStackScrolls() {
        typealias Shown = AccountStripViewController.ConditionalFolders
        let layout = { AccountStripViewController.accountGroupLayout(railHeight: $0, tileCount: $1) }
        for (height, fits) in [(CGFloat(600), 1), (800, 5), (900, 7)] {
            XCTAssertFalse(layout(height, fits).scrolls, "\(fits) at \(height)")
            XCTAssertTrue(layout(height, fits + 1).scrolls, "\(fits + 1) at \(height)")
        }
        for shown in [Shown(later: true), Shown(outbox: true)] {
            let withOne = { AccountStripViewController.accountGroupLayout(railHeight: $0, tileCount: $1, showing: shown) }
            for (height, fits) in [(CGFloat(600), 0), (800, 4), (900, 6)] {
                XCTAssertFalse(withOne(height, fits).scrolls, "\(fits) at \(height) with \(shown)")
                XCTAssertTrue(withOne(height, fits + 1).scrolls, "\(fits + 1) at \(height) with \(shown)")
            }
            XCTAssertEqual(withOne(600, 3).unifiedTop, 396, "All Inboxes stays 20 pt under All Mail's lower place (338 + 38)")
        }
        let withBoth = { AccountStripViewController.accountGroupLayout(railHeight: $0, tileCount: $1, showing: Shown(later: true, outbox: true)) }
        for (height, fits) in [(CGFloat(800), 3), (900, 5)] {
            XCTAssertFalse(withBoth(height, fits).scrolls, "\(fits) at \(height) with both")
            XCTAssertTrue(withBoth(height, fits + 1).scrolls, "\(fits + 1) at \(height) with both")
        }
        XCTAssertTrue(withBoth(600, 1).scrolls, "at the minimum height even one account scrolls")
        XCTAssertEqual(withBoth(600, 3).unifiedTop, 440, "two pitches lower: 20 pt under All Mail at 382 + 38")
        let r = Quire.Layout.Rail.self
        let floor = r.allMailTop + r.tile + r.groupGap
        XCTAssertEqual(floor, 352)
        for height in stride(from: CGFloat(600), through: 1_200, by: 50) {
            for count in 0...12 {
                let group = layout(height, count)
                XCTAssertGreaterThanOrEqual(group.unifiedTop, floor, "All Inboxes stays clear of All Mail")
                XCTAssertEqual(group.clipBottom, height - r.addTopFromBottom - r.stackBottomGap, "the clip stops 12 pt above Add")
                if !group.scrolls, count > 0 {
                    XCTAssertEqual(group.clipTop + group.contentHeight, group.clipBottom, accuracy: 0.5, "anchored on Add")
                }
            }
        }
        // Once it scrolls, the group stops under the folders and only the account tiles move.
        let crowded = layout(600, 3)
        XCTAssertEqual(crowded.unifiedTop, floor)
        XCTAssertEqual(crowded.dividerY, floor + r.tile + r.dividerGap)
        XCTAssertEqual(crowded.clipTop, crowded.dividerY + r.accountGap - r.stackInset)
    }

    /// Where each folder sits with neither, either or both conditional tiles: the shown ones in the title menu's order at
    /// the 44 pt pitch from Inbox at 62, Later directly below Inbox and the Outbox between Drafts and Trash, the hairline
    /// and All Mail one pitch lower for each; no two folders ever share a place.
    func testFolderPlacesWithTheConditionalTiles() {
        typealias Strip = AccountStripViewController
        typealias Shown = Strip.ConditionalFolders
        let order: [MailboxView] = [.inbox, .later, .starred, .sent, .drafts, .outbox, .trash, .all]
        XCTAssertEqual(TitleMenu.entries.map(\.view), order)
        func tops(_ shown: Shown) -> [CGFloat] {
            order.filter(shown.shows).map { Strip.folderTop(for: $0, showing: shown) }
        }
        XCTAssertEqual(tops(Shown()), [62, 106, 150, 194, 238, 294])
        XCTAssertEqual(tops(Shown(later: true)), [62, 106, 150, 194, 238, 282, 338])
        XCTAssertEqual(tops(Shown(outbox: true)), [62, 106, 150, 194, 238, 282, 338], "the Outbox at 238, Trash at 282")
        XCTAssertEqual(Strip.folderTop(for: .outbox, showing: Shown(outbox: true)), 238)
        XCTAssertEqual(tops(Shown(later: true, outbox: true)), [62, 106, 150, 194, 238, 282, 326, 382])
        XCTAssertEqual(Strip.folderTop(for: .outbox, showing: Shown(later: true, outbox: true)), 282, "below Drafts, itself a pitch lower")
        XCTAssertEqual(Strip.folderShift(Shown()), 0)
        XCTAssertEqual(Strip.folderShift(Shown(later: true)), 44)
        XCTAssertEqual(Strip.folderShift(Shown(outbox: true)), 44)
        XCTAssertEqual(Strip.folderShift(Shown(later: true, outbox: true)), 88)
        for shown in [Shown(), Shown(later: true), Shown(outbox: true), Shown(later: true, outbox: true)] {
            let places = tops(shown)
            XCTAssertEqual(Set(places).count, places.count, "\(shown): no two folders in one place")
            for (upper, lower) in zip(places, places.dropFirst()) {
                XCTAssertGreaterThanOrEqual(lower - upper, Quire.Layout.Rail.tileHit, "\(shown): the hit squares never overlap")
            }
            // The hairline sits between the last folder above it and All Mail.
            let hairline = Quire.Layout.Rail.folderDividerY + Strip.folderShift(shown)
            XCTAssertGreaterThan(hairline, places[places.count - 2] + Quire.Layout.Rail.tile, "\(shown)")
            XCTAssertLessThan(hairline, places[places.count - 1], "\(shown)")
        }
    }

    func testAStackThatDoesNotFitScrollsAndShowsTheChosenTile() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        for n in 1...6 {
            try harness.environment.store.upsertAccount(Account(id: AccountID("acct-extra-\(n)"), kind: .gmail, email: "alex@extra\(n).test",
                                                                displayName: "Alex Morgan", addedAt: Date(timeIntervalSince1970: Double(10 + n)),
                                                                inkSlot: 1 + n))
        }
        harness.controller.refreshAccounts()
        let strip = layOut(harness)
        XCTAssertEqual(strip.accounts.count, 8)
        let clip = strip.accountClipFrame
        let allMail = tileRect(try XCTUnwrap(strip.folderTiles.last), in: strip)
        XCTAssertGreaterThan(clip.minY, allMail.maxY, "the clip sits below the folders")
        XCTAssertEqual(clip.maxY, (try addRect(strip)).minY - Quire.Layout.Rail.stackBottomGap, accuracy: 0.5)
        XCTAssertNil(strip.clipEdges.top)
        XCTAssertNotNil(strip.clipEdges.bottom, "tiles hidden below: a hairline marks the clipped edge")

        // ⌘8 chooses the eighth account and scrolls its tile into view instantly.
        strip.selectShortcut(8)
        let eighth = try XCTUnwrap(strip.accountTileRects.last)
        XCTAssertTrue(clip.contains(eighth), "\(eighth) inside \(clip)")
        XCTAssertNotNil(strip.clipEdges.top, "scrolled: the top edge is clipped now")
        XCTAssertEqual(strip.scope, .account(AccountID("acct-extra-6")))
        // ↑ on the focused tile moves to the seventh, still in view.
        let seventh = try XCTUnwrap(strip.tile(for: .account(AccountID("acct-extra-5"))))
        let eighthTile = try XCTUnwrap(strip.tile(for: .account(AccountID("acct-extra-6"))))
        eighthTile.onArrow?(-1)
        XCTAssertEqual(strip.scope, .account(AccountID("acct-extra-5")))
        XCTAssertTrue(clip.contains(tileRect(seventh, in: strip)))
    }

    func testThePendingTileJoinsTheAnchoredStack() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        harness.controller.applySignIn(SignInProgress(kind: .gmail, reconnecting: nil, subject: "Gmail"))
        let strip = layOut(harness)
        XCTAssertTrue(strip.showsPendingTile)
        let rects = strip.accountTileRects
        XCTAssertEqual(rects.count, 3, "two accounts and the pending tile")
        XCTAssertEqual(try XCTUnwrap(rects.last).maxY, try addRect(strip).minY - 18, accuracy: 0.5, "the pending tile is last, above Add")
        harness.controller.applySignIn(nil)
    }
}
