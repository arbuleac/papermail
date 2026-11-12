import AppKit
import SSCore
import WebKit
import XCTest
@testable import SuperSparrowApp

/// Renders the demo's invitations in the real reader, the message folded under the card and unfolded, in light and dark
/// (spec §5.14, §5.15), for looking at: `invitation-<name>-folded-light.png` and its siblings, written to `SS_RENDER_DIR`
/// (the temporary folder when unset). Opt-in, because it writes files:
/// `SS_UI_TESTS=1 SS_RENDER_DIR=<dir> swift test --filter ReaderInvitationRenderTests`. The demo runs over a throwaway
/// store in a temporary folder; nothing reaches the network, the Keychain or the user's mail.
@MainActor
final class ReaderInvitationRenderTests: XCTestCase {
    private var folder: URL!
    private var environment: AppEnvironment?

    override func setUpWithError() throws {
        guard ProcessInfo.processInfo.environment["SS_UI_TESTS"] == "1" else {
            throw XCTSkip("set SS_UI_TESTS=1 to render the invitation's fold")
        }
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("ReaderInvitationRender-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        if let environment {
            var finished = false
            Task { @MainActor in
                await environment.shutdown()
                finished = true
            }
            ListTestSupport.spin(until: { finished }, timeout: 5)
        }
        if let folder { try? FileManager.default.removeItem(at: folder) }
    }

    func testRenderTheDemoInvitationsFoldedAndUnfolded() throws {
        let output = ProcessInfo.processInfo.environment["SS_RENDER_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let environment = try AppEnvironment.makeScratch(in: folder, mode: .demo)
        self.environment = environment
        environment.start()
        let store = environment.store
        var inbox: [ConversationSummary] = []
        XCTAssertTrue(ListTestSupport.spin(until: {
            inbox = (try? store.conversations(ConversationQuery(view: .inbox))) ?? []
            return inbox.contains { $0.subject.contains("Sam's birthday dinner") } && inbox.contains { $0.subject == "Design critique" }
        }, timeout: 30), "the demo mailboxes are in")
        let shown: [(name: String, subject: String)] = [("dinner", "Invitation: Sam's birthday dinner"), ("critique", "Design critique")]

        for appearance in [(name: "light", look: NSAppearance.Name.aqua), (name: "dark", look: NSAppearance.Name.darkAqua)] {
            let reader = ConversationViewController(client: environment.engine)
            let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 840, height: 900),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: appearance.look)
            window.contentViewController = reader
            window.setContentSize(NSSize(width: 840, height: 900))
            window.orderFrontRegardless()
            defer { window.orderOut(nil) }

            for item in shown {
                let id = try XCTUnwrap(inbox.first { $0.subject == item.subject }?.id, item.subject)
                reader.show(id)
                XCTAssertTrue(ListTestSupport.spin(until: {
                    guard let slot = reader.pool.current, slot.isReady, slot.renderedID == id, !slot.renderInFlight else { return false }
                    return self.evaluate("!!document.querySelector('.ss-card.ss-mfolded') && window.ss.measureAll().every(function (h) { return h > 0; })",
                                         in: slot.webView) == "true"
                }, timeout: 15), "\(item.name): the body came in and folded under its card")
                // Inline glyphs, fonts and the sheet's fit settle after the render lands.
                ListTestSupport.spin(for: 1)
                try write(reader, to: output.appendingPathComponent("invitation-\(item.name)-folded-\(appearance.name).png"))

                let webView = try XCTUnwrap(reader.pool.current?.webView)
                _ = evaluate("document.querySelector('.ss-card.ss-mfold .ss-mrow .ss-elide').click()", in: webView)
                XCTAssertTrue(ListTestSupport.spin(until: {
                    self.evaluate("document.querySelector('.ss-card.ss-mfold').classList.contains('ss-mfolded')", in: webView) == "false"
                }, timeout: 5))
                // A window off screen runs no CSS transitions, so the sheet's growth is finished as the app finishes
                // motion before a key acts (spec §4.10).
                _ = evaluate("window.ss.finishAll()", in: webView)
                ListTestSupport.spin(for: 1)
                try write(reader, to: output.appendingPathComponent("invitation-\(item.name)-unfolded-\(appearance.name).png"))
            }
        }
    }

    // MARK: Helpers

    private func evaluate(_ script: String, in webView: WKWebView) -> String {
        var answer: String?
        webView.evaluateJavaScript("(function () { var v = (\(script)); return v === null || v === undefined ? '' : String(v); })()") { value, _ in
            answer = value as? String ?? ""
        }
        ListTestSupport.spin(until: { answer != nil }, timeout: 5)
        return answer ?? ""
    }

    /// The reader as the app's `--snapshot` draws it: `cacheDisplay` cannot draw WKWebView content, so the web view's own
    /// image goes over its frame, and what the reader draws above the web view (the quick reply) goes back on top.
    private func write(_ reader: ConversationViewController, to url: URL) throws {
        let view = reader.view
        let webView = try XCTUnwrap(reader.pool.current?.webView)
        var image: NSImage?
        webView.takeSnapshot(with: nil) { snapshot, _ in image = snapshot ?? NSImage() }
        XCTAssertTrue(ListTestSupport.spin(until: { image != nil }, timeout: 10), "the web view's snapshot")
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
        var frame = webView.convert(webView.bounds, to: view)
        if view.isFlipped { frame.origin.y = view.bounds.height - frame.maxY }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        image?.draw(in: frame, from: .zero, operation: .sourceOver, fraction: 1)
        ReaderSnapshotOverlay.draw(over: webView, in: view)
        NSGraphicsContext.restoreGraphicsState()
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: url)
    }
}
