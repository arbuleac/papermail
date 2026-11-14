import AppKit
import SwiftUI
import XCTest
@testable import SSDesign

/// The pointer over Settings' SwiftUI controls (spec §4.17). SwiftUI keeps the pointer it shows to itself, so these hold
/// each Quire style and control to the modifier that sets it, the modifier to the rule, and the inline link's box to the
/// link's own words.
@MainActor
final class PointerStyleTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        QuireTestEnvironment.forceDefaults()
    }

    override func tearDown() async throws {
        QuireTestEnvironment.reset()
        try await super.tearDown()
    }

    /// Every Quire style and control draws its face through `quirePointer`, or a field's through the I-beam's: a body
    /// that lost it would show the arrow over a control.
    func testEveryQuireStyleAndControlSetsThePointer() {
        let bodies: [(String, String)] = [
            ("button", body(of: QuireButtonChrome<Text>.self)),
            ("toggle", body(of: QuireToggleChrome<Text>.self)),
            ("checkbox and radio", body(of: QuireChoiceChrome<Text>.self)),
            ("theme tile", style(of: QuireThemeTileButton.self)),
            ("+/−", body(of: QuireJoinedButtonChrome<Text>.self)),
            ("rule list −", body(of: QuireRemoveButtonChrome<Text>.self)),
            ("banner dismiss", body(of: QuireBannerDismissChrome<Text>.self)),
            ("popup", body(of: QuirePopup<Int>.self)),
            ("account rows", body(of: QuireAccountGroup<EmptyView>.self)),
            ("inline link", body(of: QuireInlineLinkText.self)),
            ("field", modifier(of: QuireFieldStyle.self)),
            ("text area", modifier(of: QuireTextAreaStyle.self)),
        ]
        for (name, type) in bodies {
            XCTAssertTrue(type.contains("QuirePointerModifier"), "\(name): \(type.prefix(200))")
        }
    }

    /// The hand or the I-beam only while the control acts; otherwise no style of its own, so the arrow shows.
    func testThePointerShowsOnlyWhileTheControlActs() {
        XCTAssertNotNil(QuirePointerModifier.style(.link, shows: true))
        XCTAssertNotNil(QuirePointerModifier.style(.text, shows: true))
        XCTAssertNil(QuirePointerModifier.style(.link, shows: false))
        XCTAssertNil(QuirePointerModifier.style(.text, shows: false))
    }

    /// The inline link's box is its own words, read from the text's layout: after the words before it on one line, and
    /// one box per line when the link wraps.
    func testTheInlineLinksBoxesAreItsOwnWords() {
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        func width(_ text: String) -> CGFloat { NSAttributedString(string: text, attributes: [.font: font]).size().width }

        let one = LinkBoxRecorder()
        var host = SwiftUIHost(LinkBoxProbe(words: "Words before the", link: "link", width: 300, recorder: one))
        host.settle(0.2)
        XCTAssertEqual(one.boxes.count, 1)
        if let box = one.boxes.first {
            XCTAssertEqual(box.minX, width("Words before the "), accuracy: 3)
            XCTAssertEqual(box.width, width("link"), accuracy: 3)
        }
        host.close()

        let wrapped = LinkBoxRecorder()
        host = SwiftUIHost(LinkBoxProbe(words: "Words", link: "a link long enough to wrap onto the next line", width: 150, recorder: wrapped))
        host.settle(0.2)
        XCTAssertGreaterThanOrEqual(wrapped.boxes.count, 2, "\(wrapped.boxes)")
        XCTAssertEqual(Set(wrapped.boxes.map { $0.minY.rounded() }).count, wrapped.boxes.count, "one box per line")
        host.close()
    }

    /// A click on the link's words runs it, through the box laid over them (a synthetic click never reaches a link inside
    /// SwiftUI text, so only the box can answer it); a click on the words before it does not.
    func testAClickOnTheInlineLinkRunsItAndOneOnTheWordsDoesNot() {
        let recorder = FrameRecorder()
        let clicks = ClickLog()
        let view = QuireInlineLinkText("Words before the", link: (title: "link", action: { clicks.count += 1 }), role: .snippet,
                                       linkRole: .snippet)
            .frame(width: 300, alignment: .leading)
            .recordFrame("text", in: recorder)
        let host = SwiftUIHost(view)
        host.settle(0.2)
        let frame = recorder["text"]
        let words = QuireDraw.width(QuireDraw.line("Words before the ", .snippet, .black))
        let link = QuireDraw.width(QuireDraw.line("link", .snippet, .black))
        let y = frame.minY + frame.height / 2
        click(host, at: CGPoint(x: frame.minX + 10, y: y))
        XCTAssertEqual(clicks.count, 0, "the words are not the link")
        click(host, at: CGPoint(x: frame.minX + words + link / 2, y: y))
        XCTAssertEqual(clicks.count, 1)
        host.close()
    }

    // MARK: Helpers

    private func body<V: View>(of type: V.Type) -> String { String(reflecting: V.Body.self) }
    private func style<S: ButtonStyle>(of type: S.Type) -> String { String(reflecting: S.Body.self) }
    private func modifier<M: ViewModifier>(of type: M.Type) -> String { String(reflecting: M.Body.self) }

    private func click<Content: View>(_ host: SwiftUIHost<Content>, at point: CGPoint) {
        let location = host.hostingView.convert(NSPoint(x: point.x, y: point.y), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: 0,
                                                 windowNumber: host.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                                 pressure: 1) else { continue }
            host.window.sendEvent(event)
        }
        host.settle()
    }
}

@MainActor
private final class ClickLog {
    var count = 0
}

@MainActor
private final class LinkBoxRecorder {
    var boxes: [CGRect] = []
}

/// Words and a link marked as `QuireInlineLinkText` marks it, with the boxes its overlay would get recorded.
private struct LinkBoxProbe: View {
    let words: String
    let link: String
    let width: CGFloat
    let recorder: LinkBoxRecorder

    var body: some View {
        Text("\(Text(words)) \(Text(link).customAttribute(QuireInlineLinkMark()))")
            .frame(width: width, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .overlayPreferenceValue(Text.LayoutKey.self) { layouts in
                GeometryReader { proxy in
                    let boxes = QuireInlineLinkText.linkBoxes(layouts, in: proxy)
                    Color.clear.onAppear { recorder.boxes = boxes }
                }
            }
    }
}
