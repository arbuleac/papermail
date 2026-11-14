import JavaScriptCore
import XCTest
@testable import SSCore

/// The JSON keys are the contract between `RenderPayload` and the shell script. These snapshots make a
/// rename on either side fail here rather than render blank cards.
final class RenderPayloadJSONTests: XCTestCase {
    static let expectedTopLevelKeys = [
        "colorsNoticeDismissed", "inkSlot", "loadRemoteImages", "messages", "participants", "readingSans", "subject", "textSize",
    ]
    static let expectedMessageKeys = [
        "attachments", "blockedRemoteImageCount", "bodyState", "cancelsSendLater", "cc", "coveredByNewYork", "dateDisplay", "dateISO",
        "declaresColors", "from", "hasAttachments", "hasBody", "hasQuotedContent", "html", "id", "isDraft", "isPending", "isStarred", "isUnread",
        "recipients", "snippet", "to", "typesetting", "unsubscribe",
    ]
    static let expectedSenderKeys = ["address", "initials", "name", "tint"]
    static let expectedAttachmentKeys = ["id", "kind", "mime", "name", "size", "symbol"]
    static let expectedRecipientFieldKeys = ["label", "people"]
    static let expectedPersonKeys = ["address", "name"]

    private func samplePayload(html: String = "<p>Hello</p>") -> RenderPayload {
        RenderPayload(
            subject: "Engines",
            messages: [
                RenderPayload.Message(
                    id: "acct|m1",
                    from: RenderPayload.Sender(name: "Ada", address: "ada@example.com", initials: "A", tint: 4),
                    to: "me",
                    cc: "",
                    recipients: [RenderPayload.RecipientField(label: "To", people: [RenderPayload.Person(name: "me", address: "me@example.com")])],
                    dateISO: "2025-03-07T14:05:00Z",
                    dateDisplay: "Today 14:05",
                    snippet: "Hello",
                    isUnread: true,
                    isStarred: false,
                    hasBody: true,
                    html: html,
                    hasQuotedContent: false,
                    blockedRemoteImageCount: 0,
                    attachments: [RenderPayload.Attachment(id: "att-1", name: "plan.pdf", size: "1.2 MB", mime: "application/pdf",
                                                           symbol: "doc", kind: "PDF")],
                    typesetting: .unstyled,
                    declaresColors: false,
                    coveredByNewYork: true
                ),
            ],
            inkSlot: 3
        )
    }

    func testBodyStateTravelsByName() throws {
        let data = try JSONEncoder().encode(samplePayload())
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let message = try XCTUnwrap((object["messages"] as? [[String: Any]])?.first)
        XCTAssertEqual(message["bodyState"] as? String, "ready")
        XCTAssertEqual(RenderPayload.BodyState.allCases.map(\.rawValue), ["ready", "loading", "offline", "failed", "inComposer"])
        for state in RenderPayload.BodyState.allCases {
            XCTAssertTrue(ConversationShellAssets.js.contains("'" + state.rawValue + "'") || state == .ready,
                          "the shell never names `\(state.rawValue)`")
        }
    }

    func testDesignFactsEncodeAsTheShellReadsThem() throws {
        let data = try JSONEncoder().encode(samplePayload())
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["inkSlot"] as? Int, 3)
        let message = try XCTUnwrap((object["messages"] as? [[String: Any]])?.first)
        // The shell compares names, so the typesetting must travel as its name rather than a number.
        XCTAssertEqual(message["typesetting"] as? String, "unstyled")
        XCTAssertEqual(message["declaresColors"] as? Bool, false)
        XCTAssertEqual(message["coveredByNewYork"] as? Bool, true)
        XCTAssertEqual(message["hasBody"] as? Bool, true)
    }

    func testEncodedKeysMatchSnapshot() throws {
        let data = try JSONEncoder().encode(samplePayload())
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object.keys.sorted(), Self.expectedTopLevelKeys)
        let messages = try XCTUnwrap(object["messages"] as? [[String: Any]])
        let message = try XCTUnwrap(messages.first)
        XCTAssertEqual(message.keys.sorted(), Self.expectedMessageKeys)
        let sender = try XCTUnwrap(message["from"] as? [String: Any])
        XCTAssertEqual(sender.keys.sorted(), Self.expectedSenderKeys)
        let attachments = try XCTUnwrap(message["attachments"] as? [[String: Any]])
        XCTAssertEqual(try XCTUnwrap(attachments.first).keys.sorted(), Self.expectedAttachmentKeys)
        let fields = try XCTUnwrap(message["recipients"] as? [[String: Any]])
        XCTAssertEqual(try XCTUnwrap(fields.first).keys.sorted(), Self.expectedRecipientFieldKeys)
        let people = try XCTUnwrap(fields.first?["people"] as? [[String: Any]])
        XCTAssertEqual(try XCTUnwrap(people.first).keys.sorted(), Self.expectedPersonKeys)
    }

    func testShellScriptReadsEveryPayloadKey() {
        let script = ConversationShellAssets.js
        let keys = Self.expectedTopLevelKeys + Self.expectedMessageKeys + Self.expectedSenderKeys + Self.expectedAttachmentKeys
            + Self.expectedRecipientFieldKeys + Self.expectedPersonKeys
        for key in keys {
            XCTAssertTrue(script.contains("." + key), "the shell never reads `\(key)`")
        }
    }

    func testJSONRoundTrips() throws {
        let payload = samplePayload(html: "<p>Zoë – “quotes” \u{2028} line</p>")
        let data = Data(try payload.jsonString().utf8)
        XCTAssertEqual(try JSONDecoder().decode(RenderPayload.self, from: data), payload)
    }

    func testJSONStringIsInertInsideScriptContext() throws {
        let json = try samplePayload(html: "<script>alert(1)</script>").jsonString()
        XCTAssertFalse(json.contains("</script>"))
        XCTAssertTrue(json.contains("<\\/script>"))
    }

    func testMessageKeyRoundTripsProviderIDsWithSeparators() throws {
        let id = MessageID(accountID: AccountID("acct-1"), providerID: "AAMkAD|x/y=")
        let key = RenderPayload.messageKey(for: id)
        XCTAssertEqual(RenderPayload.messageID(fromKey: key), id)
        XCTAssertNil(RenderPayload.messageID(fromKey: "no-separator"))
        XCTAssertNil(RenderPayload.messageID(fromKey: "|missing-account"))
        XCTAssertNil(RenderPayload.messageID(fromKey: "missing-provider|"))
    }

    func testShellDocumentWiresHandlersAndAssets() {
        let html = ConversationShellAssets.html
        XCTAssertTrue(html.contains(ConversationShellAssets.css))
        XCTAssertTrue(html.contains(ConversationShellAssets.js))
        XCTAssertTrue(ConversationShellAssets.js.contains("'" + ConversationShellAssets.readyHandlerName + "'"))
        XCTAssertTrue(ConversationShellAssets.js.contains("'" + ConversationShellAssets.messageHandlerName + "'"))
        XCTAssertTrue(ConversationShellAssets.js.contains("window.webkit"))
        XCTAssertEqual(ConversationShellAssets.baseURL?.scheme, "ss-shell")
        XCTAssertEqual(ConversationShellAssets.baseURL?.host, "local")
        XCTAssertTrue(ConversationShellAssets.js.contains("sandbox', 'allow-same-origin'"))
        XCTAssertTrue(ConversationShellAssets.css.hasPrefix(QuireCSS.head), "the Quire head comes first (spec §8.4)")
        XCTAssertTrue(ConversationShellAssets.css.contains("--ss-card: var(--q-sheet)"), "old variable names map onto Quire")
        XCTAssertTrue(ConversationShellAssets.bodyCSS.contains(".ss-quote { display: none; }"))
        let withSymbols = ConversationShellAssets.document(symbolCSS: ":root{--sym-star:url(data:x)}")
        XCTAssertTrue(withSymbols.contains(":root{--sym-star:url(data:x)}"))
    }

    /// Spec §8.4: no hex colour is written by hand in the shell; every colour comes from a Quire variable.
    func testShellCSSDrawsOnlyWithQuireVariables() {
        for css in [ConversationShellAssets.shellCSS] {
            let hex = css.range(of: "#[0-9A-Fa-f]{3,8}\\b", options: .regularExpression)
            XCTAssertNil(hex, "hand-written colour: \(hex.map { String(css[$0]) } ?? "")")
            XCTAssertFalse(css.contains("rgba("), "hand-written colour")
        }
    }

    /// The body documents carry the variables they use, in every block of the head (IC and Graphite included).
    func testBodyDocumentsCarryTheirVariables() {
        let variables = ConversationShellAssets.bodyVariables
        for needle in ["--q-ink:", "--q-accent:", "--q-rule:", "--q-focus:", "--q-originalPage:", "--q-font-reading:",
                       "--q-font-readingSans:", "html.ss-ic{", "html.ss-graphite{", "@media (prefers-color-scheme:dark){:root{",
                       "html.ss-text-small{--q-font-reading:400 14px/23px", "html.ss-text-larger{--q-font-reading:400 17px/26px"] {
            XCTAssertTrue(variables.contains(needle), needle)
        }
        XCTAssertFalse(variables.contains("--q-spine:"), "only what bodies use")
        for line in variables.components(separatedBy: "\n") {
            XCTAssertEqual(line.filter { $0 == "{" }.count, line.filter { $0 == "}" }.count, "balanced: \(line.prefix(60))")
        }
    }

    /// Parses the shell script with JavaScriptCore without running it, so a syntax slip fails headlessly.
    func testShellScriptParses() throws {
        let context = try XCTUnwrap(JSContext())
        var reported: String?
        context.exceptionHandler = { _, exception in reported = exception?.toString() }
        context.evaluateScript("(function () {\n" + ConversationShellAssets.js + "\n});")
        XCTAssertNil(reported, "shell script does not parse: \(reported ?? "")")
    }
}
