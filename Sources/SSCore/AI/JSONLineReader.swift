import Foundation

/// Complete lines from a JSON-lines stream (Claude Code's `stream-json`, Codex's `exec --json`), incrementally, as
/// `Data` ready for `JSONSerialization`. A process pipe hands over chunks that split lines anywhere, characters included.
/// Blank lines are skipped and a trailing CR is dropped.
public struct JSONLineReader: Sendable {
    /// Longer lines are dropped whole (counted in `droppedLines`) so a runaway process cannot grow memory without
    /// bound. Claude Code's `init` line runs to several kilobytes; a reply line is far below this.
    public static let defaultMaxLineLength = 4 * 1024 * 1024

    private let maxLineLength: Int
    private var line = Data()
    private var lineTooLong = false
    /// Lines dropped for exceeding the cap.
    public private(set) var droppedLines = 0

    public init(maxLineLength: Int = JSONLineReader.defaultMaxLineLength) {
        self.maxLineLength = maxLineLength
    }

    /// Feeds a chunk; returns the lines it completed, in order.
    public mutating func feed<Bytes: Sequence>(_ bytes: Bytes) -> [Data] where Bytes.Element == UInt8 {
        var lines: [Data] = []
        for byte in bytes {
            if byte == 0x0A {
                if let complete = endLine() { lines.append(complete) }
            } else if line.count < maxLineLength {
                line.append(byte)
            } else {
                lineTooLong = true
            }
        }
        return lines
    }

    /// The end of the stream: the last line, when it had no newline.
    public mutating func finish() -> [Data] {
        endLine().map { [$0] } ?? []
    }

    private mutating func endLine() -> Data? {
        defer {
            line.removeAll(keepingCapacity: true)
            lineTooLong = false
        }
        if lineTooLong {
            droppedLines += 1
            return nil
        }
        var complete = line
        if complete.last == 0x0D { complete.removeLast() }
        guard complete.contains(where: { !Self.isWhitespace($0) }) else { return nil }
        return complete
    }

    private static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0D
    }
}
