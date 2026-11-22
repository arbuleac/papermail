import Foundation

/// Server-sent events from bytes, incrementally (the WHATWG event-stream format the Anthropic and OpenAI streams use).
/// Pure and byte-driven so a provider can feed `URLSession.AsyncBytes` one byte at a time: `AsyncBytes.lines` would
/// drop the blank lines that end events. Lines may end in CRLF, LF or CR, a CR and its LF may arrive in different
/// chunks, and a character split across chunks is decoded once its line is whole.
public struct SSEParser: Sendable {
    /// Longer lines are dropped whole rather than held: a stream that never sends a newline cannot grow memory without
    /// bound. Generous, because a final event (OpenAI's `response.completed`) repeats the whole reply.
    public static let defaultMaxLineLength = 4 * 1024 * 1024

    private let maxLineLength: Int
    private var line: [UInt8] = []
    private var lineTooLong = false
    private var afterCR = false
    private var atStreamStart = true
    private var eventType = ""
    private var dataLines: [String] = []
    private var lastEventID: String?

    public init(maxLineLength: Int = SSEParser.defaultMaxLineLength) {
        self.maxLineLength = maxLineLength
    }

    /// Feeds one byte; returns the event a blank line completed, if any.
    public mutating func feed(_ byte: UInt8) -> SSEEvent? {
        switch byte {
        case 0x0A:
            if afterCR {
                afterCR = false
                return nil
            }
            return endLine()
        case 0x0D:
            afterCR = true
            return endLine()
        default:
            afterCR = false
            if line.count < maxLineLength {
                line.append(byte)
            } else {
                lineTooLong = true
            }
            return nil
        }
    }

    /// Feeds a chunk; returns the events it completed, in order.
    public mutating func feed<Bytes: Sequence>(_ bytes: Bytes) -> [SSEEvent] where Bytes.Element == UInt8 {
        var events: [SSEEvent] = []
        for byte in bytes {
            if let event = feed(byte) { events.append(event) }
        }
        return events
    }

    /// The end of the stream. The spec discards an event the server did not close with a blank line; this dispatches
    /// it, since a terminal event (`message_stop`, `response.completed`) lost to a connection that closed early is
    /// worse than leniency.
    public mutating func finish() -> SSEEvent? {
        var pending: SSEEvent?
        if !line.isEmpty || lineTooLong { pending = endLine() }
        afterCR = false
        return pending ?? dispatch()
    }

    private mutating func endLine() -> SSEEvent? {
        defer {
            line.removeAll(keepingCapacity: true)
            lineTooLong = false
        }
        if lineTooLong { return nil }
        var text = String(decoding: line, as: UTF8.self)
        if atStreamStart {
            atStreamStart = false
            if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        }
        if text.isEmpty { return dispatch() }
        if text.hasPrefix(":") { return nil }
        let field: Substring
        var value: Substring
        if let colon = text.firstIndex(of: ":") {
            field = text[..<colon]
            value = text[text.index(after: colon)...]
            if value.hasPrefix(" ") { value = value.dropFirst() }
        } else {
            field = text[...]
            value = ""
        }
        switch field {
        case "event": eventType = String(value)
        case "data": dataLines.append(String(value))
        case "id": if !value.contains("\u{0}") { lastEventID = String(value) }
        default: break
        }
        return nil
    }

    private mutating func dispatch() -> SSEEvent? {
        defer {
            eventType = ""
            dataLines.removeAll(keepingCapacity: true)
        }
        guard !dataLines.isEmpty else { return nil }
        return SSEEvent(event: eventType.isEmpty ? "message" : eventType, data: dataLines.joined(separator: "\n"), id: lastEventID)
    }
}
