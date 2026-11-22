import AppKit
import PaperCore
import XCTest
@testable import PaperApp

/// Renders a composer holding the demo's sample (spec §5.20, Images in the body; §5.43): a line of text, the sunset as
/// if pasted, the caret after it, and a second composer with the picture selected, in light and dark, for looking at:
/// `composer-image-light.png`, `composer-image-selected-dark.png` and their siblings, written to `PAPER_RENDER_DIR` (the
/// temporary folder when unset). The same sample is what `--snapshot-compose` writes in its reply. Opt-in, because it
/// writes files: `PAPER_UI_TESTS=1 PAPER_RENDER_DIR=<dir> swift test --filter ComposerInlineImageRenderTests`. The windows run
/// over a throwaway store; drafts go to a temporary folder.
@MainActor
final class ComposerInlineImageRenderTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        guard ProcessInfo.processInfo.environment["PAPER_UI_TESTS"] == "1" else {
            throw XCTSkip("set PAPER_UI_TESTS=1 to render a composer with a picture")
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ComposerImageRender-\(UUID().uuidString)")
        self.folder = folder
        MainActor.assumeIsolated { ComposeDraftStore.shared.useDirectory(folder) }
    }

    override func tearDown() {
        MainActor.assumeIsolated {
            for composer in ComposeWindowRegistry.shared.openControllers { composer.closeWithoutSaving() }
            ComposeDraftStore.shared.waitForWrites()
            ComposeDraftStore.shared.useDemoDirectory(false)
        }
        if let folder { try? FileManager.default.removeItem(at: folder) }
        super.tearDown()
    }

    func testRenderTheDemoSample() throws {
        let output = ProcessInfo.processInfo.environment["PAPER_RENDER_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let harness = try MainWindowHarness()
        defer { harness.close() }
        for (name, look) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
            for selected in [false, true] {
                harness.controller.composeNew()
                let composer = try XCTUnwrap(ComposeWindowRegistry.shared.openControllers.last)
                let window = try XCTUnwrap(composer.window)
                window.appearance = NSAppearance(named: look)
                window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
                composer.writeDemoSample()
                if selected {
                    let index = (composer.bodyEditor.string as NSString).range(of: "\u{FFFC}").location
                    composer.bodyEditor.setSelectedRange(NSRange(location: index, length: 1))
                }
                ListTestSupport.spin(for: 0.3)
                window.contentView?.layoutSubtreeIfNeeded()
                let view = try XCTUnwrap(window.contentView?.superview ?? window.contentView)
                let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: bitmap)
                let file = output.appendingPathComponent("composer-image\(selected ? "-selected" : "")-\(name).png")
                XCTAssertTrue(SnapshotRenderer.writePNG(bitmap, to: file.path))
                composer.closeWithoutSaving()
            }
        }
    }
}
