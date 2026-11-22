import AppKit
import SwiftUI
import XCTest
@testable import PaperDesign

/// The paper faces in SwiftUI (spec §5.55): the Settings row's face, the face button and the face picker card.
@MainActor
final class FacePickerTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        QuireTestEnvironment.forceDefaults()
    }

    override func tearDown() async throws {
        QuireTestEnvironment.reset()
        try await super.tearDown()
    }

    private let p = Quire.Layout.PaperFaces.self

    // MARK: The row's face

    /// A paper face changes only the disc: the ring's outer band still runs from x = 12 to 14 and the gap from 14 to 16,
    /// showing the row's fill, as for a monogram (spec §5.40).
    func testAPaperFaceKeepsTheRowsRingAndGap() {
        let recorder = FrameRecorder()
        let content = QuireAccountRowContent(id: "contoso", name: "Contoso", tag: "Gmail", address: "a@contoso.test", monogram: "C",
                                             inkSlot: 0, face: .paper(.fox))
        let view = QuireAccountRow(content, isSelected: true)
            .recordFrame("row", in: recorder)
            .frame(width: 512)
            .environment(\.controlActiveState, .key)
        let host = SwiftUIHost(view)
        let rep = host.render()
        let row = recorder["row"]
        XCTAssertColor(rep.srgb(at: CGPoint(x: row.minX + 13, y: row.midY)), TokenResolver.resolve("account:Persimmon", .light), "the ring")
        XCTAssertColor(rep.srgb(at: CGPoint(x: row.minX + 15, y: row.midY)), TokenResolver.resolve("selWash", .light), "the gap")
        // Inside: the fox's paper, not the monogram's wash.
        var wash = TokenResolver.resolve("account:Persimmon", .light)
        wash.a = Double(Quire.Layout.Rail.faceAlpha)
        let monogramFace = ColorLib.over(wash, TokenResolver.resolve("sheet", .light))
        let inside = rep.srgb(at: CGPoint(x: row.minX + 16 + 15, y: row.midY + 8))
        XCTAssertGreaterThan(max(abs(inside.r - monogramFace.r), abs(inside.g - monogramFace.g), abs(inside.b - monogramFace.b)), 0.05)
        host.close()
    }

    /// The layout size is the face; the ring is drawn outside it, for a paper face as for a monogram.
    func testAPaperFacesLayoutSizeIsTheFace() {
        for diameter: CGFloat in [16, 24, 30, 48] {
            let host = SwiftUIHost(QuireAvatarView(account: .paper(.owl), ink: 3, diameter: diameter))
            XCTAssertEqual(host.hostingView.fittingSize, CGSize(width: diameter, height: diameter))
            host.close()
        }
    }

    // MARK: The face button

    /// Hover and pressed darken the disc only: the ring and the gap stay on the surface (spec §5.55, the rows' rule).
    func testTheFaceButtonDarkensOnlyTheFace() {
        func render(_ forced: QuireForcedStates) -> NSBitmapImageRep {
            let view = QuireFaceButtonFace(face: .monogram("C"), ink: 0, isPressed: false, isFocused: false)
                .quireForcedStates(forced)
                .padding(10)
                .background(.qCanvas)
            let host = SwiftUIHost(view)
            defer { host.close() }
            return host.render()
        }
        let rest = render([])
        let pressed = render(.pressed)
        let hovered = render(.hovered)
        let midY: CGFloat = 10 + 15
        let canvas = TokenResolver.resolve("canvas", .light)
        let ink = TokenResolver.resolve("account:Persimmon", .light)
        for rep in [rest, pressed, hovered] {
            XCTAssertColor(rep.srgb(at: CGPoint(x: 10 - 3, y: midY)), ink, "the ring")
            XCTAssertColor(rep.srgb(at: CGPoint(x: 10 - 1, y: midY)), canvas, "the gap: no wash under the ring")
        }
        var wash = TokenResolver.resolve("account:Persimmon", .light)
        wash.a = Double(Quire.Layout.Rail.faceAlpha)
        let face = ColorLib.over(wash, TokenResolver.resolve("sheet", .light))
        XCTAssertColor(rest.srgb(at: CGPoint(x: 14, y: midY)), face)
        XCTAssertColor(pressed.srgb(at: CGPoint(x: 14, y: midY)), ColorLib.over(TokenResolver.resolve("pressed", .light), face), "pressed")
        XCTAssertColor(hovered.srgb(at: CGPoint(x: 14, y: midY)), ColorLib.over(TokenResolver.resolve("hover", .light), face), "hover")
    }

    // MARK: The picker

    func testTheCardIsTwoRowsOfSeven() {
        XCTAssertEqual(QuireFacePicker.size.width, 7 * p.pickerCell + 6 * p.pickerGap + 2 * p.pickerPad)
        XCTAssertEqual(QuireFacePicker.size.height, 2 * p.pickerCell + p.pickerGap + 2 * p.pickerPad)
        XCTAssertLessThanOrEqual(QuireFacePicker.size.width, Quire.Layout.Settings.width - 2 * Quire.Layout.Settings.padX,
                                 "it fits inside the Settings tab")
    }

    /// VoiceOver reads a radio group of thirteen, in the grid's order, each tile by its name, the chosen one selected.
    func testVoiceOverReadsARadioGroupOfThirteen() {
        let radios = QuireFacePicker.radios(monogram: "Dg", chosen: .paper(.fox))
        XCTAssertEqual(radios.count, 13)
        XCTAssertEqual(radios.map(\.name), Quire.PaperFace.allCases.map(\.name) + ["Monogram"])
        XCTAssertEqual(radios[7].spoken, "Fox, 8 of 13, selected")
        XCTAssertEqual(radios[0].spoken, "Person with curly hair, 1 of 13")
        XCTAssertEqual(radios.filter(\.isSelected).count, 1)
        let monogram = QuireFacePicker.radios(monogram: "Dg", chosen: .monogram("Xy"))
        XCTAssertEqual(monogram.last?.spoken, "Monogram, 13 of 13, selected", "a monogram is the Monogram tile whatever its letters")
        XCTAssertEqual(monogram.last?.face, .monogram("Dg"), "the tile shows the account's letters")
    }

    /// ← → step along, ↑ ↓ move a row, clamped; down from a column the last row lacks lands on the last tile.
    func testArrowKeysStepThroughTheGrid() {
        func step(_ i: Int, _ move: MoveCommandDirection) -> Int { QuireFacePicker.step(from: i, by: move, count: 13, columns: 7) }
        XCTAssertEqual(step(0, .left), 0)
        XCTAssertEqual(step(0, .right), 1)
        XCTAssertEqual(step(6, .right), 7, "on into the next row")
        XCTAssertEqual(step(12, .right), 12)
        XCTAssertEqual(step(2, .down), 9)
        XCTAssertEqual(step(9, .up), 2)
        XCTAssertEqual(step(1, .up), 1)
        XCTAssertEqual(step(6, .down), 12, "the last row has no seventh tile")
        XCTAssertEqual(step(12, .down), 12)
    }

    /// The chosen tile wears the account's ring; the others none.
    func testOnlyTheChosenTileWearsTheRing() {
        let view = QuireFacePicker(monogram: "C", ink: 0, chosen: .paper(.fox), onPick: { _ in }, onClose: {})
            .padding(20)
            .background(.qCanvas)
        let host = SwiftUIHost(view)
        let rep = host.render()
        defer { host.close() }
        let ink = TokenResolver.resolve("account:Persimmon", .light)
        let raised = TokenResolver.resolve("raised", .light)
        func centre(_ index: Int) -> CGPoint {
            let column = CGFloat(index % 7), row = CGFloat(index / 7)
            return CGPoint(x: 20 + p.pickerPad + column * (p.pickerCell + p.pickerGap) + p.pickerCell / 2,
                           y: 20 + p.pickerPad + row * (p.pickerCell + p.pickerGap) + p.pickerCell / 2)
        }
        let ringOffset = p.pickerFace / 2 + Quire.Border.AccountRing.gap + Quire.Border.AccountRing.width / 2
        let fox = centre(Quire.PaperFace.allCases.firstIndex(of: .fox)!)
        XCTAssertColor(rep.srgb(at: CGPoint(x: fox.x - ringOffset, y: fox.y)), ink, "the chosen tile's ring")
        let owl = centre(Quire.PaperFace.allCases.firstIndex(of: .owl)!)
        XCTAssertColor(rep.srgb(at: CGPoint(x: owl.x - ringOffset, y: owl.y)), raised, "no ring on the others: the card")
        XCTAssertColor(rep.srgb(at: CGPoint(x: 20 + 4, y: 20 + 4)), raised, "the card is raised")
    }

    /// The card's Increase Contrast outline follows the Quire override, as every Quire control does, not only the system's
    /// setting, so an off-screen render asked for in Increase Contrast draws it.
    func testTheCardsOutlineFollowsTheIncreaseContrastOverride() {
        func edge(increaseContrast: Bool) -> RGBA {
            QuireEnvironment.shared.setOverrides(.init(isGraphite: false, increaseContrast: increaseContrast, reduceMotion: false,
                                                       reduceTransparency: false, theme: .study))
            let view = QuireFacePicker(monogram: "C", ink: 0, chosen: .paper(.fox), onPick: { _ in }, onClose: {})
                .padding(20)
                .background(.qCanvas)
            let host = SwiftUIHost(view)
            defer { host.close() }
            // The outline is 1 pt inside the card's edge, at mid height, clear of the rounded corners.
            return host.render().srgb(at: CGPoint(x: 20 + 0.5, y: 20 + QuireFacePicker.size.height / 2))
        }
        XCTAssertColor(edge(increaseContrast: true), TokenResolver.resolve("ruleStrong", .lightHC), "the IC outline")
        XCTAssertColor(edge(increaseContrast: false), TokenResolver.resolve("raised", .light), "no outline otherwise")
    }

    /// An arrow key moves the focus ring, not the selection, so VoiceOver is told the tile it reaches, by name and place;
    /// a key at the grid's edge moves nothing and says nothing.
    func testAnArrowKeyAnnouncesTheTileItReaches() throws {
        var heard: [String] = []
        let speak = QuireFacePicker.announce
        QuireFacePicker.announce = { heard.append($0) }
        defer { QuireFacePicker.announce = speak }
        var closes = 0
        let host = SwiftUIHost(QuireFacePicker(monogram: "C", ink: 0, chosen: .paper(.fox), onPick: { _ in }, onClose: { closes += 1 }))
        defer { host.close() }
        host.window.makeKey()
        host.settle(0.2)
        func send(_ characters: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags = []) {
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: host.window.windowNumber,
                                             context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false,
                                             keyCode: keyCode)!
                host.window.sendEvent(event)
            }
            host.settle()
        }
        func arrow(_ scalar: Int, _ keyCode: UInt16) {
            send(String(UnicodeScalar(scalar)!), keyCode: keyCode, modifiers: [.function, .numericPad])
        }
        let faces = Quire.PaperFace.allCases
        let fox = try XCTUnwrap(faces.firstIndex(of: .fox))
        arrow(NSRightArrowFunctionKey, 124)
        XCTAssertEqual(heard, ["\(faces[fox + 1].name), \(fox + 2) of 13"])
        arrow(NSLeftArrowFunctionKey, 123)
        XCTAssertEqual(heard.last, "Fox, \(fox + 1) of 13, selected", "the chosen tile says so")
        arrow(NSUpArrowFunctionKey, 126)
        XCTAssertEqual(heard.last, "\(faces[fox - 7].name), \(fox - 6) of 13")
        let count = heard.count
        arrow(NSUpArrowFunctionKey, 126)
        XCTAssertEqual(heard.count, count, "the top row: nowhere to go, nothing said")
        XCTAssertEqual(closes, 0)
    }

    /// Tab and Shift-Tab stay in the card, as in a popover's window, even with a field beside it that Tab would reach.
    /// With Full Keyboard Access off, as on a Mac whose settings a test must not change, SwiftUI keeps Tab on the grid
    /// anyway; the card's Tab handler is what holds it there with Full Keyboard Access on, and focus leaving regardless
    /// closes the card (`testFocusLeavingTheCardClosesIt`).
    func testTabStaysInTheCard() throws {
        var heard: [String] = []
        let speak = QuireFacePicker.announce
        QuireFacePicker.announce = { heard.append($0) }
        defer { QuireFacePicker.announce = speak }
        var leaves = 0
        let view = VStack {
            TextField("Signature", text: .constant(""))
            QuireFacePicker(monogram: "C", ink: 0, chosen: .paper(.fox), onPick: { _ in }, onClose: { leaves += 1 }, onLeave: { leaves += 1 })
        }
        let host = SwiftUIHost(view)
        defer { host.close() }
        host.window.makeKey()
        host.settle(0.3)
        func send(_ characters: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags = []) {
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: host.window.windowNumber,
                                             context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false,
                                             keyCode: keyCode)!
                host.window.sendEvent(event)
            }
            host.settle()
        }
        send("\t", keyCode: 48)
        send("\u{19}", keyCode: 48, modifiers: .shift)
        XCTAssertEqual(leaves, 0, "focus never left the card")
        XCTAssertFalse(host.window.firstResponder is NSText, "the field beside it did not take focus")
        send(String(UnicodeScalar(NSRightArrowFunctionKey)!), keyCode: 124, modifiers: [.function, .numericPad])
        XCTAssertEqual(heard.count, 1, "the grid still has the keys")
    }

    /// Focus leaving the card without Esc or a pick (VoiceOver, another control) closes it through `onLeave`, so nothing
    /// keeps focus under a card that covers it.
    func testFocusLeavingTheCardClosesIt() {
        var closes = 0, leaves = 0
        let host = SwiftUIHost(QuireFacePicker(monogram: "C", ink: 0, chosen: .paper(.fox), onPick: { _ in }, onClose: { closes += 1 },
                                               onLeave: { leaves += 1 }))
        defer { host.close() }
        host.window.makeKey()
        host.settle(0.2)
        XCTAssertEqual(leaves, 0, "taking focus as it opens is not leaving")
        host.window.makeFirstResponder(nil)
        host.settle()
        XCTAssertEqual(leaves, 1)
        XCTAssertEqual(closes, 0, "not Esc: the caller leaves focus where it went")
    }

    // MARK: The face button

    /// VoiceOver reads the face button as a pop-up button reads its choice: “Face, Fox, button”, the hint naming the account.
    func testTheFaceButtonReadsItsFace() {
        XCTAssertEqual(QuireFacePicker.name(of: .paper(.fox)), "Fox")
        XCTAssertEqual(QuireFacePicker.name(of: .monogram("Dg")), "Monogram")
        XCTAssertEqual(QuireFaceButton.hint(accountName: "Demo Gmail"), "Choose a face for Demo Gmail")
    }

    /// Picking the chosen tile changes nothing; another tile is picked.
    func testPickingTheChosenTileOnlyCloses() {
        var picked: [QuireAccountFace] = []
        var closes = 0
        let picker = QuireFacePicker(monogram: "C", ink: 0, chosen: .paper(.fox), onPick: { picked.append($0) }, onClose: { closes += 1 })
        let host = SwiftUIHost(picker)
        defer { host.close() }
        let p = self.p
        // A click on the owl, then on the fox, through the window, as a person would.
        func click(_ index: Int) {
            let column = CGFloat(index % 7), row = CGFloat(index / 7)
            let x = p.pickerPad + column * (p.pickerCell + p.pickerGap) + p.pickerCell / 2
            let yFromTop = p.pickerPad + row * (p.pickerCell + p.pickerGap) + p.pickerCell / 2
            let y = host.hostingView.isFlipped ? yFromTop : host.hostingView.bounds.height - yFromTop
            let point = host.hostingView.convert(NSPoint(x: x, y: y), to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: host.window.windowNumber,
                                               context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
                host.window.sendEvent(event)
            }
            host.settle()
        }
        click(Quire.PaperFace.allCases.firstIndex(of: .owl)!)
        XCTAssertEqual(picked, [.paper(.owl)])
        click(Quire.PaperFace.allCases.firstIndex(of: .fox)!)
        XCTAssertEqual(picked, [.paper(.owl)], "the chosen one changes nothing")
        XCTAssertEqual(closes, 1, "it only closes")
        click(12)
        XCTAssertEqual(picked, [.paper(.owl), .monogram("C")])
    }
}
