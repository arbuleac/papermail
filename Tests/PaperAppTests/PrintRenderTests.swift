import AppKit
import PDFKit
import PaperCore
import WebKit
import XCTest
@testable import PaperApp

/// Prints demo conversations through the real reader and print operation (spec §5.48), for looking at:
/// `print-<name>.pdf` and the first page as `print-<name>.png`, written to `PAPER_RENDER_DIR` (the temporary folder when
/// unset). The window is dark, so the files also show that the paper is light whatever the app shows. Opt-in, because it
/// writes files: `PAPER_UI_TESTS=1 PAPER_RENDER_DIR=<dir> swift test --filter PrintRenderTests`. The demo runs over a throwaway
/// store in a temporary folder; its remote images stay held back, so nothing reaches the network, the Keychain or the
/// user's mail.
@MainActor
final class PrintRenderTests: XCTestCase {
    private var folder: URL!
    private var environment: AppEnvironment?

    override func setUpWithError() throws {
        guard ProcessInfo.processInfo.environment["PAPER_UI_TESTS"] == "1" else {
            throw XCTSkip("set PAPER_UI_TESTS=1 to print the demo's conversations")
        }
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("PrintRender-\(UUID().uuidString)")
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

    func testPrintTheDemosConversations() throws {
        let output = ProcessInfo.processInfo.environment["PAPER_RENDER_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        XCTAssertFalse(ConversationViewController.loadRemoteImages, "the demo's newsletter images stay held back: no network")
        let environment = try AppEnvironment.makeScratch(in: folder, mode: .demo)
        self.environment = environment
        environment.start()
        let store = environment.store
        var all: [ConversationSummary] = []
        XCTAssertTrue(ListTestSupport.spin(until: {
            all = (try? store.conversations(ConversationQuery(view: .all, limit: 500))) ?? []
            return all.contains { $0.subject == "Design critique" } && all.contains { $0.subject == "Photos from the offsite" }
        }, timeout: 30), "the demo mailboxes are in")
        let newsletter = all.first { summary in
            ((try? store.messages(in: summary.id)) ?? []).contains { $0.listUnsubscribe != nil }
        }
        let shown: [(name: String, id: ConversationID?)] = [
            ("thread", all.first { $0.subject == "Lisbon in March?" }?.id),
            ("photos", all.first { $0.subject == "Photos from the offsite" }?.id),
            ("newsletter", newsletter?.id),
            ("invitation", all.first { $0.subject == "Design critique" }?.id),
        ]

        let reader = ConversationViewController(client: environment.engine)
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 840, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentViewController = reader
        window.setContentSize(NSSize(width: 840, height: 900))
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }

        for item in shown {
            let id = try XCTUnwrap(item.id, item.name)
            reader.show(id)
            XCTAssertTrue(ListTestSupport.spin(until: {
                guard let slot = reader.pool.current, slot.isReady, slot.renderedID == id, !slot.renderInFlight else { return false }
                return reader.currentMessages.allSatisfy { (try? store.body(for: $0.id)) != nil }
            }, timeout: 15), "\(item.name): rendered with its bodies")
            ListTestSupport.spin(for: 0.5)

            let url = output.appendingPathComponent("print-\(item.name).pdf")
            try? FileManager.default.removeItem(at: url)
            reader.printer.destination = .file(url)
            var finished: Bool?
            reader.printer.onFinish = { finished = $0 }
            reader.printConversation(nil)
            XCTAssertTrue(ListTestSupport.spin(until: { finished != nil }, timeout: 20), "\(item.name): printed")
            XCTAssertEqual(finished, true)
            let pdf = try XCTUnwrap(PDFDocument(url: url), item.name)
            let page = try XCTUnwrap(pdf.page(at: 0))
            let image = page.thumbnail(of: NSSize(width: 1224, height: 1584), for: .mediaBox)
            let png = try XCTUnwrap(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:))?.representation(using: .png, properties: [:]))
            try png.write(to: output.appendingPathComponent("print-\(item.name).png"))
        }
    }
}
