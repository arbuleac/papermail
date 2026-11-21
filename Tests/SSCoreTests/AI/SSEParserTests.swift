import XCTest
@testable import SSCore

/// The event-stream parser the Anthropic and OpenAI providers feed byte by byte.
final class SSEParserTests: XCTestCase {
    private func parse(_ text: String, chunks: Int? = nil) -> [SSEEvent] {
        var parser = SSEParser()
        let bytes = Array(text.utf8)
        var events: [SSEEvent] = []
        if let chunks {
            var index = 0
            while index < bytes.count {
                let end = min(bytes.count, index + chunks)
                events += parser.feed(bytes[index..<end])
                index = end
            }
        } else {
            events += parser.feed(bytes)
        }
        if let last = parser.finish() { events.append(last) }
        return events
    }

    func testAnEventIsItsNameAndDataEndedByABlankLine() {
        let events = parse("event: content_block_delta\ndata: {\"a\":1}\n\nevent: ping\ndata: {}\n\n")
        XCTAssertEqual(events, [SSEEvent(event: "content_block_delta", data: "{\"a\":1}"), SSEEvent(event: "ping", data: "{}")])
    }

    func testAStreamThatNamesNoEventGetsMessage() {
        XCTAssertEqual(parse("data: hello\n\n"), [SSEEvent(event: "message", data: "hello")])
    }

    func testDataLinesJoinWithNewlines() {
        XCTAssertEqual(parse("data: one\ndata: two\ndata:\ndata: four\n\n"), [SSEEvent(data: "one\ntwo\n\nfour")])
    }

    func testOnlyOneLeadingSpaceIsDroppedFromAValue() {
        XCTAssertEqual(parse("data:no space\n\ndata:  two spaces\n\n").map(\.data), ["no space", " two spaces"])
    }

    func testCRLFAndBareCREndLines() {
        XCTAssertEqual(parse("event: a\r\ndata: 1\r\n\r\nevent: b\rdata: 2\r\r"),
                       [SSEEvent(event: "a", data: "1"), SSEEvent(event: "b", data: "2")])
    }

    func testACRAndItsLFInDifferentChunksMakeOneLineEnd() {
        var parser = SSEParser()
        XCTAssertEqual(parser.feed(Array("data: x\r".utf8)), [])
        // The LF completing the CRLF is not a second, blank line: the event is still open.
        XCTAssertEqual(parser.feed(Array("\n".utf8)), [])
        XCTAssertEqual(parser.feed(Array("\r\n".utf8)), [SSEEvent(data: "x")])
    }

    func testCommentsAndUnknownFieldsAreIgnored() {
        let events = parse(": Intermediate response events omitted.\nevent: e\nfoo: bar\nretry: 10\ndata: d\n\n:keepalive\n\n")
        XCTAssertEqual(events, [SSEEvent(event: "e", data: "d")])
    }

    func testAnEventWithoutDataIsNotDispatchedAndItsNameDoesNotLeak() {
        let events = parse("event: lonely\n\ndata: next\n\n")
        XCTAssertEqual(events, [SSEEvent(event: "message", data: "next")])
    }

    func testAFieldWithoutAColonHasAnEmptyValue() {
        XCTAssertEqual(parse("data\n\n"), [SSEEvent(data: "")])
    }

    func testTheLastIDCarriesOver() {
        let events = parse("id: 7\ndata: a\n\ndata: b\n\nid: 8\ndata: c\n\n")
        XCTAssertEqual(events.map(\.id), ["7", "7", "8"])
    }

    func testALeadingByteOrderMarkIsDropped() {
        XCTAssertEqual(parse("\u{FEFF}data: x\n\n"), [SSEEvent(data: "x")])
    }

    func testACharacterSplitAcrossChunksIsDecodedWhole() {
        let text = "data: Grüße 你好 🙂\n\n"
        for size in 1...5 {
            XCTAssertEqual(parse(text, chunks: size), [SSEEvent(data: "Grüße 你好 🙂")], "chunk size \(size)")
        }
    }

    func testByteByByteMatchesWholeFeeds() {
        let stream = """
        event: message_start\r
        data: {"type":"message_start"}\r
        \r
        : ping\r
        event: content_block_delta\r
        data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"Hi"}}\r
        \r

        """
        var parser = SSEParser()
        var oneByOne: [SSEEvent] = []
        for byte in stream.utf8 { if let event = parser.feed(byte) { oneByOne.append(event) } }
        XCTAssertEqual(oneByOne, parse(stream))
        XCTAssertEqual(oneByOne.map(\.event), ["message_start", "content_block_delta"])
    }

    func testAnEventTheServerDidNotCloseIsDispatchedAtTheEnd() {
        XCTAssertEqual(parse("event: message_stop\ndata: {\"type\":\"message_stop\"}"),
                       [SSEEvent(event: "message_stop", data: "{\"type\":\"message_stop\"}")])
        XCTAssertEqual(parse("event: response.completed\ndata: {}\n"), [SSEEvent(event: "response.completed", data: "{}")])
        XCTAssertEqual(parse(""), [])
    }

    func testAnOverlongLineIsDroppedAndTheStreamGoesOn() {
        var parser = SSEParser(maxLineLength: 16)
        var events = parser.feed(Array("data: \(String(repeating: "x", count: 100))\n\ndata: short\n\n".utf8))
        if let last = parser.finish() { events.append(last) }
        XCTAssertEqual(events, [SSEEvent(data: "short")])
    }

    func testOpenAIsDocumentedStreamParses() {
        let stream = """
        event: response.created
        data: {"type":"response.created","sequence_number":0}

        event: response.output_text.delta
        data: {"type":"response.output_text.delta","delta":"Hi","sequence_number":4}

        : Intermediate response events omitted.

        event: response.completed
        data: {"type":"response.completed","sequence_number":13}


        """
        let events = parse(stream)
        XCTAssertEqual(events.map(\.event), ["response.created", "response.output_text.delta", "response.completed"])
        for event in events {
            let object = try? JSONSerialization.jsonObject(with: Data(event.data.utf8)) as? [String: Any]
            XCTAssertEqual(object?["type"] as? String, event.event)
        }
    }
}
