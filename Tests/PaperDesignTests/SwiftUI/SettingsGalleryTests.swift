import AppKit
import SwiftUI
import XCTest
@testable import PaperDesign

/// Renders the SwiftUI gallery in all four modes. Set `QUIRE_GALLERY_DIR` to an absolute directory to write
/// the renders as `settings-gallery-<mode>.png` for a visual check.
@MainActor
final class SettingsGalleryTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        QuireTestEnvironment.forceDefaults()
    }

    override func tearDown() async throws {
        QuireTestEnvironment.reset()
        try await super.tearDown()
    }

    func testGalleryRendersInEveryMode() throws {
        let directory = ProcessInfo.processInfo.environment["QUIRE_GALLERY_DIR"]
        for mode in QuireMode.allCases {
            QuireEnvironment.shared.setOverrides(.init(isGraphite: false, increaseContrast: mode.isIncreasedContrast,
                                                       reduceMotion: false, reduceTransparency: false))
            let host = SwiftUIHost(QuireSettingsGallery(), mode: mode)
            // Long enough for the loading cells' spinners to pass their 150 ms delay.
            let rep = host.render(settle: 0.3)
            XCTAssertGreaterThan(rep.size.width, Quire.Layout.Settings.width, "the gallery lays out at its natural width")
            // The sheet's own background is the Settings canvas in this mode.
            XCTAssertColor(rep.srgb(at: CGPoint(x: 2, y: 2)), TokenResolver.resolve("canvas", mode), "\(mode)")
            if let directory {
                try rep.writePNG(to: "\(directory)/settings-gallery-\(mode.rawValue).png")
            }
            host.close()
        }
    }

    /// The Graphite substitution (spec §3.1) in light and dark: every accent-family face goes neutral.
    func testGalleryRendersUnderGraphite() throws {
        let directory = ProcessInfo.processInfo.environment["QUIRE_GALLERY_DIR"]
        for mode in [QuireMode.light, .dark] {
            QuireEnvironment.shared.setOverrides(.pinned(mode, graphite: true))
            let host = SwiftUIHost(QuireSettingsGallery(), mode: mode)
            let rep = host.render(settle: 0.3)
            XCTAssertColor(rep.srgb(at: CGPoint(x: 2, y: 2)), TokenResolver.resolve("canvas", mode), "\(mode)")
            if let directory {
                try rep.writePNG(to: "\(directory)/settings-gallery-\(mode.rawValue)-graphite.png")
            }
            host.close()
        }
    }
}
