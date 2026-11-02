import Foundation

/// Turns stored metadata and bodies into a `RenderPayload`. Pure: no store access, no HTML parsing.
///
/// Dates, initials, tints and recipients are derived here rather than in JavaScript so the shell stays a dumb
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
    ///   - bodyStates: what stands in for each missing body (`loading` when absent); ignored once a body exists.
    ///   - subject: overrides the first non-empty message subject when the caller already has it.
    ///   - loadRemoteImages: the user's preference, passed through to the shell.
    ///   - readingSans: the SF Pro reading font setting (spec §4.4).
    ///   - colorsNoticeDismissed: the Original colors notice was dismissed for good (spec §5.16).
    ///   - pending: messages that are replies still in the outbox (`PendingSheet`), shown as sending.
    public func build(
        messages: [MessageMetadata],
        bodies: [MessageID: StoredBody],
        accounts: [AccountID: Account],
        bodyStates: [MessageID: RenderPayload.BodyState] = [:],
        subject: String? = nil,
        loadRemoteImages: Bool = false,
        readingSans: Bool = false,
        colorsNoticeDismissed: Bool = false,
        pending: Set<MessageID> = [],
        now: Date = Date()
    ) -> RenderPayload {
        let visible = Self.visibleMessages(messages)
        let formatters = makeFormatters()
        let ownAddresses = Set(accounts.values.map { $0.email.lowercased() })
        let rendered = visible.map { message -> RenderPayload.Message in
            let body = bodies[message.id]
            let html = Self.html(for: message, body: body)
            // Stored facts describe renderedHTML; a fallback body (snippet or text) is small enough to scan.
            let stored = body.flatMap { $0.renderedHTML == html ? $0 : nil }
            let design = Self.design(for: message, body: body, stored: stored)
            let isFromMe = message.from.map { ownAddresses.contains($0.address.lowercased()) } ?? false
            let isDraft = message.roles.contains(.drafts)
            let date = isDraft
                ? draftDateDisplay(for: message.date, now: now, formatters: formatters)
                : dateDisplay(for: message.date, now: now, formatters: formatters)
            return RenderPayload.Message(
                id: RenderPayload.messageKey(for: message.id),
                from: Self.sender(for: message.from),
                to: Self.recipientsDisplay(message.to, ownAddresses: ownAddresses),
                cc: Self.recipientsDisplay(message.cc, ownAddresses: ownAddresses),
                recipients: Self.recipientFields(for: message, isFromMe: isFromMe, ownAddresses: ownAddresses),
                dateISO: formatters.iso.string(from: message.date),
                dateDisplay: date,
                snippet: message.snippet,
                isUnread: !message.isRead,
                isStarred: message.isStarred,
                isDraft: isDraft,
                isPending: pending.contains(message.id),
                hasBody: body != nil,
                bodyState: body != nil ? .ready : (bodyStates[message.id] ?? .loading),
                html: html,
                hasQuotedContent: stored?.hasQuotedContent ?? Self.hasQuotedContent(in: html),
                blockedRemoteImageCount: stored?.blockedRemoteImageCount ?? Self.blockedRemoteImageCount(in: html),
                attachments: (body?.body.attachments ?? [])
                    .filter { !$0.isInline }
                    .map { attachment in
                        let type = Self.attachmentType(filename: attachment.filename, mimeType: attachment.mimeType)
                        return RenderPayload.Attachment(
                            id: attachment.id,
                            name: attachment.filename.isEmpty ? "Attachment" : attachment.filename,
                            size: Self.sizeString(bytes: attachment.sizeBytes),
                            mime: attachment.mimeType,
                            symbol: type.symbol,
                            kind: type.kind
                        )
                    },
                typesetting: design.typesetting,
                declaresColors: design.declaresColors,
                coveredByNewYork: design.coveredByNewYork
            )
        }
        let resolvedSubject = subject ?? Self.subject(of: visible)
        let inkSlot = visible.first.flatMap { accounts[$0.id.accountID]?.inkSlot } ?? 0
        return RenderPayload(
            subject: resolvedSubject,
            participants: Self.participantsLine(visible, accounts: accounts),
            messages: rendered,
            loadRemoteImages: loadRemoteImages,
            inkSlot: inkSlot,
            readingSans: readingSans,
            colorsNoticeDismissed: colorsNoticeDismissed
        )
    }

    /// The design facts the shell sets a body by. A stored body carries them from sync time; one stored before
    /// they were kept, until the engine backfills it, reads as plain when its wrapper says it came from
    /// text/plain and otherwise as styled with colours, the sender's design untouched. A fallback
    /// (the snippet while the body hydrates, or the text when rendered HTML is empty) is plain text the shell
    /// wraps itself; its coverage is checked here because a snippet is short and an empty rendering is rare,
    /// and the check is a scan of scalars, not a parse.
    static func design(
        for message: MessageMetadata,
        body: StoredBody?,
        stored: StoredBody?
    ) -> (typesetting: BodyTypesetting, declaresColors: Bool, coveredByNewYork: Bool) {
        if let stored {
            // A body stored before the facts were kept, and not yet backfilled by the engine: a text/plain one is
            // recognisable by the wrapper the sanitizer has always written, a prefix check rather than a parse.
            if stored.typesetting == nil, stored.renderedHTML.hasPrefix(Self.plainBodyPrefix) {
                return (.plain, false, stored.coveredByNewYork ?? NewYorkCoverage.covers(stored.plainText))
            }
            let typesetting = stored.typesetting ?? .styled
            return (typesetting, stored.declaresColors ?? (typesetting == .styled), stored.coveredByNewYork ?? false)
        }
        return (.plain, false, NewYorkCoverage.covers(fallbackText(for: message, body: body)))
    }

    /// How every sanitized text/plain body begins (`HTMLSanitizer.renderText`, unchanged since the first build).
    static let plainBodyPrefix = "<div class=\"\(HTMLSanitizer.bodyClass) \(HTMLSanitizer.plainBodyClass)\">"

    /// The text `html(for:body:)` falls back to, in the same order.
    private static func fallbackText(for message: MessageMetadata, body: StoredBody?) -> String {
        guard let body else { return message.snippet }
        if let text = body.body.text, !text.isEmpty { return text }
        if !body.plainText.isEmpty { return body.plainText }
        return message.snippet
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

    /// A missing sender is an empty name and address: the shell sets "No sender" in the placeholder style
    /// (spec §4.1) and the face shows "?".
    public static func sender(for address: EmailAddress?) -> RenderPayload.Sender {
        guard let address else {
            return RenderPayload.Sender(name: "", address: "", initials: "?", tint: avatarTint(name: nil, address: ""))
        }
        let name = address.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return RenderPayload.Sender(
            name: name.isEmpty ? address.shortDisplay : name,
            address: address.address,
            initials: initials(name: address.name, address: address.address),
            tint: avatarTint(name: address.name, address: address.address)
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

    /// The number of avatar tints (spec §4.3, `platform.avatarTintCount`).
    public static let avatarTintCount = 8

    /// The avatar tint: FNV-1a 32-bit over the UTF-8 of the lowercased address, modulo the tint count. The same
    /// arithmetic as `Quire.avatarTintIndex(forAddress:)` in SSDesign, which SSCore cannot import; both are
    /// tested against the same vectors. Not `Hasher`, which is seeded per process.
    public static func avatarTint(name: String?, address: String) -> Int {
        let key = address.isEmpty ? (name ?? "") : address
        var hash: UInt32 = 2_166_136_261
        for byte in key.lowercased().utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 16_777_619
        }
        return Int(hash % UInt32(avatarTintCount))
    }

    // MARK: Recipients

    /// Joins recipients by display name, naming the user's own accounts "me".
    public static func recipientsDisplay(_ recipients: [EmailAddress], ownAddresses: Set<String>) -> String {
        recipients.map { recipient in
            ownAddresses.contains(recipient.address.lowercased()) ? "me" : recipient.shortDisplay
        }.joined(separator: ", ")
    }

    /// The expanded recipients (spec §5.14): To, Cc, and Bcc only on messages the user sent; empty fields are
    /// left out. The user is "me".
    public static func recipientFields(
        for message: MessageMetadata,
        isFromMe: Bool,
        ownAddresses: Set<String>
    ) -> [RenderPayload.RecipientField] {
        func people(_ list: [EmailAddress]) -> [RenderPayload.Person] {
            list.map { address in
                let isMe = ownAddresses.contains(address.address.lowercased())
                let name = address.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return RenderPayload.Person(name: isMe ? "me" : name, address: address.address)
            }
        }
        var fields: [RenderPayload.RecipientField] = []
        if !message.to.isEmpty { fields.append(.init(label: "To", people: people(message.to))) }
        if !message.cc.isEmpty { fields.append(.init(label: "Cc", people: people(message.cc))) }
        if isFromMe, !message.bcc.isEmpty { fields.append(.init(label: "Bcc", people: people(message.bcc))) }
        return fields
    }

    /// Everyone in the conversation in order of appearance (each sender, then their recipients), at most `max`
    /// names and then "+3" (spec §5.13). The user appears by name, as the list's sender line names them.
    public static func participantsLine(_ messages: [MessageMetadata], accounts: [AccountID: Account], max: Int = 4) -> String {
        let ownNames = Dictionary(accounts.values.map { ($0.email.lowercased(), $0.displayName) }, uniquingKeysWith: { first, _ in first })
        var seen: Set<String> = []
        var names: [String] = []
        for message in messages {
            for address in [message.from].compactMap({ $0 }) + message.to + message.cc {
                let key = address.address.lowercased()
                guard !key.isEmpty, seen.insert(key).inserted else { continue }
                let name = address.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !name.isEmpty {
                    names.append(name)
                } else if let own = ownNames[key], !own.isEmpty {
                    names.append(own)
                } else {
                    names.append(address.shortDisplay)
                }
            }
        }
        guard names.count > max else { return names.joined(separator: ", ") }
        return names.prefix(max).joined(separator: ", ") + " +\(names.count - max)"
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

    /// A body with no rendered HTML set from its text the way every plain body is (`PlainTextRenderer`:
    /// paragraphs, so the reading page's 12 pt gap applies instead of empty 24 pt lines, links and folded
    /// quotes), in the sanitizer's plain wrapper. String work only: opening a message never parses HTML.
    public static func textFallbackHTML(_ text: String) -> String {
        plainBodyPrefix + PlainTextRenderer.render(text).html + "</div>"
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

    /// Remote images are stored with their `src` moved to `data-ss-src` (backgrounds to `data-ss-background`),
    /// one attribute per blocked image.
    public static func blockedRemoteImageCount(in html: String) -> Int {
        occurrences(of: "data-ss-src=", in: html) + occurrences(of: "data-ss-background=", in: html)
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

    // MARK: Attachments

    /// The chip's type tile symbol and the kind its meta line names (spec §5.17), from the file's extension,
    /// else its MIME type. Symbols stay inside the reader's rasterised set (§4.11).
    public static func attachmentType(filename: String, mimeType: String) -> (symbol: String, kind: String) {
        let ext = (filename as NSString).pathExtension.lowercased()
        switch ext {
        case "pdf": return ("doc", "PDF")
        case "doc", "docx": return ("doc.richtext", "Word")
        case "pages": return ("doc.richtext", "Pages")
        case "rtf", "rtfd": return ("doc.richtext", "Rich Text")
        case "txt", "md": return ("doc", "Text")
        case "xls", "xlsx": return ("tablecells", "Excel")
        case "numbers": return ("tablecells", "Numbers")
        case "csv", "tsv": return ("tablecells", ext.uppercased())
        case "ppt", "pptx": return ("doc", "PowerPoint")
        case "key": return ("doc", "Keynote")
        case "zip", "gz", "tgz", "tar", "7z", "rar", "bz2", "xz": return ("doc.zipper", "Archive")
        case "mov": return ("film", "QuickTime")
        case "mp4", "m4v", "avi", "mkv", "webm": return ("film", "Video")
        case "jpg", "jpeg": return ("photo", "JPEG")
        case "png", "gif", "heic", "heif", "tif", "tiff", "webp", "bmp": return ("photo", ext.uppercased())
        default: break
        }
        let mime = mimeType.lowercased()
        if mime == "application/pdf" { return ("doc", "PDF") }
        if mime.hasPrefix("image/") { return ("photo", "Image") }
        if mime.hasPrefix("video/") { return ("film", "Video") }
        if mime.contains("zip") || mime.contains("compressed") { return ("doc.zipper", "Archive") }
        if mime.contains("spreadsheet") || mime.contains("excel") || mime == "text/csv" { return ("tablecells", "Spreadsheet") }
        if mime.contains("wordprocessing") || mime.contains("msword") || mime.contains("rtf") { return ("doc.richtext", "Document") }
        return ("doc", ext.isEmpty ? "File" : ext.uppercased())
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

    /// What the reader shows (spec §4.13): "Today 09:12", "Yesterday 23:39", "Fri 30 Oct" for the rest of this
    /// year and "30 Oct 2025" before it. Times follow the locale's 12/24-hour convention (the user's choice
    /// for the current locale), dates its day and month order.
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
        case 2...:
            let sameYear = cal.component(.year, from: date) == cal.component(.year, from: now)
            return (sameYear ? formatters.weekday : formatters.full).string(from: date)
        default:
            // A date in the future is clock skew; it never reads as Today.
            return formatters.full.string(from: date)
        }
    }

    /// A draft's date line (spec §5.19): "Edited 23:51" today, else "Edited Fri 30 Oct".
    private func draftDateDisplay(for date: Date, now: Date, formatters: Formatters) -> String {
        var cal = calendar
        cal.timeZone = timeZone
        if cal.isDate(date, inSameDayAs: now) { return "Edited " + formatters.time.string(from: date) }
        return "Edited " + dateDisplay(for: date, now: now, formatters: formatters)
    }

    private struct Formatters {
        let time: DateFormatter
        let weekday: DateFormatter
        let full: DateFormatter
        let iso: ISO8601DateFormatter
    }

    private func makeFormatters() -> Formatters {
        func formatter(template: String) -> DateFormatter {
            let f = DateFormatter()
            f.calendar = calendar
            f.locale = locale
            f.timeZone = timeZone
            f.setLocalizedDateFormatFromTemplate(template)
            return f
        }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        iso.timeZone = timeZone
        return Formatters(
            time: formatter(template: "jmm"),
            weekday: formatter(template: "EEEdMMM"),
            full: formatter(template: "dMMMyyyy"),
            iso: iso
        )
    }
}
