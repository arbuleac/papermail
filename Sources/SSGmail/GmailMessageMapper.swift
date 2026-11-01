import Foundation
import SSCore

/// Turns a `messages.get?format=metadata` result into the metadata the store keeps.
enum GmailMessageMapper {
    static func metadata(from message: GmailMessage, accountID: AccountID) -> MessageMetadata {
        let labels = message.labelIds ?? []
        let payload = message.payload
        let header: (String) -> String? = { payload?.header($0) }

        return MessageMetadata(
            id: MessageID(accountID: accountID, providerID: message.id),
            conversationID: ConversationID(accountID: accountID, providerID: message.threadId),
            internetMessageID: header("Message-ID").map(trimmedID).flatMap { $0.isEmpty ? nil : $0 },
            inReplyTo: header("In-Reply-To").map(trimmedID).flatMap { $0.isEmpty ? nil : $0 },
            references: header("References").map(referenceList) ?? [],
            subject: header("Subject").map { RFC2047.decode($0).trimmingCharacters(in: .whitespacesAndNewlines) } ?? "",
            snippet: decodeSnippet(message.snippet ?? ""),
            from: header("From").flatMap(AddressParser.first),
            to: header("To").map(AddressParser.parse) ?? [],
            cc: header("Cc").map(AddressParser.parse) ?? [],
            bcc: header("Bcc").map(AddressParser.parse) ?? [],
            replyTo: header("Reply-To").map(AddressParser.parse) ?? [],
            date: date(internalDate: message.internalDate, dateHeader: header("Date")),
            roles: roles(from: labels),
            isRead: !labels.contains("UNREAD"),
            isStarred: labels.contains("STARRED"),
            inboxSection: section(from: labels),
            hasAttachments: hasAttachments(payload),
            labelIDs: labels,
            folderID: nil,
            providerVersion: message.historyId,
            sizeBytes: message.sizeEstimate
        )
    }

    static func roles(from labels: [String]) -> Set<MailboxRole> {
        var roles: Set<MailboxRole> = []
        for label in labels {
            switch label {
            case "INBOX": roles.insert(.inbox)
            case "SENT": roles.insert(.sent)
            case "DRAFT": roles.insert(.drafts)
            case "TRASH": roles.insert(.trash)
            case "SPAM": roles.insert(.spam)
            default: break
            }
        }
        return roles
    }

    /// Primary is the only category the Focused toggle shows; a message with no category at all (older
    /// mail, or accounts with tabs off) belongs there too, otherwise it would vanish from both views.
    static func section(from labels: [String]) -> InboxSection {
        let categories = labels.filter { $0.hasPrefix("CATEGORY_") }
        if categories.isEmpty || categories.contains("CATEGORY_PERSONAL") { return .focused }
        return .other
    }

    /// The metadata format omits parts, so the top-level content type is the only attachment signal
    /// available without a full fetch; multipart/mixed is what every mailer uses for real attachments.
    static func hasAttachments(_ payload: GmailPart?) -> Bool {
        guard let payload else { return false }
        if payload.parts != nil { return payload.containsNamedPart }
        return payload.mimeType?.lowercased() == "multipart/mixed"
    }

    static func date(internalDate: String?, dateHeader: String?) -> Date {
        if let internalDate, let milliseconds = Int64(internalDate) {
            return Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1000)
        }
        if let dateHeader, let parsed = parseRFC5322Date(dateHeader) {
            return parsed
        }
        return Date(timeIntervalSince1970: 0)
    }

    static func trimmedID(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func referenceList(_ value: String) -> [String] {
        value.split(whereSeparator: \.isWhitespace).map(String.init).filter { !$0.isEmpty }
    }

    /// Gmail HTML-escapes snippets; the list shows them as text, so entities must come back out.
    static func decodeSnippet(_ snippet: String) -> String {
        guard snippet.contains("&") else { return snippet.trimmingCharacters(in: .whitespacesAndNewlines) }
        var result = ""
        var remainder = Substring(snippet)
        while let ampersand = remainder.firstIndex(of: "&") {
            result += remainder[..<ampersand]
            let afterAmpersand = remainder[remainder.index(after: ampersand)...]
            guard let semicolon = afterAmpersand.firstIndex(of: ";"),
                  afterAmpersand.distance(from: afterAmpersand.startIndex, to: semicolon) <= 8,
                  let decoded = decodeEntity(String(afterAmpersand[..<semicolon])) else {
                result.append("&")
                remainder = afterAmpersand
                continue
            }
            result += decoded
            remainder = afterAmpersand[afterAmpersand.index(after: semicolon)...]
        }
        result += remainder
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func decodeEntity(_ entity: String) -> String? {
        switch entity {
        case "amp": return "&"
        case "lt": return "<"
        case "gt": return ">"
        case "quot": return "\""
        case "apos": return "'"
        case "nbsp": return "\u{00A0}"
        default:
            guard entity.hasPrefix("#") else { return nil }
            let number = entity.dropFirst()
            let value: UInt32?
            if number.hasPrefix("x") || number.hasPrefix("X") {
                value = UInt32(number.dropFirst(), radix: 16)
            } else {
                value = UInt32(number)
            }
            guard let value, let scalar = Unicode.Scalar(value) else { return nil }
            return String(Character(scalar))
        }
    }

    private static func parseRFC5322Date(_ raw: String) -> Date? {
        // Trailing comments such as "(UTC)" are legal and common; the formatter cannot see past them.
        var text = raw
        if let paren = text.firstIndex(of: "(") { text = String(text[..<paren]) }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        for format in ["EEE, d MMM yyyy HH:mm:ss Z", "d MMM yyyy HH:mm:ss Z", "EEE, d MMM yyyy HH:mm Z", "EEE, d MMM yyyy HH:mm:ss zzz"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }
}
