import Foundation
import SSCore

/// One embedded response of a `multipart/mixed` batch reply.
struct GmailBatchPart: Sendable {
    var index: Int?
    var status: Int
    var headers: [String: String]
    var body: Data
}

enum GmailBatchError: Error, Sendable {
    /// The reply was not the multipart shape the batch endpoint documents; callers fall back to single gets.
    case unparseable(String)
}

/// Builds and parses the `multipart/mixed` envelope of the Gmail batch endpoint. Each part wraps a complete
/// HTTP request or response, so the parser is a small HTTP-in-MIME reader rather than a JSON decoder.
enum GmailBatch {
    static let maxPartsPerBatch = 50

    /// Content-ID of request `index`; Google echoes it back as `response-<id>` so parts can be matched
    /// without trusting their order.
    static func contentID(for index: Int) -> String { "item-\(index)" }

    static func request(paths: [String], boundary: String) throws -> GmailRequest {
        var body = ""
        for (index, path) in paths.enumerated() {
            body += "--\(boundary)\r\n"
            body += "Content-Type: application/http\r\n"
            body += "Content-ID: <\(contentID(for: index))>\r\n"
            body += "\r\n"
            body += "GET \(path) HTTP/1.1\r\n"
            body += "\r\n\r\n"
        }
        body += "--\(boundary)--\r\n"
        return GmailRequest(
            method: .post,
            url: try GmailRequest.batchURL(),
            headers: ["Content-Type": "multipart/mixed; boundary=\(boundary)"],
            body: Data(body.utf8)
        )
    }

    static func parse(_ data: Data, contentType: String?) throws -> [GmailBatchPart] {
        guard let boundary = boundary(from: contentType) else {
            throw GmailBatchError.unparseable("No multipart boundary in Content-Type")
        }
        // Google's batch replies are JSON in UTF-8, so a lossy decode only ever touches malformed input.
        let text = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\r\n", with: "\n")
        let delimiter = "--" + boundary
        var pieces = text.components(separatedBy: delimiter)
        guard pieces.count >= 2 else {
            throw GmailBatchError.unparseable("Boundary never occurs in body")
        }
        pieces.removeFirst()
        var parts: [GmailBatchPart] = []
        for piece in pieces {
            if piece.hasPrefix("--") { break }
            let trimmed = piece.drop { $0 == "\n" }
            guard !trimmed.isEmpty else { continue }
            parts.append(try parsePart(String(trimmed)))
        }
        guard !parts.isEmpty else {
            throw GmailBatchError.unparseable("No parts between boundaries")
        }
        return parts
    }

    private static func parsePart(_ piece: String) throws -> GmailBatchPart {
        let (outerHeaders, embedded) = splitHeaders(piece)
        var index: Int?
        if let id = outerHeaders["content-id"] {
            let bare = id.trimmingCharacters(in: CharacterSet(charactersIn: "<> "))
            let suffix = bare.hasPrefix("response-") ? String(bare.dropFirst("response-".count)) : bare
            if suffix.hasPrefix("item-") { index = Int(suffix.dropFirst("item-".count)) }
        }
        let (innerHeaders, body) = splitHeaders(String(embedded.drop(while: { $0 == "\n" })))
        guard let statusLine = innerHeaders["status-line"] else {
            throw GmailBatchError.unparseable("Missing status line")
        }
        let tokens = statusLine.split(separator: " ")
        guard tokens.count >= 2, tokens[0].hasPrefix("HTTP/"), let status = Int(tokens[1]) else {
            throw GmailBatchError.unparseable("Bad status line")
        }
        var headers = innerHeaders
        headers["status-line"] = nil
        let trimmedBody = body.trimmingCharacters(in: .newlines)
        return GmailBatchPart(index: index, status: status, headers: headers, body: Data(trimmedBody.utf8))
    }

    /// Splits "headers\n\nrest"; the first line is stored under `status-line` when it is not a header.
    private static func splitHeaders(_ text: String) -> ([String: String], String) {
        var headers: [String: String] = [:]
        var rest = ""
        let lines = text.components(separatedBy: "\n")
        var seenBlank = false
        var bodyLines: [String] = []
        for (lineIndex, line) in lines.enumerated() {
            if seenBlank {
                bodyLines.append(line)
                continue
            }
            if line.isEmpty {
                seenBlank = true
                continue
            }
            if let colon = line.firstIndex(of: ":"), !line.hasPrefix("HTTP/") {
                let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                headers[name] = value
            } else if lineIndex == 0 {
                headers["status-line"] = line
            }
        }
        rest = bodyLines.joined(separator: "\n")
        return (headers, rest)
    }

    static func boundary(from contentType: String?) -> String? {
        guard let contentType else { return nil }
        for parameter in contentType.split(separator: ";").dropFirst() {
            let pair = parameter.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard pair.count == 2, pair[0].lowercased() == "boundary" else { continue }
            let value = pair[1].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            return value.isEmpty ? nil : value
        }
        return nil
    }
}
