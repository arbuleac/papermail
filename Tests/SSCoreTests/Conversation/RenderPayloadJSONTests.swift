import JavaScriptCore
import XCTest
@testable import SSCore

/// The JSON keys are the contract between `RenderPayload` and the shell script. These snapshots make a
/// rename on either side fail here rather than render blank cards.
final class RenderPayloadJSONTests: XCTestCase {
    static let expectedTopLevelKeys = ["messages", "subject"]
    static let expectedMessageKeys = [
        "attachments", "blockedRemoteImageCount", "cc", "dateDisplay", "dateISO", "from", "hasBody",
        "hasQuotedContent", "html", "id", "isStarred", "isUnread", "snippet", "to",
    ]
    static let expectedSenderKeys = ["address", "color", "initials", "name"]
    static let expectedAttachmentKeys = ["id", "mime", "name", "size"]

    private func samplePayload(html: String = "<p>Hello</p>") -> RenderPayload {
        RenderPayload(
            subject: "Engines",
            messages: [
                RenderPayload.Message(
                    id: "acct|m1",
                    from: RenderPayload.Sender(name: "Ada", address: "ada@example.com", initials: "A", color: "#1E88E5"),
                    to: "me",
                    cc: "",
                    dateISO: "2025-03-07T14:05:00Z",
                    dateDisplay: "Today 14:05",
                    snippet: "Hello",
                    isUnread: true,
                    isStarred: false,
                    hasBody: true,
                    html: html,
                    hasQuotedContent: false,
                    blockedRemoteImageCount: 0,
                    attachments: [RenderPayload.Attachment(id: "att-1", name: "plan.pdf", size: "1.2 MB", mime: "application/pdf")]
                ),
            ]
        )
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
    }

    func testShellScriptReadsEveryPayloadKey() {
        let script = ConversationShellAssets.js
        let keys = Self.expectedTopLevelKeys + Self.expectedMessageKeys + Self.expectedSenderKeys + Self.expectedAttachmentKeys
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
        XCTAssertTrue(ConversationShellAssets.css.contains("prefers-color-scheme: dark"))
        XCTAssertTrue(ConversationShellAssets.css.contains("border-radius: 12px"))
        XCTAssertTrue(ConversationShellAssets.bodyCSS.contains(".ss-quote { display: none; }"))
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
