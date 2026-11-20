import AppKit
import SSCore
@testable import SSDesign
import SwiftUI
import XCTest
@testable import SuperSparrowApp

/// Paper faces across the app (Quire §5.55): the choice resolved for every surface, each surface drawing it, the
/// Settings picker writing it through the store to every window, and VoiceOver naming the account, never the face. Every
/// window is a throwaway store's; nothing touches the app's own store or defaults.
@MainActor
final class AccountFaceSurfaceTests: XCTestCase {
    private let a = ListTestSupport.accountA
    private let b = ListTestSupport.accountB

    // MARK: Resolving the choice

    func testTheChoiceResolvesForEverySurface() {
        var account = a
        XCTAssertEqual(AccountFaces.face(for: account, monogram: "C"), .paper(.automatic(forSlot: 0)), "automatic: by ink slot")
        account.inkSlot = 7
        XCTAssertEqual(AccountFaces.face(for: account, monogram: "C"), .paper(.fox), "slot 7 wears the eighth face")
        account.face = .monogram
        XCTAssertEqual(AccountFaces.face(for: account, monogram: "C"), .monogram("C"))
        account.face = .paper("owl")
        XCTAssertEqual(AccountFaces.face(for: account, monogram: "C"), .paper(.owl))
        account.face = .paper("retired-face")
        XCTAssertEqual(AccountFaces.face(for: account, monogram: "C"), .paper(.fox), "art no longer drawn is automatic")
        XCTAssertEqual(AccountFaces.choice(.paper(.owl)), .paper("owl"))
        XCTAssertEqual(AccountFaces.choice(.monogram("C")), .monogram)
        let faces = AccountFaces.faces(for: [a, b])
        XCTAssertNotEqual(faces[a.id], faces[b.id], "two inks, two faces")
    }

    // MARK: The main window

    /// The rail wears the faces, changes with the store at once, and names the account to VoiceOver.
    func testTheRailWearsTheFaceAndFollowsTheStore() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let strip = harness.controller.strip
        let tile = try XCTUnwrap(strip.tile(for: .account(a.id)))
        XCTAssertEqual(tile.content, .account(face: .paper(.automatic(forSlot: a.inkSlot)), slot: a.inkSlot))
        XCTAssertEqual(tile.accessibilityLabel(), "Contoso, \(a.email)", "the account, never the face's name")

        try harness.environment.store.setFace(.paper("frog"), for: a.id)
        harness.controller.refreshAccounts()
        XCTAssertEqual(tile.content, .account(face: .paper(.frog), slot: a.inkSlot))
        try harness.environment.store.setFace(.monogram, for: b.id)
        harness.controller.refreshAccounts()
        let other = try XCTUnwrap(strip.tile(for: .account(b.id)))
        guard case .account(.monogram, _)? = Optional(other.content) else { return XCTFail("monogram: \(other.content)") }
    }

    /// The title menu's account items, as the menu builds them: on a 2× screen a paper face is the rail's art at 12 pt and a
    /// monogram its first letter; on a 1× screen, where 12 pixels of art are a blob, the paper face gives way to the
    /// monogram's first letter too (§5.55). The item is named by the account; its image says nothing of its own.
    func testTheTitleMenuDrawsTheFacesItsScreenCanShow() throws {
        var monogramAccount = b
        monogramAccount.face = .monogram
        let model = TitleMenu.Model(view: .inbox, inboxUnread: 0, scope: .unified, showsAccounts: true, unifiedUnread: 0, accounts: [
            TitleMenu.AccountEntry(account: a, face: .paper(.frog), monogram: "Co", unread: 0),
            TitleMenu.AccountEntry(account: monogramAccount, face: .monogram("Fa"), monogram: "Fa", unread: 0),
        ])
        let menu = TitleMenu.build(model, target: self, viewAction: #selector(NSResponder.noResponder(for:)),
                                   scopeAction: #selector(NSResponder.noResponder(for:)))
        let paperItem = try XCTUnwrap(menu.items.first { $0.title.hasPrefix(AccountLabels.name(for: a)) })
        let monogramItem = try XCTUnwrap(menu.items.first { $0.title.hasPrefix(AccountLabels.name(for: b)) })
        let paperImage = try XCTUnwrap(paperItem.image)
        let monogramImage = try XCTUnwrap(monogramItem.image)
        XCTAssertEqual(paperImage.size, NSSize(width: 18, height: 18))
        XCTAssertNil(paperImage.accessibilityDescription, "the item's title names the account; the face adds nothing")

        func render(_ image: NSImage, scale: CGFloat) throws -> NSBitmapImageRep {
            // Tagged sRGB, the faces' own space, so their pixels arrive unconverted.
            let blank = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(18 * scale), pixelsHigh: Int(18 * scale),
                                                       bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                       colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0))
            let rep = try XCTUnwrap(blank.retagging(with: .sRGB))
            rep.size = NSSize(width: 18, height: 18)
            let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: rep))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance {
                image.draw(in: NSRect(x: 0, y: 0, width: 18, height: 18))
            }
            NSGraphicsContext.restoreGraphicsState()
            return rep
        }
        func centre(_ rep: NSBitmapImageRep) -> NSColor {
            rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2)!.usingColorSpace(.sRGB)!
        }
        func close(_ x: NSColor, _ y: NSColor) -> Bool {
            abs(x.redComponent - y.redComponent) < 0.04 && abs(x.greenComponent - y.greenComponent) < 0.04
                && abs(x.blueComponent - y.blueComponent) < 0.04
        }
        // The face sits inside the ring's 1.5 pt and a 1.25 pt gap, as drawn.
        let diameter = 18 - 2 * (Quire.Border.AccountRing.width / 2 + 0.5 + 1.5)
        let frog = NSBitmapImageRep(cgImage: try XCTUnwrap(QuireAvatarRenderer.shared.paperFace(.frog, diameter: diameter, scale: 2, dark: false)))
        let frogCentre = try XCTUnwrap(frog.colorAt(x: frog.pixelsWide / 2, y: frog.pixelsHigh / 2)?.usingColorSpace(.sRGB))

        // A fresh image per scale: an NSImage keeps what its handler drew for a resolution.
        let paper2x = try render(TitleMenu.faceImage(.paper(.frog), monogram: "Co", slot: a.inkSlot), scale: 2)
        XCTAssertTrue(close(centre(paper2x), frogCentre), "2×: the frog, \(centre(paper2x)) against \(frogCentre)")
        let monogram2x = try render(monogramImage, scale: 2)
        XCTAssertFalse(close(centre(monogram2x), frogCentre), "a monogram account keeps its letter")

        let paper1x = try render(TitleMenu.faceImage(.paper(.frog), monogram: "Co", slot: a.inkSlot), scale: 1)
        let letter1x = try render(TitleMenu.faceImage(.monogram("C"), monogram: "Co", slot: a.inkSlot), scale: 1)
        XCTAssertEqual(paper1x.representation(using: .png, properties: [:]), letter1x.representation(using: .png, properties: [:]),
                       "1×: the monogram's first letter in the frog's place")
        let frog1x = NSBitmapImageRep(cgImage: try XCTUnwrap(QuireAvatarRenderer.shared.paperFace(.frog, diameter: diameter, scale: 1, dark: false)))
        XCTAssertFalse(close(centre(paper1x), try XCTUnwrap(frog1x.colorAt(x: frog1x.pixelsWide / 2, y: frog1x.pixelsHigh / 2)?.usingColorSpace(.sRGB))),
                       "not the frog")
    }

    /// The account ring and its gap are exactly as around a monogram: only the disc inside them changes.
    func testTheRailTileKeepsItsRingAndGap() throws {
        func render(_ face: QuireAccountFace) throws -> (NSBitmapImageRep, NSRect, CGFloat) {
            let tile = AccountStripButton(content: .account(face: face, slot: 0))
            let window = NSWindow(contentRect: tile.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .aqua)
            window.contentView = tile
            defer { window.close() }
            let rep = try XCTUnwrap(tile.bitmapImageRepForCachingDisplay(in: tile.bounds))
            tile.cacheDisplay(in: tile.bounds, to: rep)
            return (rep, tile.accountFace, CGFloat(rep.pixelsWide) / tile.bounds.width)
        }
        let (paper, face, scale) = try render(.paper(.owl))
        let (monogram, _, _) = try render(.monogram("C"))
        func pixel(_ rep: NSBitmapImageRep, _ x: CGFloat, _ y: CGFloat) -> NSColor {
            rep.colorAt(x: Int(x * scale), y: Int(y * scale))!.usingColorSpace(.sRGB)!
        }
        // The ring (2–4 pt outside the face), the gap (0–2 pt), on the four sides of the face.
        for (dx, dy) in [(-3.0, 0.0), (-1.0, 0.0), (0.0, -3.0), (0.0, -1.0)] {
            let x = dx == 0 ? face.midX : face.minX + CGFloat(dx)
            let y = dy == 0 ? face.midY : face.minY + CGFloat(dy)
            XCTAssertEqual(pixel(paper, x, y), pixel(monogram, x, y), "at \(dx), \(dy) from the face")
        }
        XCTAssertNotEqual(pixel(paper, face.midX, face.midY), pixel(monogram, face.midX, face.midY), "the disc is the owl")
        XCTAssertEqual(pixel(paper, face.midX, face.midY).alphaComponent, 1, accuracy: 0.01, "an opaque disc")
    }

    /// The list's account tile shows the account's face, drawn from the cache: rows redrawn render nothing new.
    func testTheListsAccountTileDrawsTheCachedFace() throws {
        let store = try ListTestSupport.store(threads: 6)
        let (list, window) = ListTestSupport.host(store: store, settings: ListTestSupport.settings(density: .compact, faces: true))
        defer { window.close() }
        window.displayIfNeeded()
        let renders = QuireAvatarRenderer.shared.paperFaceRenderCount
        for _ in 0..<5 {
            list.view.needsDisplay = true
            for case let cell as ConversationCellView in list.tableView.subviews.flatMap(\.subviews) { cell.needsDisplay = true }
            window.displayIfNeeded()
        }
        XCTAssertEqual(QuireAvatarRenderer.shared.paperFaceRenderCount, renders, "redrawn rows draw the cached faces")

        let row = try XCTUnwrap(list.layout.row(ofConversation: 0))
        let cell = try XCTUnwrap(list.tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? ConversationCellView)
        let account = list.conversations[0].id.accountID
        let tileRegion = try XCTUnwrap(cell.toolTipRegions().first { $0.text.contains("@") && $0.rect.minX > cell.bounds.width / 2 })
        let tileCentre = NSPoint(x: tileRegion.rect.midX, y: tileRegion.rect.midY)
        let rep = try XCTUnwrap(cell.bitmapImageRepForCachingDisplay(in: cell.bounds))
        cell.cacheDisplay(in: cell.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / cell.bounds.width
        let drawn = try XCTUnwrap(rep.colorAt(x: Int(tileCentre.x * scale), y: Int(tileCentre.y * scale))?.usingColorSpace(.sRGB))
        let slot = account == a.id ? a.inkSlot : b.inkSlot
        let face = try XCTUnwrap(QuireAvatarRenderer.shared.paperFace(.automatic(forSlot: slot), diameter: Quire.Layout.Row.accountTile,
                                                                      scale: scale, dark: false))
        let facePixels = NSBitmapImageRep(cgImage: face)
        let expected = try XCTUnwrap(facePixels.colorAt(x: facePixels.pixelsWide / 2, y: facePixels.pixelsHigh / 2)?.usingColorSpace(.sRGB))
        XCTAssertEqual(drawn.redComponent, expected.redComponent, accuracy: 0.04, "the tile's centre is the face's centre")
        XCTAssertEqual(drawn.greenComponent, expected.greenComponent, accuracy: 0.04)
        XCTAssertEqual(drawn.blueComponent, expected.blueComponent, accuracy: 0.04)
    }

    /// The quick reply wears the replying account's face.
    func testTheQuickReplyWearsTheRepliersFace() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        harness.selectFirst(1)
        let bar = harness.reader.quickReplyBar
        harness.spin(until: { bar.face != nil })
        let conversation = harness.list.conversations[0]
        let account = conversation.id.accountID == a.id ? a : b
        XCTAssertEqual(bar.face?.face, .paper(.automatic(forSlot: account.inkSlot)))
        XCTAssertEqual(bar.face?.inkSlot, account.inkSlot)
    }

    // MARK: Settings

    /// The Face row keeps the Monogram row's height: the detail form is as tall as before, with or without the field.
    func testTheFaceRowKeepsTheFormsHeight() throws {
        let (controller, _) = try settingsWindow()
        defer { controller.tearDown() }
        let s = Quire.Layout.Settings.self
        let expected = 4 * s.detailRow + (s.detailRow + (s.signatureFieldHeight - s.fieldHeight))
        for face in [AccountFace.automatic, .monogram, .paper("owl")] {
            var account = a
            account.face = face
            let form = NSHostingView(rootView: AccountDetailForm(model: controller.model, account: account))
            XCTAssertEqual(form.fittingSize.height, expected, accuracy: 2, "\(face)")
        }
    }

    /// A click on the face opens the picker over the tab; a click on a tile writes the choice to the store, every window
    /// takes it, and the picker closes. Esc closes without a change; ← and Return pick from the keyboard.
    func testThePickerWritesThroughTheStoreToEveryWindow() throws {
        let (controller, environment) = try settingsWindow()
        defer { controller.tearDown() }
        let window = try XCTUnwrap(controller.window)
        let tabs = try XCTUnwrap(window.contentViewController as? NSTabViewController)
        let tab = try XCTUnwrap(tabs.tabViewItems[0].viewController?.view)
        let model = controller.model
        var refreshes = 0
        model.setFace = { face, account in
            // What the app delegate does (`edit`): the store, then every window re-reads its accounts.
            try? environment.store.setFace(face, for: account.id)
            controller.refreshAccounts()
            refreshes += 1
        }
        model.selection = a.id.rawValue
        ListTestSupport.spin(for: 0.2)

        let button = try XCTUnwrap(faceButton(in: tab), "the face button is a Tab stop, 30 pt")
        click(NSPoint(x: button.midX, y: button.midY), in: tab)
        XCTAssertTrue(ListTestSupport.spin(until: { model.showsFacePicker }, timeout: 2), "a click opens the picker")
        XCTAssertEqual(tab.fittingSize.height, tab.frame.height, accuracy: 1, "the card moves nothing: the tab keeps its height")

        // Esc closes it without a change.
        sendKey("\u{1b}", keyCode: 53, to: window)
        XCTAssertTrue(ListTestSupport.spin(until: { !model.showsFacePicker }, timeout: 2), "Esc closes")
        XCTAssertEqual(refreshes, 0)

        // Open again and click the owl.
        click(NSPoint(x: button.midX, y: button.midY), in: tab)
        XCTAssertTrue(ListTestSupport.spin(until: { model.showsFacePicker }, timeout: 2))
        let card = AccountsSettingsView.facePickerFrame(button: button, container: tab.bounds.size)
        click(tileCentre(Quire.PaperFace.allCases.firstIndex(of: .owl)!, in: card), in: tab)
        XCTAssertTrue(ListTestSupport.spin(until: { !model.showsFacePicker }, timeout: 2), "a pick closes the picker")
        XCTAssertEqual(try environment.store.accounts().first { $0.id == a.id }?.face, .paper("owl"))
        XCTAssertEqual(model.rows.first { $0.id == a.id.rawValue }?.face, .paper(.owl), "the row shows it at once")

        // From the keyboard: the grid takes focus on the chosen tile (the owl); → then Return picks the rabbit.
        click(NSPoint(x: button.midX, y: button.midY), in: tab)
        XCTAssertTrue(ListTestSupport.spin(until: { model.showsFacePicker }, timeout: 2))
        ListTestSupport.spin(for: 0.2)
        sendKey(String(UnicodeScalar(NSRightArrowFunctionKey)!), keyCode: 124, modifiers: [.function, .numericPad], to: window)
        sendKey("\r", keyCode: 36, to: window)
        XCTAssertTrue(ListTestSupport.spin(until: { !model.showsFacePicker }, timeout: 2))
        XCTAssertEqual(try environment.store.accounts().first { $0.id == a.id }?.face, .paper("rabbit"))
        XCTAssertEqual(refreshes, 2)
    }

    /// The card belongs to the Accounts tab it opened over: another tab, or closing the window, closes it, so it is never
    /// found open, without focus, on the way back (§5.55).
    func testLeavingTheTabOrClosingTheWindowClosesThePicker() throws {
        let (controller, _) = try settingsWindow()
        defer { controller.tearDown() }
        let window = try XCTUnwrap(controller.window)
        let tab = try XCTUnwrap((window.contentViewController as? NSTabViewController)?.tabViewItems[0].viewController?.view)
        let model = controller.model
        model.selection = a.id.rawValue
        ListTestSupport.spin(for: 0.2)
        let button = try XCTUnwrap(faceButton(in: tab))
        click(NSPoint(x: button.midX, y: button.midY), in: tab)
        XCTAssertTrue(ListTestSupport.spin(until: { model.showsFacePicker }, timeout: 2))
        model.tab = .general
        XCTAssertFalse(model.showsFacePicker, "another tab closes it")
        model.tab = .accounts
        ListTestSupport.spin(for: 0.2)
        XCTAssertFalse(model.showsFacePicker, "and it is not open on the way back")

        click(NSPoint(x: button.midX, y: button.midY), in: tab)
        XCTAssertTrue(ListTestSupport.spin(until: { model.showsFacePicker }, timeout: 2))
        window.performClose(nil)
        XCTAssertFalse(model.showsFacePicker, "closing the window closes it")
        controller.show(tab: .accounts)
        ListTestSupport.spin(for: 0.2)
        XCTAssertFalse(model.showsFacePicker, "reopened, Settings shows no card")
    }

    /// Space and Return on the focused face button open the card, as a click does, and only open it: one press never opens
    /// and closes it at once. Tab and Shift-Tab then stay in the card, where Esc still closes it.
    func testTheFaceButtonOpensFromTheKeyboardAndTabStaysInTheCard() throws {
        let (controller, _) = try settingsWindow()
        defer { controller.tearDown() }
        let window = try XCTUnwrap(controller.window)
        let tab = try XCTUnwrap((window.contentViewController as? NSTabViewController)?.tabViewItems[0].viewController?.view)
        let model = controller.model
        model.selection = a.id.rawValue
        ListTestSupport.spin(for: 0.2)
        let button = try XCTUnwrap(faceButton(in: tab))
        // The click focuses the button; Esc closes the card and gives focus back to it, as the user would get it there.
        click(NSPoint(x: button.midX, y: button.midY), in: tab)
        XCTAssertTrue(ListTestSupport.spin(until: { model.showsFacePicker }, timeout: 2))
        ListTestSupport.spin(for: 0.2)
        sendKey("\u{1b}", keyCode: 53, to: window)
        XCTAssertTrue(ListTestSupport.spin(until: { !model.showsFacePicker }, timeout: 2))
        ListTestSupport.spin(for: 0.2)

        sendKey(" ", keyCode: 49, to: window)
        XCTAssertTrue(ListTestSupport.spin(until: { model.showsFacePicker }, timeout: 2), "Space opens it")
        ListTestSupport.spin(for: 0.3)
        XCTAssertTrue(model.showsFacePicker, "and leaves it open")
        sendKey("\t", keyCode: 48, to: window)
        sendKey("\u{19}", keyCode: 48, modifiers: .shift, to: window)
        XCTAssertTrue(model.showsFacePicker, "Tab and Shift-Tab stay in the card")
        sendKey("\u{1b}", keyCode: 53, to: window)
        XCTAssertTrue(ListTestSupport.spin(until: { !model.showsFacePicker }, timeout: 2), "Esc still reaches it")
        ListTestSupport.spin(for: 0.2)

        sendKey("\r", keyCode: 36, to: window)
        XCTAssertTrue(ListTestSupport.spin(until: { model.showsFacePicker }, timeout: 2), "Return opens it")
        ListTestSupport.spin(for: 0.3)
        XCTAssertTrue(model.showsFacePicker, "and leaves it open")
    }

    /// Choosing Monogram brings the field beside the face; the store keeps the choice.
    func testMonogramBringsItsFieldBack() throws {
        let (controller, environment) = try settingsWindow()
        defer { controller.tearDown() }
        let window = try XCTUnwrap(controller.window)
        let tab = try XCTUnwrap((window.contentViewController as? NSTabViewController)?.tabViewItems[0].viewController?.view)
        controller.model.setFace = { face, account in
            try? environment.store.setFace(face, for: account.id)
            controller.refreshAccounts()
        }
        controller.model.selection = a.id.rawValue
        ListTestSupport.spin(for: 0.2)
        let fieldsBefore = textFields(in: tab).count
        let button = try XCTUnwrap(faceButton(in: tab))
        click(NSPoint(x: button.midX, y: button.midY), in: tab)
        XCTAssertTrue(ListTestSupport.spin(until: { controller.model.showsFacePicker }, timeout: 2))
        let card = AccountsSettingsView.facePickerFrame(button: button, container: tab.bounds.size)
        click(tileCentre(12, in: card), in: tab)
        XCTAssertTrue(ListTestSupport.spin(until: { !controller.model.showsFacePicker }, timeout: 2))
        XCTAssertEqual(try environment.store.accounts().first { $0.id == a.id }?.face, .monogram)
        XCTAssertTrue(ListTestSupport.spin(until: { self.textFields(in: tab).count == fieldsBefore + 1 }, timeout: 2),
                      "the monogram field stands beside the face")
    }

    /// The card goes under the button when there is room, over it when not, and never past the tab's edges.
    func testTheCardIsPlacedInsideTheTab() {
        let p = Quire.Layout.PaperFaces.self
        let size = QuireFacePicker.size
        let button = CGRect(x: 180, y: 200, width: 30, height: 30)
        let below = AccountsSettingsView.facePickerFrame(button: button, container: CGSize(width: 560, height: 600))
        XCTAssertEqual(below.minY, button.maxY + 4 + p.pickerOffset)
        XCTAssertGreaterThanOrEqual(below.minX, p.pickerEdgeMin)
        XCTAssertLessThanOrEqual(below.maxX, 560 - p.pickerEdgeMin)
        let above = AccountsSettingsView.facePickerFrame(button: button, container: CGSize(width: 560, height: 300))
        XCTAssertEqual(above.maxY, button.minY - 4 - p.pickerOffset)
        let tight = AccountsSettingsView.facePickerFrame(button: CGRect(x: 180, y: 100, width: 30, height: 30),
                                                         container: CGSize(width: 560, height: 200))
        XCTAssertGreaterThanOrEqual(tight.minY, p.pickerEdgeMin)
        XCTAssertEqual(tight.size, size)
    }

    // MARK: Helpers

    private func settingsWindow() throws -> (SettingsWindowController, AppEnvironment) {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AccountFaceSurfaceTests-\(UUID().uuidString)")
        let environment = try AppEnvironment.makeScratch(in: directory)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        try environment.store.upsertAccount(a)
        try environment.store.upsertAccount(b)
        let controller = SettingsWindowController(environment: environment, settings: ListTestSupport.settings(), mailtoHandler: FakeMailtoHandler(),
                                                  loginItem: FakeLoginItem())
        let window = try XCTUnwrap(controller.window)
        window.setFrameAutosaveName("")
        window.appearance = NSAppearance(named: .aqua)
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        controller.show(tab: .accounts)
        controller.refreshAccounts()
        let tab = try XCTUnwrap((window.contentViewController as? NSTabViewController)?.tabViewItems[0].viewController?.view)
        XCTAssertTrue(ListTestSupport.spin(until: { self.faceButton(in: tab) != nil }, timeout: 3), "the tab is laid out")
        ListTestSupport.spin(for: 0.1)
        return (controller, environment)
    }

    /// The face button's key-view proxy: SwiftUI frames one as each focusable control, and the face button's is its 30 pt face.
    private func faceButton(in view: NSView) -> CGRect? {
        let face = Quire.Layout.Settings.accountFace
        return view.subviews
            .filter { String(describing: type(of: $0)).hasSuffix("KeyViewProxy") }
            .map(\.frame)
            .first { abs($0.width - face) < 0.5 && abs($0.height - face) < 0.5 }
    }

    private func textFields(in view: NSView) -> [NSView] {
        var out: [NSView] = []
        func walk(_ v: NSView) {
            if v is NSTextField { out.append(v) }
            v.subviews.forEach(walk)
        }
        walk(view)
        return out
    }

    /// The centre of tile `index` in a card at `card`, in the tab's (flipped) coordinates.
    private func tileCentre(_ index: Int, in card: CGRect) -> NSPoint {
        let p = Quire.Layout.PaperFaces.self
        let columns = Int(p.pickerColumns)
        let column = CGFloat(index % columns), row = CGFloat(index / columns)
        return NSPoint(x: card.minX + p.pickerPad + column * (p.pickerCell + p.pickerGap) + p.pickerCell / 2,
                       y: card.minY + p.pickerPad + row * (p.pickerCell + p.pickerGap) + p.pickerCell / 2)
    }

    /// A click as the user makes one; `point` is in `view`'s own coordinates.
    private func click(_ point: NSPoint, in view: NSView) {
        guard let window = view.window else { return XCTFail("no window") }
        let location = view.convert(point, to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                 windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
            else { return XCTFail("no event") }
            window.sendEvent(event)
        }
        ListTestSupport.spin(for: 0.15)
    }

    private func sendKey(_ characters: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags = [], to window: NSWindow) {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: window.windowNumber,
                                               context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false,
                                               keyCode: keyCode)
            else { return XCTFail("no event") }
            window.sendEvent(event)
        }
        ListTestSupport.spin(for: 0.15)
    }
}
