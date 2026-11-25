import AppKit
import PaperCore
import WebKit
import XCTest
@testable import PaperApp

/// Where a real click on a link or a button in received mail goes ("some buttons do not open in the browser", 2026-11-25).
/// Each pattern is raw mail HTML, sanitized as sync stores it and shown in the real reader (its pooled web views, its shell,
/// its sandboxed body frames and its navigation policy), then clicked the way a user clicks: the pointer moved over the
/// element's on-screen point (found from the shell, whose body frames are same-origin), then a left mouse down and up in
/// window coordinates, through `window.sendEvent` while the window is key, else to the view the window hit-tests (the test
/// process is seldom the active app, and a window that is not key takes a plain click as the one that makes it key). The
/// policy's `openExternally` records instead of opening, so nothing reaches the browser or the network; a proxy in front of
/// the policy records every question WebKit asks it. A script's `element.click()` runs after each real click, to compare.
///
/// Every test prints one `LINKCLICK` line per probe: the pattern, what a browser would open, what the click opened, what
/// `element.click()` opened, what the body's document hit there, and what WebKit asked the policy (`new` is a request for a
/// new window, `main` one for the shell's own frame, `frame` one for the body's). `PAPER_LINK_STRICT=1` asserts that every
/// probe not marked `knownGap` opens what a browser would; `PAPER_LINK_ONLY="name|name"` runs only the patterns whose names
/// contain one of those; `PAPER_LINK_SANDBOX` gives the body frames another `sandbox` in the tests that otherwise run the
/// shell as shipped. The `…WithSandbox…` and `…TargetsRemoved…` tests rerun the corpus with the shell changed at run time, to
/// see which patterns a candidate fix fixes; they run only with `PAPER_LINK_VARIANTS=1`. All of it is gated behind
/// `PAPER_UI_TESTS=1`, as every WebKit render is.
///
/// Found 2026-11-25, shell as shipped (`sandbox="allow-same-origin"`): a link with any `target` but `_self` (`_blank`,
/// `_top`, `_parent`, a name), and every `mailto:` and `tel:` link, does nothing, real click or script, and WebKit asks the
/// policy nothing. `allow-popups` alone makes every one of them reach the policy and open once.
@MainActor
final class ReaderLinkClickTests: XCTestCase {
    // MARK: Corpus

    struct Probe: Sendable {
        enum Spot: Sendable {
            /// The middle of the element's box.
            case center
            /// `dx`, `dy` points in from the box's top left: the padding of a cell or a padded link.
            case inset(CGFloat, CGFloat)
            /// The middle of an `<area>`'s rectangle on its image (`coords` "x1,y1,x2,y2"), found through its map.
            case area(image: String)
        }

        var label: String
        /// In the body's document, after the sanitizer prefixed ids (`id="p"` is `#ss-p`).
        var selector: String
        var spot: Spot = .center
        /// What a browser would open for this click; nil when it would open nothing.
        var expected: String?
        var modifiers: NSEvent.ModifierFlags = []
        /// Why the app as designed differs from a browser here (the sanitizer removed or rejected it); strict mode skips it.
        var knownGap: String?
    }

    struct Pattern: Sendable {
        var name: String
        var html: String
        var probes: [Probe]
        /// Show the message's quoted text first (its own toggle).
        var showsQuotes = false
    }

    struct Outcome {
        var pattern: String
        var probe: String
        var expected: String?
        var knownGap: String?
        var click: String
        var script: String
        var asked: [String]
        var hit: String

        var clickOK: Bool { click == (expected ?? "nothing") }
        var scriptOK: Bool { script == (expected ?? "nothing") }
    }

    /// A data: picture, so nothing in the corpus reaches the network.
    nonisolated static let picture = "data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7"
    nonisolated static let longTracking = "https://click.mailer.example/ls/click?upn=" + String(repeating: "u001.Zm9vYmFyYmF6cXV4", count: 90)
        + "-2BAbCdEf&utm_source=newsletter&utm_medium=email"

    nonisolated static let corpus: [Pattern] = [
        Pattern(name: "plain <a href>", html: #"<p>Read <a id="p" href="https://example.com/plain">the post</a> today.</p>"#,
                probes: [Probe(label: "text", selector: "#ss-p", expected: "https://example.com/plain")]),
        Pattern(name: "target=_blank", html: #"<p><a id="p" href="https://example.com/blank" target="_blank">Shop now</a></p>"#,
                probes: [Probe(label: "text", selector: "#ss-p", expected: "https://example.com/blank")]),
        Pattern(name: "target=_top", html: #"<p><a id="p" href="https://example.com/top" target="_top">Shop now</a></p>"#,
                probes: [Probe(label: "text", selector: "#ss-p", expected: "https://example.com/top")]),
        Pattern(name: "target=_parent", html: #"<p><a id="p" href="https://example.com/parent" target="_parent">Shop now</a></p>"#,
                probes: [Probe(label: "text", selector: "#ss-p", expected: "https://example.com/parent")]),
        Pattern(name: "target=named", html: #"<p><a id="p" href="https://example.com/named" target="promo">Shop now</a></p>"#,
                probes: [Probe(label: "text", selector: "#ss-p", expected: "https://example.com/named")]),
        Pattern(name: "target=_self", html: #"<p><a id="p" href="https://example.com/self" target="_self">Shop now</a></p>"#,
                probes: [Probe(label: "text", selector: "#ss-p", expected: "https://example.com/self")]),
        Pattern(name: "rel=noopener noreferrer", html: #"<p><a id="p" href="https://example.com/rel" rel="noopener noreferrer">Details</a></p>"#,
                probes: [Probe(label: "text", selector: "#ss-p", expected: "https://example.com/rel")]),
        Pattern(name: "target=_blank rel=noopener", html:
                    #"<p><a id="p" href="https://example.com/blankrel" target="_blank" rel="noopener noreferrer">Details</a></p>"#,
                probes: [Probe(label: "text", selector: "#ss-p", expected: "https://example.com/blankrel")]),
        Pattern(name: "cmd-click plain", html: #"<p><a id="p" href="https://example.com/cmd">Open in background</a></p>"#,
                probes: [Probe(label: "⌘-click", selector: "#ss-p", expected: "https://example.com/cmd", modifiers: .command)]),
        Pattern(name: "Litmus bulletproof (padded <a>, _blank)", html: """
            <table role="presentation" border="0" cellspacing="0" cellpadding="0"><tr>
            <td align="center" style="border-radius:3px;" bgcolor="#e9703e"><a id="p" href="https://litmus.example/cta" target="_blank"
             style="font-size:16px;font-family:Helvetica,Arial,sans-serif;color:#ffffff;text-decoration:none;border-radius:3px;padding:12px 18px;border:1px solid #e9703e;display:inline-block;">Learn More &rarr;</a></td>
            </tr></table>
            """,
                probes: [Probe(label: "text", selector: "#ss-p", expected: "https://litmus.example/cta"),
                         Probe(label: "padding", selector: "#ss-p", spot: .inset(4, 4), expected: "https://litmus.example/cta")]),
        Pattern(name: "Litmus bulletproof (padded <a>, no target)", html: """
            <table role="presentation" border="0" cellspacing="0" cellpadding="0"><tr>
            <td align="center" style="border-radius:3px;" bgcolor="#e9703e"><a id="p" href="https://litmus.example/cta2"
             style="font-size:16px;color:#ffffff;text-decoration:none;padding:12px 18px;border:1px solid #e9703e;display:inline-block;">Learn More</a></td>
            </tr></table>
            """,
                probes: [Probe(label: "text", selector: "#ss-p", expected: "https://litmus.example/cta2"),
                         Probe(label: "padding", selector: "#ss-p", spot: .inset(4, 4), expected: "https://litmus.example/cta2")]),
        Pattern(name: "<td> padding button (Microsoft-style)", html: """
            <table cellspacing="0" cellpadding="0"><tr><td id="td" style="background-color:#2672ec;padding:12px 28px;">
            <a id="p" href="https://account.ms.example/verify?code=12" style="color:#ffffff;text-decoration:none;font-family:Segoe UI,sans-serif">Verify</a>
            </td></tr></table>
            """,
                probes: [Probe(label: "text", selector: "#ss-p", expected: "https://account.ms.example/verify?code=12"),
                         Probe(label: "cell padding", selector: "#ss-td", spot: .inset(4, 4), expected: nil)]),
        Pattern(name: "Mailchimp button (_blank, tracking)", html: """
            <table border="0" cellpadding="0" cellspacing="0" class="mcnButtonContentContainer" style="border-collapse:separate !important;border-radius:4px;background-color:#2BAADF;"><tbody><tr>
            <td align="center" valign="middle" class="mcnButtonContent" style="font-family:Arial;font-size:16px;padding:15px;">
            <a class="mcnButton" id="p" title="Read more" href="https://shop.us21.list-manage.com/track/click?u=abc&amp;id=def&amp;e=123" target="_blank" style="font-weight:bold;letter-spacing:normal;line-height:100%;text-align:center;text-decoration:none;color:#FFFFFF;">Read more</a>
            </td></tr></tbody></table>
            """,
                probes: [Probe(label: "text", selector: "#ss-p", expected: "https://shop.us21.list-manage.com/track/click?u=abc&id=def&e=123")]),
        Pattern(name: "Campaign Monitor VML + non-mso twin", html: """
            <div><!--[if mso]>
              <v:roundrect xmlns:v="urn:schemas-microsoft-com:vml" xmlns:w="urn:schemas-microsoft-com:office:word" href="https://cm.example/b" style="height:40px;v-text-anchor:middle;width:200px;" arcsize="10%" stroke="f" fillcolor="#d62828">
                <w:anchorlock/><center style="color:#ffffff;font-family:sans-serif;font-size:16px;font-weight:bold;">Show me the button!</center>
              </v:roundrect>
            <![endif]--><![if !mso]>
              <table cellspacing="0" cellpadding="0"><tr><td align="center" width="200" height="40" bgcolor="#d62828" style="border-radius:5px;color:#ffffff;display:block;">
                <a id="p" href="https://cm.example/b" style="font-size:16px;font-weight:bold;font-family:Helvetica,Arial,sans-serif;text-decoration:none;line-height:40px;width:100%;display:inline-block"><span id="s" style="color:#FFFFFF;">Show me the button!</span></a>
              </td></tr></table>
            <![endif]></div>
            """,
                probes: [Probe(label: "text", selector: "#ss-s", expected: "https://cm.example/b"),
                         Probe(label: "edge", selector: "#ss-p", spot: .inset(6, 4), expected: "https://cm.example/b")]),
        Pattern(name: "VML <!--[if !mso]><!--> twin, _blank", html: """
            <!--[if mso]><v:roundrect href="https://vml2.example/go" style="height:44px;width:220px" fillcolor="#111"><center>Go</center></v:roundrect><![endif]-->
            <!--[if !mso]><!--><a id="p" href="https://vml2.example/go" target="_blank" style="background-color:#111111;border-radius:4px;color:#ffffff;display:inline-block;font-family:sans-serif;font-size:15px;line-height:44px;text-align:center;text-decoration:none;width:220px;">Go</a><!--<![endif]-->
            """,
                probes: [Probe(label: "text", selector: "#ss-p", expected: "https://vml2.example/go"),
                         Probe(label: "edge", selector: "#ss-p", spot: .inset(6, 4), expected: "https://vml2.example/go")]),
        Pattern(name: "<a> wrapping <table> (Google-style, _blank)", html: """
            <a id="p" href="https://docs.google.example/d/1/edit" target="_blank" style="text-decoration:none">
            <table role="presentation" cellpadding="0" cellspacing="0"><tr><td id="td" style="padding:12px 24px;background:#1a73e8;color:#ffffff;border-radius:4px;font-family:Arial">Open</td></tr></table></a>
            """,
                probes: [Probe(label: "cell text", selector: "#ss-td", expected: "https://docs.google.example/d/1/edit"),
                         Probe(label: "cell padding", selector: "#ss-td", spot: .inset(4, 4), expected: "https://docs.google.example/d/1/edit")]),
        Pattern(name: "<a> wrapping <table>, no target", html: """
            <a id="p" href="https://docs.google.example/d/2/edit" style="text-decoration:none">
            <table role="presentation" cellpadding="0" cellspacing="0"><tr><td id="td" style="padding:12px 24px;background:#1a73e8;color:#ffffff">Open</td></tr></table></a>
            """,
                probes: [Probe(label: "cell text", selector: "#ss-td", expected: "https://docs.google.example/d/2/edit"),
                         Probe(label: "cell padding", selector: "#ss-td", spot: .inset(4, 4), expected: "https://docs.google.example/d/2/edit")]),
        Pattern(name: "<a> around <td> (fostered out by the parser)", html: """
            <table><tr><a id="p" href="https://fostered.example/x"><td id="td" style="padding:10px;background:#eee">Fostered cell</td></a></tr></table>
            """,
                probes: [Probe(label: "cell text", selector: "#ss-td", expected: nil)]),
        Pattern(name: "<a> wrapping <div> (_blank)", html: """
            <a id="p" href="https://div.example/start" target="_blank" style="text-decoration:none"><div id="d" style="background:#000;color:#fff;padding:16px;text-align:center;width:240px">Get started</div></a>
            """,
                probes: [Probe(label: "div text", selector: "#ss-d", expected: "https://div.example/start"),
                         Probe(label: "div padding", selector: "#ss-d", spot: .inset(4, 4), expected: "https://div.example/start")]),
        Pattern(name: "<a> wrapping padded <span> (Stripe-style, _blank)", html: """
            <table><tr><td align="center" bgcolor="#635bff" style="border-radius:4px"><a id="p" href="https://pay.stripe.example/invoice/acct_1/inv_2" target="_blank" style="text-decoration:none"><span id="s" style="display:inline-block;padding:10px 20px;color:#ffffff;font-weight:600">Pay this invoice</span></a></td></tr></table>
            """,
                probes: [Probe(label: "span text", selector: "#ss-s", expected: "https://pay.stripe.example/invoice/acct_1/inv_2"),
                         Probe(label: "span padding", selector: "#ss-s", spot: .inset(3, 3), expected: "https://pay.stripe.example/invoice/acct_1/inv_2")]),
        Pattern(name: "<a> wrapping <img> (data:, _blank)", html: """
            <a id="p" href="https://img.example/sale" target="_blank"><img id="i" src="\(picture)" width="240" height="60" alt="Shop the sale" style="display:block;border:0"></a>
            """,
                probes: [Probe(label: "image", selector: "#ss-i", expected: "https://img.example/sale")]),
        Pattern(name: "<a> wrapping <img> (data:, no target)", html: """
            <a id="p" href="https://img.example/sale2"><img id="i" src="\(picture)" width="240" height="60" alt="Shop the sale" style="display:block;border:0"></a>
            """,
                probes: [Probe(label: "image", selector: "#ss-i", expected: "https://img.example/sale2")]),
        Pattern(name: "<a> wrapping a parked remote <img>", html: """
            <a id="p" href="https://img.example/parked"><img id="i" src="https://cdn.img.example/button.png" width="240" height="60" alt="View order"></a>
            """,
                probes: [Probe(label: "image", selector: "#ss-i", expected: "https://img.example/parked")]),
        Pattern(name: "GitHub-style (<a> padded inline-block)", html: """
            <a id="p" href="https://github.example/acme/app/pull/42" style="background-color:#2ea44f;border:1px solid #2c974b;border-radius:6px;color:#ffffff;display:inline-block;font-size:14px;font-weight:500;padding:6px 16px;text-decoration:none">View pull request</a>
            """,
                probes: [Probe(label: "text", selector: "#ss-p", expected: "https://github.example/acme/app/pull/42")]),
        Pattern(name: "Apple receipt (<a><span> in cells, _blank)", html: """
            <table width="100%"><tr><td style="padding:6px 0"><span style="font-size:12px">Subscription</span></td>
            <td align="right"><a id="p" href="https://apps.apple.example/account/subscriptions" target="_blank" style="color:#0070c9"><span id="s">Manage</span></a></td></tr></table>
            """,
                probes: [Probe(label: "text", selector: "#ss-s", expected: "https://apps.apple.example/account/subscriptions")]),
        Pattern(name: "image map <area> (_blank and none)", html: """
            <img id="m" src="\(picture)" width="300" height="100" usemap="#nav" alt="Navigation" style="display:block">
            <map name="nav"><area id="l" shape="rect" coords="0,0,150,100" href="https://map.example/left" target="_blank" alt="Left">
            <area id="r" shape="rect" coords="150,0,300,100" href="https://map.example/right" alt="Right"></map>
            """,
                probes: [Probe(label: "left area (_blank)", selector: "#ss-l", spot: .area(image: "#ss-m"), expected: "https://map.example/left"),
                         Probe(label: "right area", selector: "#ss-r", spot: .area(image: "#ss-m"), expected: "https://map.example/right")]),
        Pattern(name: "href with spaces and line breaks", html: "<p><a id=\"p\" href=\"  https://example.com/spaced/\npath?x=1  \">Spaced</a></p>",
                probes: [Probe(label: "text", selector: "#ss-p", expected: "https://example.com/spaced/path?x=1")]),
        Pattern(name: "&amp; entities in href", html: #"<p><a id="p" href="https://example.com/q?a=1&amp;b=2&amp;c=%20d">Entities</a></p>"#,
                probes: [Probe(label: "text", selector: "#ss-p", expected: "https://example.com/q?a=1&b=2&c=%20d")]),
        Pattern(name: "very long click-tracking URL (_blank)", html: "<p><a id=\"p\" href=\"\(longTracking)\" target=\"_blank\">Track me</a></p>",
                probes: [Probe(label: "text", selector: "#ss-p", expected: longTracking)]),
        Pattern(name: "uppercase scheme", html: #"<p><a id="p" href="HTTPS://EXAMPLE.COM/Upper">Upper</a></p>"#,
                probes: [Probe(label: "text", selector: "#ss-p", expected: "https://example.com/Upper")]),
        Pattern(name: "protocol-relative //host", html: #"<p><a id="p" href="//example.com/protocol-relative">Relative scheme</a></p>"#,
                probes: [Probe(label: "text", selector: "#ss-p", expected: "https://example.com/protocol-relative",
                               knownGap: "URLPolicy rejects a scheme-relative href, so the sanitizer drops it")]),
        Pattern(name: "relative link, no base", html: #"<p><a id="p" href="/account/settings">Settings</a></p>"#,
                probes: [Probe(label: "text", selector: "#ss-p", expected: nil)]),
        Pattern(name: "display:block padded <a>", html: """
            <a id="p" href="https://block.example/go" style="display:block;padding:20px;background:#333333;color:#ffffff;text-align:center;text-decoration:none;width:260px">Block link</a>
            """,
                probes: [Probe(label: "text", selector: "#ss-p", expected: "https://block.example/go"),
                         Probe(label: "padding", selector: "#ss-p", spot: .inset(5, 5), expected: "https://block.example/go")]),
        Pattern(name: "position:absolute <a>", html: """
            <div style="position:relative;height:90px;background:#f4f4f4"><a id="p" href="https://abs.example/go" style="position:absolute;top:20px;left:30px;padding:10px;background:#0a0;color:#fff">Absolute</a></div>
            """,
                probes: [Probe(label: "text", selector: "#ss-p", expected: "https://abs.example/go")]),
        Pattern(name: "high z-index container", html: """
            <div style="position:relative;z-index:99999"><a id="p" href="https://z.example/go" target="_blank" style="display:inline-block;padding:8px;background:#06c;color:#fff">Z link</a></div>
            """,
                probes: [Probe(label: "text", selector: "#ss-p", expected: "https://z.example/go")]),
        Pattern(name: "link under a transparent overlay", html: """
            <div style="position:relative;width:300px"><p style="margin:0;padding:10px"><a id="p" href="https://under.example/x">Under the overlay</a></p>
            <div style="position:absolute;top:0;left:0;right:0;bottom:0"></div></div>
            """,
                probes: [Probe(label: "text", selector: "#ss-p", expected: nil)]),
        Pattern(name: "<a role=button>", html: #"<p><a id="p" role="button" href="https://role.example/btn" style="padding:6px 12px;background:#eee">Role button</a></p>"#,
                probes: [Probe(label: "text", selector: "#ss-p", expected: "https://role.example/btn")]),
        Pattern(name: "<a> inside <button>", html: #"<p><button style="padding:8px"><a id="p" href="https://btn.example/inside">Inside a button</a></button></p>"#,
                probes: [Probe(label: "text", selector: "#ss-p", expected: "https://btn.example/inside",
                               knownGap: "the sanitizer removes <button> with all it holds")]),
        Pattern(name: "<button> inside <a>", html: #"<p><a id="p" href="https://btn.example/around"><button id="b" style="padding:8px">Button in a link</button></a></p>"#,
                probes: [Probe(label: "button", selector: "#ss-b", expected: "https://btn.example/around",
                               knownGap: "the sanitizer removes <button> with all it holds, which leaves the link empty")]),
        Pattern(name: "<form> with a submit button", html: """
            <form action="https://form.example/confirm" method="get"><input type="hidden" name="t" value="1"><input id="b" type="submit" value="Confirm subscription"></form>
            """,
                probes: [Probe(label: "submit", selector: "#ss-b", expected: "https://form.example/confirm?t=1",
                               knownGap: "the sanitizer removes <form> and <input>")]),
        Pattern(name: "onclick-only element", html: """
            <div id="p" onclick="window.location='https://onclick.example/x'" style="cursor:pointer;padding:10px;background:#eee;width:200px">Click me</div>
            """,
                probes: [Probe(label: "div", selector: "#ss-p", expected: nil)]),
        Pattern(name: "<a> in inline SVG (_blank)", html: """
            <svg width="220" height="44" xmlns="http://www.w3.org/2000/svg"><a id="p" href="https://svg.example/go" target="_blank"><rect id="r" width="220" height="44" fill="#0099ff"/><text x="20" y="28" fill="#fff">SVG button</text></a></svg>
            """,
                probes: [Probe(label: "rect", selector: "#ss-r", expected: "https://svg.example/go")]),
        Pattern(name: "mailto with target=_blank", html: #"<p><a id="p" href="mailto:help@example.com?subject=Hi" target="_blank">Write to us</a></p>"#,
                probes: [Probe(label: "text", selector: "#ss-p", expected: "mailto:help@example.com?subject=Hi")]),
        Pattern(name: "mailto plain", html: #"<p><a id="p" href="mailto:help@example.com">help@example.com</a></p>"#,
                probes: [Probe(label: "text", selector: "#ss-p", expected: "mailto:help@example.com")]),
        Pattern(name: "tel link", html: #"<p><a id="p" href="tel:+15551234567">Call</a></p>"#,
                probes: [Probe(label: "text", selector: "#ss-p", expected: "tel:+15551234567")]),
        Pattern(name: "in-message anchor with target=_blank", html: """
            <p><a id="p" href="#later" target="_blank">Jump to the list</a></p><div style="height:1600px">Long news</div><h2 id="later">The list</h2>
            """,
                probes: [Probe(label: "text (scrolls, opens nothing)", selector: "#ss-p", expected: nil)]),
        Pattern(name: "in-message anchor with target=_top", html: """
            <p><a id="p" href="#later" target="_top">Jump to the list</a></p><div style="height:1600px">Long news</div><h2 id="later">The list</h2>
            """,
                probes: [Probe(label: "text (scrolls, opens nothing)", selector: "#ss-p", expected: nil)]),
        Pattern(name: "link in a quoted part (_blank and plain)", html: """
            <p>Thanks, see below.</p>
            <div class="gmail_quote"><div class="gmail_attr">On Mon, 2 Nov 2026 at 10:00, Ada &lt;ada@example.com&gt; wrote:<br></div>
            <blockquote class="gmail_quote" style="margin:0 0 0 .8ex;border-left:1px #ccc solid;padding-left:1ex">
            <p><a id="q" href="https://quoted.example/blank" target="_blank">Quoted button</a></p><p><a id="r" href="https://quoted.example/plain">Quoted plain</a></p>
            </blockquote></div>
            """,
                probes: [Probe(label: "quoted _blank", selector: "#ss-q", expected: "https://quoted.example/blank"),
                         Probe(label: "quoted plain", selector: "#ss-r", expected: "https://quoted.example/plain")],
                showsQuotes: true),
    ]

    // MARK: Setup

    private var folder: URL!
    private var engine: MailEngine?
    private var suite: String?
    private var savedPreference = false
    private let account = ListTestSupport.accountA

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PAPER_UI_TESTS"] == "1", "WebKit runs with PAPER_UI_TESTS=1")
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("ReaderLinkClick-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        _ = AppSettings.shared
        savedPreference = ConversationViewController.loadRemoteImages
        ConversationViewController.loadRemoteImages = false
    }

    override func tearDownWithError() throws {
        ConversationViewController.loadRemoteImages = savedPreference
        if let engine {
            var stopped = false
            Task { await engine.stopAndWait(); stopped = true }
            ListTestSupport.spin(until: { stopped }, timeout: 5)
        }
        if let suite { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        if let folder { try? FileManager.default.removeItem(at: folder) }
    }

    /// Stands in front of the pool's policy: records what WebKit asks it, then lets it decide, and records what it hands
    /// the browser instead of opening it.
    @MainActor
    final class Recorder: NSObject, WKNavigationDelegate, WKUIDelegate {
        let policy: ConversationNavigationPolicy
        var opened: [URL] = []
        var asked: [String] = []

        init(policy: ConversationNavigationPolicy) {
            self.policy = policy
            super.init()
            policy.openExternally = { [weak self] url in self?.opened.append(url) }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            let url = navigationAction.request.url?.absoluteString ?? "nil"
            let quiet = navigationAction.navigationType == .other && (url.hasPrefix("about:") || url.hasPrefix("ss-shell:"))
            if !quiet {
                let target = navigationAction.targetFrame.map { $0.isMainFrame ? "main" : "frame" } ?? "new"
                asked.append("policy(\(Self.kind(navigationAction.navigationType)),\(target),\(url.prefix(48)))")
            }
            policy.webView(webView, decidePolicyFor: navigationAction, decisionHandler: decisionHandler)
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            asked.append("terminated")
            policy.webViewWebContentProcessDidTerminate(webView)
        }

        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction,
                     windowFeatures: WKWindowFeatures) -> WKWebView? {
            asked.append("createWebView(\((navigationAction.request.url?.absoluteString ?? "nil").prefix(48)))")
            return policy.webView(webView, createWebViewWith: configuration, for: navigationAction, windowFeatures: windowFeatures)
        }

        static func kind(_ type: WKNavigationType) -> String {
            switch type {
            case .linkActivated: return "link"
            case .formSubmitted: return "form"
            case .backForward: return "backForward"
            case .reload: return "reload"
            case .formResubmitted: return "formResubmitted"
            case .other: return "other"
            @unknown default: return "unknown"
            }
        }
    }

    // MARK: Tests

    /// The corpus as the app shows it today.
    func testTheCorpusAsShippedClickedForReal() throws {
        let outcomes = try runCorpus(variant: "shipped", sandbox: nil)
        // Absent only while `PAPER_LINK_ONLY` leaves it out.
        if let plain = outcomes.first(where: { $0.pattern == "plain <a href>" }) {
            XCTAssertEqual(plain.click, "https://example.com/plain", "the harness's control: a real click on a plain link opens it")
        }
        assertStrict(outcomes)
    }

    /// Candidate fix: popups (a `target` naming a new window) allowed, and the top page navigated on a click; the policy
    /// still decides every one of them.
    func testTheCorpusWithSandboxAllowingPopupsAndTopNavigationByUserActivation() throws {
        try skipUnlessVariants()
        let outcomes = try runCorpus(variant: "popups+top-by-activation",
                                     sandbox: "allow-same-origin allow-popups allow-top-navigation-by-user-activation")
        assertStrict(outcomes)
    }

    /// The smallest change that fixed every target and every mailto:/tel: link on 2026-11-25. A `_top` or `_parent` target,
    /// which the frame may not navigate, comes as a request for a new window; an in-message anchor with a target scrolls.
    func testTheCorpusWithSandboxAllowingPopupsOnly() throws {
        try skipUnlessVariants()
        let outcomes = try runCorpus(variant: "popups", sandbox: "allow-same-origin allow-popups")
        assertStrict(outcomes)
    }

    /// Navigation to a scheme another app handles (mailto:, tel:) from the frame itself.
    func testTheCorpusWithSandboxAllowingCustomProtocolsOnly() throws {
        try skipUnlessVariants()
        _ = try runCorpus(variant: "custom-protocols", sandbox: "allow-same-origin allow-top-navigation-to-custom-protocols")
    }

    func testTheCorpusWithSandboxAllowingTopNavigationByUserActivationOnly() throws {
        try skipUnlessVariants()
        _ = try runCorpus(variant: "top-by-activation", sandbox: "allow-same-origin allow-top-navigation-by-user-activation")
    }

    /// Candidate fix at load instead: the shell takes every `target` off the body's links once the frame has loaded, so each
    /// link navigates its own frame, which the policy turns into an open.
    func testTheCorpusWithTargetsRemovedAtLoad() throws {
        try skipUnlessVariants()
        _ = try runCorpus(variant: "targets-removed", sandbox: nil, removesTargets: true)
    }

    /// Block trackers on (spec §5.60): a tracking link loses its tracking parameters on its way to the browser, whatever
    /// its target.
    func testATrackingLinkWithBlockTrackersOn() throws {
        let link = "https://shop.example/p/42?utm_source=news&amp;color=red&amp;fbclid=abc"
        let patterns = [
            Pattern(name: "tracking plain (Block trackers on)", html: "<p><a id=\"p\" href=\"\(link)\">Shop</a></p>",
                    probes: [Probe(label: "text", selector: "#ss-p", expected: "https://shop.example/p/42?color=red")]),
            Pattern(name: "tracking _blank (Block trackers on)", html: "<p><a id=\"p\" href=\"\(link)\" target=\"_blank\">Shop</a></p>",
                    probes: [Probe(label: "text", selector: "#ss-p", expected: "https://shop.example/p/42?color=red")]),
        ]
        let outcomes = try runCorpus(variant: "shipped+blockTrackers", sandbox: nil, patterns: patterns, blocksTrackers: true)
        XCTAssertEqual(outcomes.first?.click, "https://shop.example/p/42?color=red")
        assertStrict(outcomes)
    }

    /// A link in the earlier message of a conversation, which a click also makes the target (`frameFocused`).
    func testALinkInAnEarlierMessageOfTheConversation() throws {
        let patterns = [
            Pattern(name: "earlier message, plain", html: #"<p>First. <a id="p" href="https://earlier.example/plain">Earlier plain</a></p>"#,
                    probes: [Probe(label: "text", selector: "#ss-p", expected: "https://earlier.example/plain")]),
            Pattern(name: "earlier message, _blank", html: #"<p>First. <a id="b" href="https://earlier.example/blank" target="_blank">Earlier blank</a></p>"#,
                    probes: [Probe(label: "text", selector: "#ss-b", expected: "https://earlier.example/blank")]),
        ]
        let outcomes = try runCorpus(variant: "shipped,multi", sandbox: nil, patterns: patterns, threaded: true)
        XCTAssertEqual(outcomes.first?.click, "https://earlier.example/plain")
        assertStrict(outcomes)
    }

    /// The main window's reader and a conversation in its own window (spec §5.49), through the app's window controller.
    func testTheMainWindowAndAReaderWindowClickedForReal() throws {
        let harness = try MainWindowHarness(threads: 2)
        defer { harness.close() }
        let blank = Pattern(name: "target=_blank", html: #"<p><a id="p" href="https://example.com/blank" target="_blank">Shop now</a></p>"#,
                            probes: [Probe(label: "text", selector: "#ss-p", expected: "https://example.com/blank")])
        let plain = Pattern(name: "plain <a href>", html: #"<p><a id="p" href="https://example.com/plain">the post</a></p>"#,
                            probes: [Probe(label: "text", selector: "#ss-p", expected: "https://example.com/plain")])
        let ids = try store([plain, blank], in: harness.environment.store, threaded: false)
        XCTAssertTrue(ListTestSupport.spin(until: { ids.allSatisfy { id in harness.list.conversations.contains { $0.id == id.conversation } } },
                                           timeout: 5), "the list shows the corpus")
        var outcomes: [Outcome] = []
        let window = try XCTUnwrap(harness.controller.window)
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        let reader = harness.reader
        let recorder = Recorder(policy: try policy(of: reader))
        let sandbox = Self.sandboxFromEnvironment
        let label = sandbox.map { " [" + $0 + "]" } ?? ""
        XCTAssertTrue(ListTestSupport.spin(until: { reader.pool.slots.allSatisfy(\.isReady) }, timeout: 15), "the shells loaded")
        for slot in reader.pool.slots { _ = evaluate(Self.patch(sandbox: sandbox, removesTargets: false), in: slot.webView) }
        for (pattern, id) in zip([plain, blank], ids) {
            harness.list.selectedConversationID = id.conversation
            harness.list.onSelectionChange?(id.conversation)
            try waitRendered(id.conversation, in: reader)
            install(recorder, in: reader)
            outcomes += try probe(pattern, in: reader, window: window, recorder: recorder, variant: "main window" + label)
        }

        // The second conversation in a window of its own (⌘O).
        harness.list.selectedConversationID = ids[1].conversation
        harness.list.onSelectionChange?(ids[1].conversation)
        harness.controller.openSelectionInNewWindow(nil)
        let readerWindow = try XCTUnwrap(harness.controller.readerWindows.first { $0.conversationID == ids[1].conversation })
        let other = try XCTUnwrap(readerWindow.window)
        let otherRecorder = Recorder(policy: try policy(of: readerWindow.conversation))
        install(otherRecorder, in: readerWindow.conversation)
        try waitRendered(ids[1].conversation, in: readerWindow.conversation)
        if sandbox != nil {
            // Its one shell rendered as it opened: patched, then shown again, so its frame is made under the patch.
            for slot in readerWindow.conversation.pool.slots {
                _ = evaluate(Self.patch(sandbox: sandbox, removesTargets: false), in: slot.webView)
            }
            ListTestSupport.spin(for: 0.3)
            try waitRendered(ids[1].conversation, in: readerWindow.conversation)
        }
        other.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        other.makeKeyAndOrderFront(nil)
        defer { other.orderOut(nil) }
        install(otherRecorder, in: readerWindow.conversation)
        outcomes += try probe(blank, in: readerWindow.conversation, window: other, recorder: otherRecorder, variant: "reader window" + label)
        report(outcomes)
        XCTAssertEqual(outcomes.first?.click, "https://example.com/plain", "the main window's control")
        assertStrict(outcomes)
    }

    private func skipUnlessVariants() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PAPER_LINK_VARIANTS"] == "1", "candidate fixes run with PAPER_LINK_VARIANTS=1")
    }

    // MARK: Running the corpus

    private struct Stored {
        var conversation: ConversationID
        var message: MessageID
    }

    /// Stores each pattern as a message of its own (or, `threaded`, after a later reply in the same conversation), sanitized
    /// as sync stores it.
    private func store(_ patterns: [Pattern], in store: MailStoring, threaded: Bool) throws -> [Stored] {
        var result: [Stored] = []
        let now = Date()
        for (index, pattern) in patterns.enumerated() {
            let conversation = ConversationID(accountID: account.id, providerID: "link-thread-\(index)")
            let message = MessageID(accountID: account.id, providerID: "link-\(index)")
            var messages = [MessageMetadata(
                id: message, conversationID: conversation, subject: "Link \(index)", snippet: pattern.name,
                from: EmailAddress(name: "News", address: "news@sender.example"), to: [EmailAddress(address: account.email)],
                date: now.addingTimeInterval(Double(-index * 600 - 300)), roles: [.inbox], isRead: true, isStarred: false, hasAttachments: false
            )]
            if threaded {
                messages.append(MessageMetadata(
                    id: MessageID(accountID: account.id, providerID: "link-\(index)-reply"), conversationID: conversation,
                    subject: "Re: Link \(index)", snippet: "A later reply", from: EmailAddress(name: "Ada", address: "ada@sender.example"),
                    to: [EmailAddress(address: account.email)], date: now.addingTimeInterval(Double(-index * 600)), roles: [.inbox],
                    isRead: true, isStarred: false, hasAttachments: false))
            }
            try store.upsertMessages(messages)
            try save(pattern.html, for: message, in: store)
            if threaded { try save("<p>A later reply, with no links.</p>", for: messages[1].id, in: store) }
            result.append(Stored(conversation: conversation, message: message))
        }
        return result
    }

    private func save(_ html: String, for id: MessageID, in store: MailStoring) throws {
        let body = MessageBody(html: html, text: nil)
        let sanitized = HTMLSanitizer().sanitize(body, messageID: id)
        try store.saveBody(StoredBody(body: body, renderedHTML: sanitized.html, plainText: sanitized.plainText,
                                      hasQuotedContent: sanitized.hasQuotedContent,
                                      blockedRemoteImageCount: RenderPayloadBuilder.blockedRemoteImageCount(in: sanitized.html),
                                      trackerImageCount: sanitized.trackerImageCount, typesetting: sanitized.typesetting,
                                      declaresColors: sanitized.declaresColors, coveredByNewYork: sanitized.coveredByNewYork),
                           for: id)
    }

    /// `PAPER_LINK_SANDBOX`: a `sandbox` for the body frames of the tests that otherwise run the shell as shipped (the
    /// trackers', the earlier message's, the windows'), to try a candidate fix on them.
    private static var sandboxFromEnvironment: String? {
        ProcessInfo.processInfo.environment["PAPER_LINK_SANDBOX"].flatMap { $0.isEmpty ? nil : $0 }
    }

    private func runCorpus(variant: String, sandbox: String?, removesTargets: Bool = false, patterns: [Pattern] = corpus,
                           blocksTrackers: Bool = false, threaded: Bool = false) throws -> [Outcome] {
        let variant = sandbox == nil ? variant + (Self.sandboxFromEnvironment.map { " [" + $0 + "]" } ?? "") : variant
        let sandbox = sandbox ?? Self.sandboxFromEnvironment
        var patterns = patterns
        if let only = ProcessInfo.processInfo.environment["PAPER_LINK_ONLY"], !only.isEmpty {
            patterns = patterns.filter { pattern in only.split(separator: "|").contains { pattern.name.contains($0) } }
        }
        let memory = InMemoryMailStore()
        try memory.upsertAccount(account)
        let ids = try store(patterns, in: memory, threaded: threaded)
        let service = DemoMailService()
        let engine = MailEngine(store: memory, tokenStore: InMemoryTokenStore(), tokenProvider: DemoTokenProvider(),
                                authenticator: DemoAuthenticator(), sanitizer: HTMLSanitizer(), providerFactory: { service.provider(for: $0) },
                                attachmentCacheDirectory: folder.appendingPathComponent("attachments", isDirectory: true))
        self.engine = engine
        let suite = "ReaderLinkClickTests-\(UUID().uuidString)"
        self.suite = suite
        let settings = AppSettings(defaults: try XCTUnwrap(UserDefaults(suiteName: suite)))
        let reader = ConversationViewController(client: engine, settings: settings)
        // Before anything can be clicked: the policy records instead of opening.
        let recorder = Recorder(policy: try policy(of: reader))
        if blocksTrackers {
            reader.pool.trackerRules = TrackerContentRules(
                store: try XCTUnwrap(WKContentRuleListStore(url: folder.appendingPathComponent("rules", isDirectory: true))))
            settings.blocksTrackers = true
        }
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 900, height: 800), styleMask: [.titled, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil); window.close() }
        window.contentViewController = reader
        window.setContentSize(NSSize(width: 900, height: 800))
        window.makeKeyAndOrderFront(nil)
        XCTAssertTrue(ListTestSupport.spin(until: { reader.pool.slots.allSatisfy(\.isReady) }, timeout: 15), "the shells loaded")
        for slot in reader.pool.slots {
            _ = evaluate(Self.patch(sandbox: sandbox, removesTargets: removesTargets), in: slot.webView)
        }
        var outcomes: [Outcome] = []
        for (pattern, id) in zip(patterns, ids) {
            reader.show(id.conversation)
            try waitRendered(id.conversation, in: reader)
            if threaded, let webView = reader.pool.current?.webView {
                // The earlier message opens folded: unfolded by its own row, as a click there does, and then the latest is
                // made the target again, so the link is in a message that is not the target.
                _ = evaluate("""
                    (function () { var rows = document.querySelectorAll('.ss-card.ss-collapsed .ss-row');
                      for (var i = 0; i < rows.length; i++) { rows[i].click(); }
                      var cards = document.querySelectorAll('.ss-card'); cards[cards.length - 1].querySelector('.ss-inner').click();
                      return rows.length; })()
                    """, in: webView)
                ListTestSupport.spin(for: 0.6)
                try waitRendered(id.conversation, in: reader)
            }
            install(recorder, in: reader)
            outcomes += try probe(pattern, in: reader, window: window, recorder: recorder, variant: variant)
        }
        reader.show(nil)
        report(outcomes)
        return outcomes
    }

    /// Changes, in the shell at run time, what every body frame made from now on gets: its `sandbox`, and (with
    /// `removesTargets`) its links' `target`s taken off once it has loaded. Nil and false leave the shell as shipped.
    private static func patch(sandbox: String?, removesTargets: Bool) -> String {
        var script = "(function () {\n"
        if let sandbox {
            script += """
                var set = Element.prototype.setAttribute;
                Element.prototype.setAttribute = function (name, value) {
                  if (this.tagName === 'IFRAME' && name === 'sandbox') { value = '\(sandbox)'; }
                  return set.call(this, name, value);
                };
                // A frame already made (a reader window renders as it opens) takes the sandbox when it loads again.
                var made = document.querySelectorAll('.ss-card iframe');
                for (var m = 0; m < made.length; m++) {
                  if (made[m].getAttribute('sandbox') !== '\(sandbox)') { made[m].setAttribute('sandbox', 'x'); made[m].srcdoc = made[m].srcdoc; }
                }

                """
        }
        if removesTargets {
            script += """
                var create = Document.prototype.createElement;
                Document.prototype.createElement = function (tag) {
                  var node = create.apply(this, arguments);
                  if (String(tag).toLowerCase() === 'iframe') {
                    node.addEventListener('load', function () {
                      try {
                        var links = node.contentDocument.querySelectorAll('[target]');
                        for (var i = 0; i < links.length; i++) { links[i].removeAttribute('target'); }
                      } catch (e) {}
                    });
                  }
                  return node;
                };

                """
        }
        return script + "return 'patched'; })()"
    }

    private func policy(of reader: ConversationViewController) throws -> ConversationNavigationPolicy {
        try XCTUnwrap(reader.pool.slots.first?.webView.navigationDelegate as? ConversationNavigationPolicy, "the pool's policy")
    }

    /// The recorder in front of the policy in every slot (a slot replaced after a crash gets the policy again).
    private func install(_ recorder: Recorder, in reader: ConversationViewController) {
        for slot in reader.pool.slots {
            if slot.webView.navigationDelegate !== recorder { slot.webView.navigationDelegate = recorder }
            if slot.webView.uiDelegate !== recorder { slot.webView.uiDelegate = recorder }
        }
    }

    private func waitRendered(_ id: ConversationID, in reader: ConversationViewController) throws {
        XCTAssertTrue(ListTestSupport.spin(until: {
            guard let slot = reader.pool.current else { return false }
            return slot.isReady && slot.pendingRender == nil && !slot.renderInFlight && slot.renderedID == id
        }, timeout: 15), "the conversation rendered")
        let webView = try XCTUnwrap(reader.pool.current?.webView)
        XCTAssertTrue(ListTestSupport.spin(until: {
            self.evaluate("""
                (function () { var fs = document.querySelectorAll('.ss-card iframe');
                  // A body the sanitizer emptied has no frame at all.
                  if (!fs.length) { return document.querySelectorAll('.ss-card').length > 0; }
                  for (var i = 0; i < fs.length; i++) { var d = fs[i].contentDocument;
                    if (!d || d.URL !== 'about:srcdoc' || !d.body || d.readyState !== 'complete') { return false; }
                    // Sized, unless the sanitizer left the body nothing to show.
                    if (fs[i].getBoundingClientRect().height < 1 && ((d.body.innerText || '').trim() || d.body.querySelector('img,svg,table'))) { return false; } }
                  return true; })()
                """, in: webView) == "true"
        }, timeout: 10), "every body frame loaded and sized: " + evaluate("""
            (function () { return Array.prototype.map.call(document.querySelectorAll('.ss-card iframe'), function (f) {
              var d = f.contentDocument; return (d ? d.URL + ' ' + d.readyState + ' ' + JSON.stringify(d.body ? d.body.innerHTML.slice(0, 120) : null) : 'no document')
                + ' ' + f.getBoundingClientRect().height; }).join(' | ') || 'no frames'; })()
            """, in: webView))
    }

    // MARK: Probing

    private func probe(_ pattern: Pattern, in reader: ConversationViewController, window: NSWindow, recorder: Recorder,
                       variant: String) throws -> [Outcome] {
        var outcomes: [Outcome] = []
        for probe in pattern.probes {
            var webView = try XCTUnwrap(reader.pool.current?.webView)
            if pattern.showsQuotes {
                _ = evaluate("""
                    (function () { var t = document.querySelector('.ss-toggle-quote');
                      var d = document.querySelector('.ss-card iframe').contentDocument;
                      if (t && !d.body.classList.contains('ss-show-quotes')) { t.click(); } return true; })()
                    """, in: webView)
                ListTestSupport.spin(for: 0.4)
            }
            var outcome = Outcome(pattern: pattern.name, probe: probe.label, expected: probe.expected, knownGap: probe.knownGap, click: "?",
                                  script: "?", asked: [], hit: "")
            guard let point = locate(probe, in: webView, hit: &outcome.hit) else {
                outcome.click = "missing"
                outcome.script = "missing"
                outcomes.append(outcome)
                print("LINKCLICK\t\(variant)\t\(outcome.pattern)\t\(outcome.probe)\texpected=\(outcome.expected ?? "nothing")"
                      + "\tclick=missing\tscript=missing\thit=\(outcome.hit)\tasked=")
                continue
            }
            // A real click.
            recorder.opened = []
            recorder.asked = []
            window.makeKeyAndOrderFront(nil)
            _ = window.makeFirstResponder(webView)
            let frameTop = "String(Math.round(document.querySelector('.ss-card iframe').getBoundingClientRect().top))"
            let topBefore = Double(evaluate(frameTop, in: webView)) ?? 0
            click(at: point, in: webView, window: window, modifiers: probe.modifiers)
            outcome.click = settle(recorder, webView: webView)
            outcome.asked = recorder.asked
            // An in-message anchor opens nothing; the page scrolls to its place instead.
            let topAfter = Double(evaluate(frameTop, in: webView)) ?? 0
            if abs(topAfter - topBefore) > 50 { outcome.hit += " [click scrolled the page by \(Int(topBefore - topAfter))]" }
            if outcome.click.hasPrefix("frame:") || outcome.click == "terminated" {
                try rerender(reader)
            }

            // The same element clicked by script.
            webView = try XCTUnwrap(reader.pool.current?.webView)
            var ignored = ""
            guard let again = locate(probe, in: webView, hit: &ignored) else { outcomes.append(outcome); continue }
            recorder.opened = []
            let askedBefore = recorder.asked.count
            _ = evaluate("""
                (function () { var fs = document.querySelectorAll('.ss-card iframe');
                  for (var i = 0; i < fs.length; i++) { var f = fs[i]; var r = f.getBoundingClientRect();
                    if (\(again.y) < r.top || \(again.y) > r.bottom) { continue; }
                    var n = f.contentDocument.elementFromPoint(\(again.x) - r.left, \(again.y) - r.top);
                    if (n) { n.click(); return true; } }
                  return false; })()
                """, in: webView)
            outcome.script = settle(recorder, webView: webView)
            outcome.asked += recorder.asked.dropFirst(askedBefore).map { "script:" + $0 }
            if outcome.script.hasPrefix("frame:") || outcome.script == "terminated" {
                try rerender(reader)
            }
            outcomes.append(outcome)
            print("LINKCLICK\t\(variant)\t\(outcome.pattern)\t\(outcome.probe)\texpected=\(outcome.expected ?? "nothing")"
                  + "\tclick=\(outcome.click)\tscript=\(outcome.script)\thit=\(outcome.hit)\tasked=\(outcome.asked.joined(separator: " "))")
        }
        return outcomes
    }

    /// Where to click, in the web view's coordinates (the page's: the view is flipped and unmagnified), with the element
    /// brought into view first; nil when the sanitizer left no such element or it takes no room. `hit` is what the body's
    /// document finds at that point.
    private func locate(_ probe: Probe, in webView: WKWebView, hit: inout String) -> NSPoint? {
        let selector = ConversationShellAssets.jsStringLiteral(probe.selector)
        let spot: String
        switch probe.spot {
        case .center: spot = "x = r.left + r.width / 2; y = r.top + r.height / 2;"
        case .inset(let dx, let dy): spot = "x = r.left + \(dx); y = r.top + \(dy);"
        case .area(let image):
            spot = """
                var img = d.querySelector(\(ConversationShellAssets.jsStringLiteral(image))); var ir = img.getBoundingClientRect();
                var c = n.getAttribute('coords').split(',').map(Number);
                x = ir.left + (c[0] + c[2]) / 2; y = ir.top + (c[1] + c[3]) / 2; r = ir;
                """
        }
        let find = """
            (function () { var fs = document.querySelectorAll('.ss-card iframe');
              for (var i = 0; i < fs.length; i++) { var d = fs[i].contentDocument; var n = d && d.querySelector(\(selector));
                if (!n) { continue; }
                var anchor = n.tagName === 'AREA' ? d.querySelector('img[usemap]') : n;
                anchor.scrollIntoView({ block: 'center' }); return 'found'; }
              return 'missing'; })()
            """
        guard evaluate(find, in: webView) == "found" else {
            hit = "element missing after sanitizing"
            return nil
        }
        ListTestSupport.spin(for: 0.15)
        let measure = """
            (function () { var fs = document.querySelectorAll('.ss-card iframe');
              for (var i = 0; i < fs.length; i++) { var f = fs[i]; var d = f.contentDocument; var n = d && d.querySelector(\(selector));
                if (!n) { continue; }
                var r = n.getBoundingClientRect(); var x, y; \(spot)
                if (!r.width || !r.height) { return JSON.stringify({ empty: true }); }
                var fr = f.getBoundingClientRect(); var h = d.elementFromPoint(x, y);
                var top = document.elementFromPoint(fr.left + x, fr.top + y);
                var link = h && h.closest ? h.closest('a[href],area[href]') : null;
                return JSON.stringify({ x: fr.left + x, y: fr.top + y,
                  hit: (h ? h.tagName.toLowerCase() + (h.id ? '#' + h.id : '') : 'none') + (link ? ' in ' + link.tagName.toLowerCase() + '[href]' : '')
                    + (top === f ? '' : ' shell:' + (top ? top.tagName.toLowerCase() + '.' + top.className : 'none'))
                    + (f.getAttribute('sandbox') === 'allow-same-origin' ? '' : ' sandbox=' + f.getAttribute('sandbox')) }); }
              return JSON.stringify({ missing: true }); })()
            """
        guard let data = evaluate(measure, in: webView).data(using: .utf8),
              let box = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            hit = "unmeasured"
            return nil
        }
        if box["empty"] != nil { hit = "takes no room"; return nil }
        guard let x = box["x"] as? Double, let y = box["y"] as? Double else { hit = "missing"; return nil }
        hit = box["hit"] as? String ?? ""
        let point = NSPoint(x: x, y: y)
        guard webView.bounds.contains(point) else { hit += " (outside the view)"; return nil }
        return point
    }

    /// A user's click: the pointer moves there, then a left mouse down and up go to the window, which hit-tests them.
    private func click(at point: NSPoint, in webView: WKWebView, window: NSWindow, modifiers: NSEvent.ModifierFlags) {
        let location = webView.convert(point, to: nil)
        func event(_ type: NSEvent.EventType) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: location, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: type == .mouseMoved ? 0 : 1,
                               pressure: type == .leftMouseDown ? 1 : 0)
        }
        let hitView = window.contentView?.superview?.hitTest(location)
        if let hitView, hitView !== webView, !hitView.isDescendant(of: webView) {
            print("LINKCLICK-NOTE\tthe window hit-tests \(type(of: hitView)) at \(location), not the web view")
        }
        // A window that is not key takes a plain click as the click that makes it key, and passes it on only to a view that
        // accepts the first mouse; ⌘ passes it on. The test process is seldom the active app, so its window is seldom key:
        // then the events go to the view the window hit-tests, as the window would hand them once key.
        let throughWindow = window.isKeyWindow && ProcessInfo.processInfo.environment["PAPER_LINK_DELIVERY"] != "view"
        if !Self.toldDelivery {
            Self.toldDelivery = true
            print("LINKCLICK-NOTE\tkey window \(window.isKeyWindow), app active \(NSApp.isActive): clicks go "
                  + (throughWindow ? "through window.sendEvent" : "to the hit-tested view's mouseDown/mouseUp"))
        }
        let target = hitView ?? webView
        if let moved = event(.mouseMoved) { webView.mouseMoved(with: moved) }
        ListTestSupport.spin(for: 0.05)
        if let down = event(.leftMouseDown) {
            if throughWindow { window.sendEvent(down) } else { target.mouseDown(with: down) }
        }
        ListTestSupport.spin(for: 0.06)
        if let up = event(.leftMouseUp) {
            if throughWindow { window.sendEvent(up) } else { target.mouseUp(with: up) }
        }
    }
    private static var toldDelivery = false

    /// What the click did, once WebKit has had time to ask: the address handed to the browser, a frame that navigated, or
    /// nothing.
    private func settle(_ recorder: Recorder, webView: WKWebView) -> String {
        ListTestSupport.spin(until: { !recorder.opened.isEmpty }, timeout: 1.0)
        ListTestSupport.spin(for: 0.15)
        if recorder.asked.contains("terminated") { return "terminated" }
        if !recorder.opened.isEmpty { return recorder.opened.map(\.absoluteString).joined(separator: " + ") }
        let frames = evaluate("""
            (function () { var fs = document.querySelectorAll('.ss-card iframe'); var out = [];
              for (var i = 0; i < fs.length; i++) { var d = null; try { d = fs[i].contentDocument; } catch (e) {}
                if (!d) { out.push('unreachable'); } else if (d.URL !== 'about:srcdoc') { out.push(d.URL); } }
              return out.join(','); })()
            """, in: webView)
        return frames.isEmpty ? "nothing" : "frame:" + frames
    }

    private func rerender(_ reader: ConversationViewController) throws {
        guard let id = reader.pool.current?.renderedID else { return }
        reader.show(nil)
        ListTestSupport.spin(for: 0.2)
        reader.show(id)
        try waitRendered(id, in: reader)
    }

    private func report(_ outcomes: [Outcome]) {
        let failing = outcomes.filter { !$0.clickOK && $0.knownGap == nil }
        print("LINKCLICK-SUMMARY\t\(failing.count) of \(outcomes.count) probes differ from a browser (known gaps aside): "
              + failing.map { "\($0.pattern) [\($0.probe)] → \($0.click)" }.joined(separator: "; "))
    }

    private func assertStrict(_ outcomes: [Outcome], file: StaticString = #filePath, line: UInt = #line) {
        guard ProcessInfo.processInfo.environment["PAPER_LINK_STRICT"] == "1" else { return }
        for outcome in outcomes where !outcome.clickOK && outcome.knownGap == nil {
            XCTFail("\(outcome.pattern) [\(outcome.probe)]: a click opened \(outcome.click), a browser opens \(outcome.expected ?? "nothing")",
                    file: file, line: line)
        }
    }

    private func evaluate(_ script: String, in webView: WKWebView) -> String {
        var answer: String?
        webView.evaluateJavaScript("(function () { var v = (\(script)); return v === null || v === undefined ? '' : String(v); })()") { value, error in
            answer = value as? String ?? (error.map { "error: \($0)" } ?? "")
        }
        ListTestSupport.spin(until: { answer != nil }, timeout: 5)
        return answer ?? ""
    }
}
