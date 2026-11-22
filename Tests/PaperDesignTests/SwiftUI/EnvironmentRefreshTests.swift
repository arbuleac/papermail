import AppKit
import SwiftUI
import XCTest
@testable import PaperDesign

/// `QuireEnvironmentRefresh`: a Graphite switch reaches SwiftUI faces drawn before it.
@MainActor
final class EnvironmentRefreshTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        QuireTestEnvironment.forceDefaults()
    }

    override func tearDown() async throws {
        QuireTestEnvironment.reset()
        try await super.tearDown()
    }

    private func face(refreshing: Bool) -> some View {
        Group {
            if refreshing {
                Button {} label: { Color.clear.frame(width: 40, height: 10) }
                    .buttonStyle(.quire(.primary))
                    .quireRefreshesOnEnvironmentChange()
            } else {
                Button {} label: { Color.clear.frame(width: 40, height: 10) }
                    .buttonStyle(.quire(.primary))
            }
        }
        .environment(\.controlActiveState, .key)
        .padding(8)
        .background(Color.qCanvas)
    }

    func testGraphiteSwitchRedrawsTheTree() {
        let host = SwiftUIHost(face(refreshing: true))
        let point = CGPoint(x: 8 + 6, y: 8 + 14)
        XCTAssertColor(host.render().srgb(at: point), TokenResolver.resolve("accentFill", .light))
        QuireEnvironment.shared.setOverrides(.pinned(.light, graphite: true))
        XCTAssertColor(host.render(settle: 0.1).srgb(at: point), TokenResolver.resolve("ink", .light), "accentFill → ink under Graphite")
        QuireEnvironment.shared.setOverrides(.pinned(.light, graphite: false))
        XCTAssertColor(host.render(settle: 0.1).srgb(at: point), TokenResolver.resolve("accentFill", .light), "and back")
        host.close()
    }
}
