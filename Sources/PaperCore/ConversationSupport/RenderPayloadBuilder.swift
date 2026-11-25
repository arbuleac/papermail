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
    ///   - readingSans: the Font setting is SF Pro (spec §4.4).
    ///   - textSize: the reader's Text size by name (spec §4.15).
    ///   - colorsNoticeDismissed: the Original colors notice was dismissed for good (spec §5.16).
    ///   - adaptsColours: the Dark Mode default (spec §5.14); nil leaves the shell's.
    ///   - blocksTrackers: Settings › Experimental › Block trackers (spec §5.60), passed through to the shell.
    ///   - pending: messages that are replies still in the outbox (`PendingSheet`), shown as sending.
    ///   - invitationPermissionNeeded: accounts whose answered invitations wait for permission to update the calendar
    ///     (`AccountSyncStatus.permissionsNeeded`): their cards ask to reconnect.
    ///   - invitationOverlaps: each invitation card's overlap line (`overlapLines(for:events:now:)`), read from the
    ///     calendar by the caller, so the build stays pure; a card that cannot say it (`overlapCards`) shows none.
    ///   - sendLater: drafts that are Send Later messages (`SendLaterConversation`): their date line says when they send
    ///     instead of when they were edited, and one still waiting offers Cancel.
    ///   - outbox: drafts shown in the Outbox (`SendLaterConversation.outboxSummary`, spec §5.53): their date line says
    ///     where the send is, a failed one's reason in `danger`, one still waiting for its Send Later time offers Cancel,
    ///     and their footer offers only Continue editing, and that only while the message is held. Ahead of `sendLater`.
    ///   - readerMode: given while reader mode is on (spec §5.59): every message it applies to shows its text version
    ///     (`ReaderText`) on the reading page instead of its HTML, an evicted body's kept text included.
    public func build(
        messages: [MessageMetadata],
        bodies: [MessageID: StoredBody],
        accounts: [AccountID: Account],
        bodyStates: [MessageID: RenderPayload.BodyState] = [:],
        subject: String? = nil,
        loadRemoteImages: Bool = false,
        readingSans: Bool = false,
        textSize: String = "default",
        colorsNoticeDismissed: Bool = false,
        adaptsColours: Bool? = nil,
        blocksTrackers: Bool = false,
        pending: Set<MessageID> = [],
        invitationPermissionNeeded: Set<AccountID> = [],
        invitationOverlaps: [MessageID: String] = [:],
        invitationCalendarAnswers: [MessageID: InvitationResponse] = [:],
        sendLater: [MessageID: SendLaterState] = [:],
        outbox: [MessageID: OutboxState] = [:],
        readerMode: ReaderModeRender? = nil,
        now: Date = Date()
    ) -> RenderPayload {
        let visible = Self.visibleMessages(messages)
        let formatters = makeFormatters()
        let dueTimes = sendLater.isEmpty && outbox.isEmpty ? nil : DateFormatting(locale: locale, calendar: calendar, timeZone: timeZone)
        let ownAddresses = Set(accounts.values.map { $0.email.lowercased() })
        let cards = InvitationCardText(calendar: calendar, locale: locale, timeZone: timeZone)
        // Every revision of an invitation the conversation shows, so an earlier one offers no answer.
        let revisions = visible.compactMap { bodies[$0.id]?.invitation }
        let rendered = visible.map { message -> RenderPayload.Message in
            let isDraft = message.roles.contains(.drafts)
            let isPending = pending.contains(message.id)
            let reading = isDraft || isPending ? nil : readerMode.flatMap { Self.reading(message, body: bodies[message.id], in: $0) }
            // An evicted body read in reader mode shows its kept text and lists its kept attachments.
            let body = bodies[message.id] ?? reading?.kept
            let html = reading?.html ?? Self.html(for: message, body: body)
            // Stored facts describe renderedHTML; a fallback body (snippet or text) is small enough to scan.
            let stored = body.flatMap { $0.renderedHTML == html ? $0 : nil }
            let design = reading?.design ?? Self.design(for: message, body: body, stored: stored)
            let isFromMe = message.from.map { ownAddresses.contains($0.address.lowercased()) } ?? false
            let sending = isDraft ? outbox[message.id] : nil
            let later = isDraft && sending == nil ? sendLater[message.id] : nil
            let date: String
            if let sending, let dueTimes {
                date = OutboxCopy.sheetStatus(sending, provider: accounts[message.id.accountID]?.kind, formatter: dueTimes,
                                              reference: dueTimes.reference(now: now))
            } else if let later, let dueTimes {
                date = SendLaterCopy.status(later, formatter: dueTimes, reference: dueTimes.reference(now: now))
            } else if isDraft {
                date = draftDateDisplay(for: message.date, now: now, formatters: formatters)
            } else {
                date = dateDisplay(for: message.date, now: now, formatters: formatters)
            }
            let attachments = (body?.body.attachments ?? [])
                .filter { !$0.isInline }
                .map { attachment in
                    RenderPayload.Attachment(
                        id: attachment.id,
                        name: attachment.filename.isEmpty ? "Attachment" : attachment.filename,
                        size: Self.sizeString(bytes: attachment.sizeBytes),
                        mime: attachment.mimeType,
                        mark: FileMark(filename: attachment.filename, mimeType: attachment.mimeType)
                    )
                }
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
                isPending: isPending,
                hasBody: body != nil,
                bodyState: body != nil ? .ready : (bodyStates[message.id] ?? .loading),
                html: html,
                hasQuotedContent: reading?.hasQuotedContent ?? stored?.hasQuotedContent ?? Self.hasQuotedContent(in: html),
                // Text names no image: nothing is held back, so no banner offers to load one.
                blockedRemoteImageCount: reading?.html != nil ? 0 : stored?.blockedRemoteImageCount ?? Self.blockedRemoteImageCount(in: html),
                // Unknown for a body stored before the marks, which carries none: the shell tells its known pixels by
                // their address while Block trackers is on, so nothing is scanned here, on every open. A text version
                // holds no tracker for blocking to stop, so its card says none was blocked (spec §5.59, §5.60).
                trackerImageCount: reading?.html != nil ? 0 : stored?.trackerImageCount ?? 0,
                attachments: attachments,
                typesetting: design.typesetting,
                declaresColors: design.declaresColors,
                coveredByNewYork: design.coveredByNewYork,
                unsubscribe: !isDraft && !isPending && UnsubscribeMethod(message: message) != nil,
                // A draft or a reply on its way out is the user's own writing, never an invitation to answer.
                // “You” is the account the invitation came to, which is whom an answer speaks for, never another account.
                invitation: isDraft || isPending ? nil : body?.invitation.map { invitation in
                    cards.card(for: invitation, reply: message.invitationReply,
                               ownAddresses: Set(accounts[message.id.accountID].map { [$0.email.lowercased()] } ?? []),
                               needsPermission: invitationPermissionNeeded.contains(message.id.accountID),
                               superseded: revisions.contains { $0.supersedes(invitation) },
                               overlap: invitationOverlaps[message.id],
                               calendarAnswer: invitationCalendarAnswers[message.id], now: now)
                },
                cancelsSendLater: {
                    if case .waiting? = later { return true }
                    if case .waiting? = sending { return true }
                    return false
                }(),
                outbox: sending.map { state in
                    let failed: Bool
                    if case .failed = state { failed = true } else { failed = false }
                    return RenderPayload.OutboxSheet(continues: state.isHeld, failed: failed)
                },
                // The body knows what the reader will show; before it arrives, the flag the list row draws from.
                // Gmail's flag is a guess from the content type (multipart/mixed), so the body corrects it.
                hasAttachments: body != nil ? !attachments.isEmpty : message.hasAttachments,
                reader: body != nil ? reading?.view : nil
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
            textSize: textSize,
            colorsNoticeDismissed: colorsNoticeDismissed,
            adaptsColours: adaptsColours,
            blocksTrackers: blocksTrackers
        )
    }

    /// What reader mode makes of one message (spec §5.59): nil when it shows nothing new (no words yet: the snippet stands in
    /// as it always does); the HTML as it is, under the Original line, for a message the user asked to see as sent; a
    /// text/plain message's stored page as it is, since its text is what that page holds; else its text version set as a
    /// plain body. Typeset `plain`, so it sits on the reading page in Quire's inks, never the sender's colours; no image, so
    /// no banner offers to load one; inline pictures stay out of it and attachments keep their chips.
    struct Reading {
        var view: RenderPayload.ReaderView
        /// An evicted body as kept, which stands in for the stored body.
        var kept: StoredBody? = nil
        /// Nil where the stored page shows as it is: an original, which renders as without reader mode, and a text/plain
        /// message, whose page is already its text.
        var html: String? = nil
        var hasQuotedContent: Bool? = nil
        var design: (typesetting: BodyTypesetting, declaresColors: Bool, coveredByNewYork: Bool)? = nil
    }

    /// Sets the text versions `build` would show for `messages` into `mode.cache`, without building a payload (spec §5.59):
    /// pure and `Sendable` work, so a reader runs it off the main thread for the conversations it is about to pre-render,
    /// and the pre-render finds every text already set.
    public static func setReaderTexts(of messages: [MessageMetadata], bodies: [MessageID: StoredBody], in mode: ReaderModeRender) {
        guard mode.cache != nil else { return }
        for message in visibleMessages(messages) where !message.roles.contains(.drafts) {
            _ = reading(message, body: bodies[message.id], in: mode)
        }
    }

    static func reading(_ message: MessageMetadata, body: StoredBody?, in mode: ReaderModeRender) -> Reading? {
        let kept = body == nil ? mode.kept[message.id] : nil
        guard let source = body ?? kept else { return nil }
        if mode.originals.contains(message.id) {
            // Shown as sent: an evicted body has no HTML to show, so the snippet stands in while it downloads.
            return body == nil ? nil : Reading(view: .original)
        }
        let choice = ReaderText.choose(source, snippet: message.snippet)
        if choice.source == .plain, body != nil {
            // Nothing to replace: the page the sanitizer set from this very text at sync time, as without reader mode, and
            // no pass over its words however long it is.
            return Reading(view: .text)
        }
        let folds = choice.source.foldsHistory
        let set = mode.cache?.render(choice.text, foldsHistory: folds) ?? {
            let set = ReaderText.render(choice.text, foldsHistory: folds)
            return ReaderTextCache.Setting(html: set.html, hasQuotedContent: set.hasQuotedContent,
                                           coveredByNewYork: NewYorkCoverage.covers(choice.text))
        }()
        // The stored coverage was worked out over exactly the extracted text, or an evicted text/plain body's kept text.
        let covered = choice.source == .extracted || choice.source == .plain ? source.coveredByNewYork ?? set.coveredByNewYork
            : set.coveredByNewYork
        let view: RenderPayload.ReaderView
        switch choice.source {
        case .plain, .text: view = .text
        case .extracted: view = .extracted
        case .snippet: view = .snippet
        }
        return Reading(view: view, kept: kept, html: plainBodyPrefix + set.html + "</div>", hasQuotedContent: set.hasQuotedContent,
                       design: (.plain, false, covered))
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
    /// arithmetic as `Quire.avatarTintIndex(forAddress:)` in PaperDesign, which PaperCore cannot import; both are
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
