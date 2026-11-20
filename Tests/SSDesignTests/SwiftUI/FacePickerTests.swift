import AppKit
import SwiftUI
import XCTest
@testable import SSDesign

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
