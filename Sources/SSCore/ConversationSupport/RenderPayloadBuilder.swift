import Foundation

/// Turns stored metadata and bodies into a `RenderPayload`. Pure: no store access, no HTML parsing.
///
/// Dates, initials and colors are derived here rather than in JavaScript so the shell stays a dumb
/// renderer and the rules can be unit tested without WebKit.
public struct RenderPayloadBuilder: Sendable {
    public var calendar: Calendar
    public var locale: Locale
    public var timeZone: TimeZone

    public init(calendar: Calendar = .current, locale: Locale = .current, timeZone: TimeZone = .current) {
        self.calendar = calendar
        self.locale = locale
        self.timeZone = timeZone
    }

    // MARK: Building

    /// - Parameters:
    ///   - messages: a conversation's messages in any order; trash and spam are filtered like the list does.
    ///   - bodies: stored bodies keyed by message; missing ones get a snippet fallback.
    ///   - subject: overrides the first non-empty message subject when the caller already has it.
    public func build(
        messages: [MessageMetadata],
        bodies: [MessageID: StoredBody],
        accounts: [AccountID: Account],
        subject: String? = nil,
        now: Date = Date()
    ) -> RenderPayload {
        let visible = Self.visibleMessages(messages)
        let formatters = makeFormatters()
        let ownAddresses = Set(accounts.values.map { $0.email.lowercased() })
        let rendered = visible.map { message -> RenderPayload.Message in
            let body = bodies[message.id]
            let html = Self.html(for: message, body: body)
            return RenderPayload.Message(
                id: RenderPayload.messageKey(for: message.id),
                from: Self.sender(for: message.from),
                to: Self.recipientsDisplay(message.to, ownAddresses: ownAddresses),
                cc: Self.recipientsDisplay(message.cc, ownAddresses: ownAddresses),
                dateISO: formatters.iso.string(from: message.date),
                dateDisplay: dateDisplay(for: message.date, now: now, formatters: formatters),
                snippet: message.snippet,
                isUnread: !message.isRead,
                isStarred: message.isStarred,
                hasBody: body != nil,
                html: html,
                hasQuotedContent: Self.hasQuotedContent(in: html),
                blockedRemoteImageCount: Self.blockedRemoteImageCount(in: html),
                attachments: (body?.body.attachments ?? [])
                    .filter { !$0.isInline }
                    .map { attachment in
                        RenderPayload.Attachment(
                            id: attachment.id,
                            name: attachment.filename.isEmpty ? "Attachment" : attachment.filename,
                            size: Self.sizeString(bytes: attachment.sizeBytes),
                            mime: attachment.mimeType
                        )
                    }
            )
        }
        let resolvedSubject = subject ?? Self.subject(of: visible)
        return RenderPayload(subject: resolvedSubject, messages: rendered)
    }

    /// Same rule as the conversation summary: spam never shows; trashed messages show only when the whole
    /// conversation is in the trash. Oldest first.
    public static func visibleMessages(_ messages: [MessageMetadata]) -> [MessageMetadata] {
        let nonSpam = messages
            .filter { !$0.roles.contains(.spam) }
            .sorted { ($0.date, $0.id.providerID) < ($1.date, $1.id.providerID) }
        let notTrashed = nonSpam.filter { !$0.roles.contains(.trash) }
        return notTrashed.isEmpty ? nonSpam : notTrashed
    }

    public static func subject(of messages: [MessageMetadata]) -> String {
        messages.first { !$0.subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }?.subject ?? ""
    }

    // MARK: Sender

    public static func sender(for address: EmailAddress?) -> RenderPayload.Sender {
        guard let address else {
            return RenderPayload.Sender(name: "Unknown sender", address: "", initials: "?", color: palette[0])
        }
        let name = address.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return RenderPayload.Sender(
            name: name.isEmpty ? address.shortDisplay : name,
            address: address.address,
            initials: initials(name: address.name, address: address.address),
            color: avatarColor(name: address.name, address: address.address)
        )
    }

    /// First letter of the first and last word of the name, or of the address's local part when there is
    /// no name ("ada.lovelace@…" → "AL"). Grapheme-based so accented and CJK characters survive.
    public static func initials(name: String?, address: String) -> String {
        let trimmedName = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let source: String
        if !trimmedName.isEmpty {
            source = trimmedName
        } else {
            source = address.split(separator: "@", maxSplits: 1).first.map(String.init) ?? address
        }
        let words = source
            .split { $0.isWhitespace || "._-,/+".contains($0) }
            .map { word -> String in
                var trimmed = Substring(word)
                while let first = trimmed.first, !(first.isLetter || first.isNumber) { trimmed = trimmed.dropFirst() }
                return String(trimmed)
            }
            .filter { !$0.isEmpty }
        guard let first = words.first?.first else { return "?" }
        if words.count == 1 { return String(first).uppercased() }
        guard let last = words[words.count - 1].first else { return String(first).uppercased() }
        return (String(first) + String(last)).uppercased()
    }

    /// A fixed palette keeps avatars legible with white text in both appearances; FNV-1a (not `Hasher`,
    /// which is seeded per process) makes the choice stable across launches.
    public static let palette: [String] = [
        "#D9534F", "#E8792E", "#C9A227", "#3FA34D", "#2A9D8F", "#1E88E5",
        "#5C6BC0", "#8E44AD", "#D81B60", "#6D4C41", "#546E7A", "#00897B",
    ]

    public static func avatarColor(name: String?, address: String) -> String {
        let key = address.isEmpty ? (name ?? "") : address
        var hash: UInt32 = 2_166_136_261
        for byte in key.lowercased().utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 16_777_619
        }
        return palette[Int(hash % UInt32(palette.count))]
    }

    // MARK: Recipients

    /// Joins recipients by display name, naming the user's own accounts "me".
    public static func recipientsDisplay(_ recipients: [EmailAddress], ownAddresses: Set<String>) -> String {
        recipients.map { recipient in
            ownAddresses.contains(recipient.address.lowercased()) ? "me" : recipient.shortDisplay
        }.joined(separator: ", ")
    }

    // MARK: Body

    public static func html(for message: MessageMetadata, body: StoredBody?) -> String {
        guard let body else {
            return "<p class=\"ss-pending\">" + escapeHTML(message.snippet) + "</p>"
        }
        if !body.renderedHTML.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return body.renderedHTML
        }
        if let text = body.body.text, !text.isEmpty { return textFallbackHTML(text) }
        if !body.plainText.isEmpty { return textFallbackHTML(body.plainText) }
        return textFallbackHTML(message.snippet)
    }

    public static func textFallbackHTML(_ text: String) -> String {
        "<div class=\"ss-plain\">" + escapeHTML(text).replacingOccurrences(of: "\n", with: "<br>") + "</div>"
    }

    public static func escapeHTML(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.utf8.count)
        for scalar in text.unicodeScalars {
            switch scalar {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&#39;"
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    /// The sanitizer wraps quoted earlier messages in `<div class="ss-quote">`; a substring check is enough
    /// because no HTML is parsed at render time.
    public static func hasQuotedContent(in html: String) -> Bool {
        html.contains("ss-quote")
    }

    /// Remote images are stored with their `src` moved to `data-ss-src`, one attribute per blocked image.
    public static func blockedRemoteImageCount(in html: String) -> Int {
        occurrences(of: "data-ss-src=", in: html)
    }

    static func occurrences(of needle: String, in haystack: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        var count = 0
        var range = haystack.startIndex..<haystack.endIndex
        while let found = haystack.range(of: needle, range: range) {
            count += 1
            range = found.upperBound..<haystack.endIndex
        }
        return count
    }

    // MARK: Sizes

    /// Finder-style decimal units; one decimal below 10 so "1.2 MB" and "45 KB" both read naturally.
    public static func sizeString(bytes: Int) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = Double(max(bytes, 0))
        var unit = 0
        while value >= 1000, unit < units.count - 1 {
            value /= 1000
            unit += 1
        }
        if unit == 0 { return "\(Int(value)) B" }
        let formatted = value < 10 ? String(format: "%.1f", value) : String(format: "%.0f", value)
        let trimmed = formatted.hasSuffix(".0") ? String(formatted.dropLast(2)) : formatted
        return trimmed + " " + units[unit]
    }

    // MARK: Dates

    /// "Today 14:05", "Yesterday 09:12", "Tue 3 Mar" for the rest of the last week, else "3 Mar 2025 14:05".
    public func dateDisplay(for date: Date, now: Date = Date()) -> String {
        dateDisplay(for: date, now: now, formatters: makeFormatters())
    }

    private func dateDisplay(for date: Date, now: Date, formatters: Formatters) -> String {
        var cal = calendar
        cal.timeZone = timeZone
        cal.locale = locale
        let startOfToday = cal.startOfDay(for: now)
        let startOfDate = cal.startOfDay(for: date)
        let days = cal.dateComponents([.day], from: startOfDate, to: startOfToday).day ?? Int.max
        switch days {
        case 0: return "Today " + formatters.time.string(from: date)
        case 1: return "Yesterday " + formatters.time.string(from: date)
        case 2...6: return formatters.weekday.string(from: date)
        default: return formatters.full.string(from: date)
        }
    }

    private struct Formatters {
        let time: DateFormatter
        let weekday: DateFormatter
        let full: DateFormatter
        let iso: ISO8601DateFormatter
    }

    private func makeFormatters() -> Formatters {
        func formatter(_ format: String) -> DateFormatter {
            let f = DateFormatter()
            f.calendar = calendar
            f.locale = locale
            f.timeZone = timeZone
            f.dateFormat = format
            return f
        }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        iso.timeZone = timeZone
        return Formatters(
            time: formatter("HH:mm"),
            weekday: formatter("EEE d MMM"),
            full: formatter("d MMM yyyy HH:mm"),
            iso: iso
        )
    }
}
