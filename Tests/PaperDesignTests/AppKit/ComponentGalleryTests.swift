import AppKit
import XCTest
@testable import PaperDesign

/// Writes the component gallery in all four modes as PNGs, for looking at. Runs only when
/// `QUIRE_GALLERY_OUT` names a directory:
/// `QUIRE_GALLERY_OUT=/tmp/gallery swift test --filter ComponentGalleryTests`.
@MainActor
final class ComponentGalleryTests: XCTestCase {
    override func tearDown() async throws {
        QuireTestEnvironment.reset()
        try await super.tearDown()
    }

    func testWriteGallery() throws {
        guard let out = ProcessInfo.processInfo.environment["QUIRE_GALLERY_OUT"], !out.isEmpty else {
            throw XCTSkip("Set QUIRE_GALLERY_OUT to a directory to write the gallery PNGs.")
        }
        let directory = URL(fileURLWithPath: out, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let scale = Double(ProcessInfo.processInfo.environment["QUIRE_GALLERY_SCALE"] ?? "").map { CGFloat($0) }
        for mode in QuireMode.allCases {
            let gallery = ComponentGallery.make()
            let snapshot = ComponentSnapshot.render(gallery, mode: mode, scale: scale)
            try snapshot.write(to: directory.appendingPathComponent("gallery-\(mode.rawValue).png"))
        }
        // Graphite takes the colour out of every accent-family token (§3.1).
        for mode in [QuireMode.light, .dark] {
            let gallery = ComponentGallery.make()
            let snapshot = ComponentSnapshot.render(gallery, mode: mode, scale: scale, graphite: true)
            try snapshot.write(to: directory.appendingPathComponent("gallery-graphite-\(mode.rawValue).png"))
        }
    }
}
