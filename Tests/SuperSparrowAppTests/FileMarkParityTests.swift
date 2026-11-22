import AppKit
import SSCore
import SSDesign
import WebKit
import XCTest
@testable import SuperSparrowApp

/// The reader's file mark is AppKit's (spec §5.57): the shell draws it as inline SVG from `SS_FILE_MARK` and AppKit draws
/// `QuireFileMark` from the same tokens, and at 2x the two agree pixel for pixel (exactly, on macOS 27). Gated
/// behind `SS_UI_TESTS=1`, as every WebKit render is: it needs a window-server session.
@MainActor
final class FileMarkParityTests: XCTestCase {
    private var folder: URL!
    private var engine: MailEngine?

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SS_UI_TESTS"] == "1", "WebKit renders run with SS_UI_TESTS=1")
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("FileMarkParity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let engine {
            var stopped = false
            Task { await engine.stopAndWait(); stopped = true }
            ListTestSupport.spin(until: { stopped }, timeout: 5)
        }
        if let folder { try? FileManager.default.removeItem(at: folder) }
    }

    func testTheReadersMarkIsAppKitsMarkAtTwoX() throws {
        let account = ListTestSupport.accountA
        let conversation = ConversationID(accountID: account.id, providerID: "thread-files")
        let message = MessageID(accountID: account.id, providerID: "msg-files")
        let names = ["plan.pdf", "Q4.xlsx", "launch-deck.pptx", "press-kit.zip", "hero.heic", "review.ics", "odd.wmwm", "Makefile"]
        let files = names.enumerated().map { AttachmentInfo(id: "f\($0.offset)", filename: $0.element, mimeType: "", sizeBytes: 1_000, isInline: false) }
        let store = InMemoryMailStore()
        try store.upsertAccount(account)
        try store.upsertMessages([MessageMetadata(
            id: message, conversationID: conversation, subject: "Files", snippet: "Files",
            from: EmailAddress(name: "Ada Lovelace", address: "ada@example.com"), to: [EmailAddress(address: account.email)],
            date: Date(), roles: [.inbox], isRead: true, isStarred: false, hasAttachments: true
        )])
        try store.saveBody(StoredBody(body: MessageBody(html: "<p>Files.</p>", text: "Files.", attachments: files),
                                      renderedHTML: "<p>Files.</p>", plainText: "Files."), for: message)
        let provider = QueuedServerProvider(accountID: account.id, kind: account.kind, latency: 0, serverConcurrency: 1)
        let engine = MailEngine(store: store, tokenStore: InMemoryTokenStore(), tokenProvider: DemoTokenProvider(),
                                authenticator: DemoAuthenticator(), sanitizer: HTMLSanitizer(), providerFactory: { _ in provider },
                                attachmentCacheDirectory: folder.appendingPathComponent("attachments", isDirectory: true))
        self.engine = engine
        let reader = ConversationViewController(client: engine)
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 900, height: 900), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = reader.view
        reader.show(conversation)
        let slot = try XCTUnwrap(reader.pool.current)
        XCTAssertNotNil(ListTestSupport.spin(until: { slot.isReady && slot.pendingRender == nil && !slot.renderInFlight && slot.renderedID == conversation },
                                             timeout: 10))
        let webView = slot.webView
        ListTestSupport.spin(until: { false }, timeout: 0.5)
        for mode in [QuireMode.light, .dark] {
            window.appearance = mode.appearance
            ListTestSupport.spin(until: { false }, timeout: 0.5)
            try assertParity(in: webView, mode: mode, count: names.count)
        }
    }

    private func assertParity(in webView: WKWebView, mode: QuireMode, count: Int) throws {
        let marks = try XCTUnwrap(evaluate("""
            Array.from(document.querySelectorAll('.ss-chip .ss-fm')).map(function (m) {
              var r = m.getBoundingClientRect(), t = m.querySelector('.ss-fm-label');
              return [r.left, r.top, r.width, m.getAttribute('data-family'), t ? t.textContent : ''];
            })
            """, in: webView) as? [[Any]])
        XCTAssertEqual(marks.count, count)
        for mark in marks {
            let left = try XCTUnwrap(mark[0] as? Double), top = try XCTUnwrap(mark[1] as? Double)
            let family = try XCTUnwrap(mark[3] as? String), label = try XCTUnwrap(mark[4] as? String)
            XCTAssertEqual(mark[2] as? Double, 28)
            let web = try XCTUnwrap(snapshot(webView, rect: NSRect(x: left, y: top, width: 28, height: 28)))
            let ink = try XCTUnwrap(Quire.FileInk(rawValue: family))
            let appKit = try XCTUnwrap(QuireOffscreenRenderer.render(mode: mode, scale: 2) { ChipPatch(QuireFileMark(ink: ink, label: label)) })
            let diff = compare(srgb(web), srgb(appKit))
            // `SS_PARITY_DUMP=<folder>` writes both renders, to look at a failure.
            if let dir = ProcessInfo.processInfo.environment["SS_PARITY_DUMP"] {
                for (name, bytes) in [("web", srgb(web)), ("appkit", srgb(appKit))] {
                    var copy = bytes
                    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 56, pixelsHigh: 56, bitsPerSample: 8, samplesPerPixel: 4,
                                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 224, bitsPerPixel: 32)!
                    copy.withUnsafeMutableBytes { memcpy(rep.bitmapData!, $0.baseAddress!, 56 * 56 * 4) }
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/\(family)-\(mode)-\(name).png"))
                }
            }
            // Identical on macOS 27; the slack is for a WebKit that antialiases its text a shade differently.
            XCTAssertLessThan(diff.mean, 1.5, "\(mode) \(family) \(label): mean channel difference \(diff.mean)")
            XCTAssertLessThan(diff.far, 20, "\(mode) \(family) \(label): \(diff.far) of 3136 pixels differ by more than 64")
        }
    }

    // MARK: Pixels

    /// The web view's pixels under `rect` at 2x, whatever the screen's scale.
    private func snapshot(_ webView: WKWebView, rect: NSRect) -> CGImage? {
        let configuration = WKSnapshotConfiguration()
        configuration.rect = rect
        configuration.snapshotWidth = NSNumber(value: Double(rect.width * 2 / (webView.window?.backingScaleFactor ?? 1)))
        var result: CGImage?
        var done = false
        webView.takeSnapshot(with: configuration) { image, _ in
            result = image?.cgImage(forProposedRect: nil, context: nil, hints: nil)
            done = true
        }
        ListTestSupport.spin(until: { done }, timeout: 5)
        return result
    }

    /// 56 x 56 sRGB bytes, colour managed from whatever space the image is in.
    private func srgb(_ image: CGImage) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 56 * 56 * 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: &bytes, width: 56, height: 56, bitsPerComponent: 8, bytesPerRow: 56 * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return bytes }
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: 56, height: 56))
        return bytes
    }

    private func srgb(_ rep: NSBitmapImageRep) -> [UInt8] {
        rep.cgImage.map(srgb) ?? []
    }

    private func compare(_ a: [UInt8], _ b: [UInt8]) -> (mean: Double, far: Int) {
        guard a.count == b.count, !a.isEmpty else { return (255, 3136) }
        var sum = 0, far = 0
        for pixel in stride(from: 0, to: a.count, by: 4) {
            var worst = 0
            for c in 0..<3 {
                let d = abs(Int(a[pixel + c]) - Int(b[pixel + c]))
                sum += d
                worst = max(worst, d)
            }
            if worst > 64 { far += 1 }
        }
        return (Double(sum) / Double(a.count / 4 * 3), far)
    }

    private func evaluate(_ script: String, in webView: WKWebView) -> Any? {
        var result: Any?
        var done = false
        webView.evaluateJavaScript(script) { value, _ in
            result = value
            done = true
        }
        ListTestSupport.spin(until: { done }, timeout: 5)
        return result
    }
}

/// The mark on the chip's own fill, as the reader draws it.
private final class ChipPatch: NSView {
    private let mark: QuireFileMark

    init(_ mark: QuireFileMark) {
        self.mark = mark
        super.init(frame: NSRect(x: 0, y: 0, width: 28, height: 28))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("built in code") }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.qSheet.setFill()
        bounds.fill()
        mark.draw(in: bounds)
    }
}
