import AppKit
import XCTest
@testable import SSDesign

/// The paper faces (spec §5.55): the art as generated from tokens.json, its paths, the automatic face per ink slot, and the
/// renderer's cache, which every surface draws from in `draw(_:)`.
@MainActor
final class PaperFaceTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        QuireTestEnvironment.forceDefaults()
    }

    override func tearDown() async throws {
        QuireTestEnvironment.reset()
        try await super.tearDown()
    }

    private let box = Quire.Layout.PaperFaces.artBox

    // MARK: The art

    /// Every cut-out parses, draws something, and lies on the disc: a layer may run past the square (a shirt cut long
    /// at the bottom) but never wholly outside it.
    func testEveryPathParsesAndLiesOnTheDisc() throws {
        XCTAssertEqual(Quire.PaperFace.allCases.count, 12)
        for face in Quire.PaperFace.allCases {
            XCTAssertFalse(face.layers.isEmpty, face.rawValue)
            for (i, layer) in face.layers.enumerated() {
                let path = try QuireSVGPath.parse(layer.path)
                let bounds = path.boundingBoxOfPath
                XCTAssertGreaterThan(bounds.width * bounds.height, 0, "\(face.rawValue) layer \(i) draws nothing")
                XCTAssertTrue(bounds.intersects(CGRect(x: 0, y: 0, width: box, height: box)), "\(face.rawValue) layer \(i) is off the art")
                XCTAssertTrue(CGRect(x: -box / 4, y: -box / 4, width: box * 1.5, height: box * 1.5).contains(bounds),
                              "\(face.rawValue) layer \(i) runs far past the art: \(bounds)")
                XCTAssertTrue((0..<Quire.Layout.PaperFaces.shadowY.count).contains(layer.lift), "\(face.rawValue) layer \(i) lift")
            }
        }
    }

    /// The generated Swift is tokens.json's art exactly, and every paper a face names is a token of the palette, with no IC
    /// values of its own: the art keeps its papers under Increase Contrast.
    func testTheArtIsTokensJSONAndEveryFillIsAPaperToken() throws {
        let file = DesignTokensFile.shared
        let palette = try XCTUnwrap(file.array("paperPalette") as? [[String: String]])
        let names = palette.compactMap { $0["name"] }
        XCTAssertEqual(names, Quire.Paper.allCases.map(\.name))
        XCTAssertEqual(names.count, 15)
        for (paper, values) in zip(Quire.Paper.allCases, palette) {
            XCTAssertEqual(values["lightHC"], values["light"], paper.name)
            XCTAssertEqual(values["darkHC"], values["dark"], paper.name)
            XCTAssertEqual(String(format: "#%06X", paper.values.light >> 8), values["light"], paper.name)
            XCTAssertEqual(String(format: "#%06X", paper.values.dark >> 8), values["dark"], paper.name)
        }
        let faces = try XCTUnwrap(file.array("paperFaces") as? [[String: Any]])
        XCTAssertEqual(faces.compactMap { $0["id"] as? String }, Quire.PaperFace.allCases.map(\.rawValue), "the picker's order")
        for (face, json) in zip(Quire.PaperFace.allCases, faces) {
            XCTAssertEqual(json["name"] as? String, face.name)
            let ground = try XCTUnwrap(json["ground"] as? String)
            XCTAssertTrue(names.contains(ground), "\(face.rawValue): ground \(ground) is not a paper")
            XCTAssertEqual(ground, face.ground.name)
            let layers = try XCTUnwrap(json["layers"] as? [[String: Any]])
            XCTAssertEqual(layers.count, face.layers.count, face.rawValue)
            for (layer, l) in zip(face.layers, layers) {
                let paper = try XCTUnwrap(l["paper"] as? String)
                XCTAssertTrue(names.contains(paper), "\(face.rawValue): fill \(paper) is not a paper")
                XCTAssertEqual(paper, layer.paper.name)
                XCTAssertEqual(l["d"] as? String, layer.path)
                XCTAssertEqual(l["lift"] as? Int, layer.lift)
            }
        }
    }

    /// Faces read as people and animals, and VoiceOver names each in the picker.
    func testEveryFaceHasAName() {
        let names = Quire.PaperFace.allCases.map(\.name)
        XCTAssertEqual(Set(names).count, names.count)
        XCTAssertEqual(Quire.PaperFace.fox.name, "Fox")
        XCTAssertFalse(names.contains { $0.isEmpty })
    }

    /// Automatic faces go by ink slot, so the ten slots wear ten faces and any stored slot draws one.
    func testAutomaticFacesAreDistinctForEveryInkSlot() {
        let faces = (0..<Quire.AccountInk.allCases.count).map(Quire.PaperFace.automatic(forSlot:))
        XCTAssertEqual(Set(faces).count, faces.count)
        XCTAssertEqual(Quire.PaperFace.automatic(forSlot: 0), Quire.PaperFace.allCases[0])
        XCTAssertEqual(Quire.PaperFace.automatic(forSlot: 12), Quire.PaperFace.automatic(forSlot: 0))
        XCTAssertEqual(Quire.PaperFace.automatic(forSlot: -1), Quire.PaperFace.allCases.last)
    }

    // MARK: The renderer

    func testFacesAreCachedPerSizeScaleAndMode() throws {
        let renderer = QuireAvatarRenderer()
        XCTAssertEqual(renderer.paperFaceRenderCount, 0)
        let face = try XCTUnwrap(renderer.paperFace(.fox, diameter: 30, scale: 2, dark: false))
        XCTAssertEqual(face.width, 60, "30 pt at 2×")
        XCTAssertTrue(face === renderer.paperFace(.fox, diameter: 30, scale: 2, dark: false), "a cache hit")
        XCTAssertEqual(renderer.paperFaceRenderCount, 1, "drawn once")
        let dark = try XCTUnwrap(renderer.paperFace(.fox, diameter: 30, scale: 2, dark: true))
        XCTAssertFalse(face === dark)
        XCTAssertEqual(try XCTUnwrap(renderer.paperFace(.fox, diameter: 16, scale: 2, dark: false)).width, 32)
        XCTAssertEqual(try XCTUnwrap(renderer.paperFace(.fox, diameter: 30, scale: 1, dark: false)).width, 30)
        XCTAssertFalse(face === renderer.paperFace(.owl, diameter: 30, scale: 2, dark: false))
        XCTAssertEqual(renderer.paperFaceRenderCount, 5)
        renderer.removeAll()
        _ = renderer.paperFace(.fox, diameter: 30, scale: 2, dark: false)
        XCTAssertEqual(renderer.paperFaceRenderCount, 6, "a memory warning forgets them")
    }

    /// A face fills its disc with its ground, the papers follow Light and Dark, and the corners stay clear for the
    /// surface under it (the ring's gap shows that surface).
    func testAFaceIsItsGroundOnADiscWithClearCorners() throws {
        let renderer = QuireAvatarRenderer()
        var grounds = 0
        for dark in [false, true] {
            for face in Quire.PaperFace.allCases {
                let image = try XCTUnwrap(renderer.paperFace(face, diameter: 48, scale: 2, dark: dark))
                let rep = NSBitmapImageRep(cgImage: image)
                XCTAssertEqual(ComponentSnapshot.rgba(of: rep, x: 0, y: 0).a, 0, accuracy: 0.01, "\(face.rawValue): corners clear")
                XCTAssertEqual(ComponentSnapshot.rgba(of: rep, x: 95, y: 95).a, 0, accuracy: 0.01)
                XCTAssertEqual(ComponentSnapshot.rgba(of: rep, x: 48, y: 48).a, 1, accuracy: 0.01, "\(face.rawValue): an opaque disc")
                // Where no cut-out and no shadow reaches, the ground, exactly. A face cut edge to edge shows none.
                guard let point = groundPoint(face) else { continue }
                grounds += 1
                let pixel = ComponentSnapshot.rgba(of: rep, x: Int(point.x * 0.96), y: Int(point.y * 0.96))
                let v = dark ? face.ground.values.dark : face.ground.values.light
                let ground = RGBA(r: Double((v >> 24) & 0xFF) / 255, g: Double((v >> 16) & 0xFF) / 255, b: Double((v >> 8) & 0xFF) / 255, a: 1)
                XCTAssertEqual(pixel.r, ground.r, accuracy: 2 / 255, "\(face.rawValue) ground, dark \(dark)")
                XCTAssertEqual(pixel.g, ground.g, accuracy: 2 / 255, "\(face.rawValue) ground, dark \(dark)")
                XCTAssertEqual(pixel.b, ground.b, accuracy: 2 / 255, "\(face.rawValue) ground, dark \(dark)")
            }
        }
        XCTAssertGreaterThanOrEqual(grounds, 16, "most faces show their ground somewhere")
    }

    /// The face drawn in place comes from the cache: a view redrawn ten times at one size draws its bitmap ten times and
    /// renders it once, in its window's Light or Dark.
    func testDrawingInPlaceDrawsTheCachedImage() {
        let view = PaperFaceView(frame: NSRect(x: 0, y: 0, width: 40, height: 40))
        let before = QuireAvatarRenderer.shared.paperFaceRenderCount
        var snapshot = ComponentSnapshot.render(view, mode: .light, surface: .qSheet, scale: 2)
        let afterFirst = QuireAvatarRenderer.shared.paperFaceRenderCount
        // The window draws at its backing scale, the snapshot at 2×: one render each at most (another test may have made them).
        XCTAssertLessThanOrEqual(afterFirst - before, 2)
        for _ in 0..<10 { snapshot = ComponentSnapshot.render(view, mode: .light, surface: .qSheet, scale: 2) }
        XCTAssertEqual(QuireAvatarRenderer.shared.paperFaceRenderCount, afterFirst, "ten draws, no new render")
        XCTAssertGreaterThanOrEqual(view.draws, 11)
        // The frog's ground is rose: Light here, and the dark paper in Dark, the right way up in a flipped view.
        guard let art = groundPoint(.frog) else { return XCTFail("the frog shows its ground") }
        let ground = NSPoint(x: 5 + art.x * 0.3, y: 5 + art.y * 0.3)
        XCTAssertEqual(snapshot.hex(at: ground), "#EDAAA2")
        let dark = ComponentSnapshot.render(view, mode: .dark, surface: .qSheet, scale: 2)
        XCTAssertEqual(dark.hex(at: ground), "#AE807A")
        XCTAssertTrue(dark.matches(expected("sheet", mode: .dark), at: NSPoint(x: 5.5, y: 5.5)), "outside the disc, the surface")
        // Increase Contrast keeps the art.
        let ic = ComponentSnapshot.render(view, mode: .lightHC, surface: .qSheet, scale: 2)
        XCTAssertEqual(ic.hex(at: ground), "#EDAAA2")
        // The frog's eyes are near the top: the face is not drawn upside down.
        XCTAssertNotEqual(snapshot.hex(at: NSPoint(x: 20, y: 5 + 0.3 * 25)), snapshot.hex(at: NSPoint(x: 20, y: 5 + 0.3 * 95)))
    }

    /// A point of the art, in its units, that no layer's outline comes within 12 units of, so neither paper nor shadow
    /// reaches it, inside the disc.
    private func groundPoint(_ face: Quire.PaperFace) -> CGPoint? {
        let paths = face.layers.compactMap { try? QuireSVGPath.parse($0.path) }
        let grown = paths.map { $0.copy(strokingWithWidth: 24, lineCap: .round, lineJoin: .round, miterLimit: 4) }
        for y in stride(from: 10.0, through: 90.0, by: 2.0) {
            for x in stride(from: 10.0, through: 90.0, by: 2.0) {
                let p = CGPoint(x: x, y: y)
                guard hypot(x - 50, y - 50) < 44 else { continue }
                if paths.contains(where: { $0.contains(p, using: .winding) }) || grown.contains(where: { $0.contains(p) }) { continue }
                return p
            }
        }
        return nil
    }
}

/// Draws the frog, 30 pt, at (5, 5), in place, as a row or a tile does.
@MainActor
private final class PaperFaceView: NSView {
    var draws = 0
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        draws += 1
        QuireAvatarRenderer.drawPaperFace(.frog, in: NSRect(x: 5, y: 5, width: 30, height: 30))
    }
}
