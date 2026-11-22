import XCTest
@testable import PaperCore

/// The JSON-lines reader the CLI providers feed with whatever chunks a pipe hands over.
final class JSONLineReaderTests: XCTestCase {
    private func lines(_ text: String, chunk: Int) -> [String] {
        var reader = JSONLineReader()
        let bytes = Array(text.utf8)
        var found: [Data] = []
        var index = 0
        while index < bytes.count {
            let end = min(bytes.count, index + chunk)
            found += reader.feed(bytes[index..<end])
            index = end
        }
        found += reader.finish()
        return found.map { String(decoding: $0, as: UTF8.self) }
    }

    func testLinesSurviveAnyChunking() {
        let text = "{\"type\":\"a\",\"text\":\"Grüße 🙂\"}\n{\"type\":\"b\"}\n{\"type\":\"c\"}\n"
        for chunk in [1, 2, 3, 7, 1_000] {
            XCTAssertEqual(lines(text, chunk: chunk), ["{\"type\":\"a\",\"text\":\"Grüße 🙂\"}", "{\"type\":\"b\"}", "{\"type\":\"c\"}"],
                           "chunk \(chunk)")
        }
    }

    func testCRLFAndBlankLines() {
        XCTAssertEqual(lines("{\"a\":1}\r\n\r\n   \n{\"b\":2}\r\n", chunk: 4), ["{\"a\":1}", "{\"b\":2}"])
    }

    func testTheLastLineWithoutANewlineComesAtTheEnd() {
        var reader = JSONLineReader()
        XCTAssertEqual(reader.feed(Data("{\"a\":1}\n{\"b\"".utf8)).count, 1)
        XCTAssertEqual(reader.feed(Data(":2}".utf8)), [])
        XCTAssertEqual(reader.finish().map { String(decoding: $0, as: UTF8.self) }, ["{\"b\":2}"])
        XCTAssertEqual(reader.finish(), [])
    }

    func testAnOverlongLineIsDroppedAndCounted() {
        var reader = JSONLineReader(maxLineLength: 10)
        let found = reader.feed(Data("{\"long\":\"\(String(repeating: "x", count: 50))\"}\n{\"ok\":1}\n".utf8))
        XCTAssertEqual(found.map { String(decoding: $0, as: UTF8.self) }, ["{\"ok\":1}"])
        XCTAssertEqual(reader.droppedLines, 1)
    }

    func testEveryLineIsReadyForJSONSerialization() throws {
        var reader = JSONLineReader()
        let found = reader.feed(Data("{\"type\":\"result\",\"is_error\":false}\n".utf8))
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(found.first)) as? [String: Any])
        XCTAssertEqual(object["type"] as? String, "result")
    }
}
