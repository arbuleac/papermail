import Foundation

/// Turns a conversation's `RenderPayload` into the document File › Print… prints (spec §5.48). Pure: no store, no
/// WebKit, and no HTML parsing; every body goes in as the reader got it.
///
/// The printout is the conversation's sheets, every message open, oldest first, set on the paper itself in light inks
/// whatever the app's appearance. Each message keeps what the reader shows of it (`PrintSheetState`): its remote images,
/// its quoted text, and the message under an invitation card. Bodies are not put in frames, which a printer cuts through
/// mid-line, but into shadow roots in the one page flow, so they paginate like the rest of the page while their styles
/// stay their own. The bodies sit inert in `<template>`s until the document's script attaches them, so nothing a body
/// holds is fetched before the script has applied the reader's image policy (see `PrintDocumentAssets.script`), and a
/// policy in the head lets no script run but that one, as the reader's sandboxed frames run none of a body's.
public struct PrintDocumentBuilder: Sendable {
    /// The script message handler the document posts `ready` to once its bodies are attached and their images have come
    /// in, or the wait is over.
    public static let readyHandlerName = "ssPrint"

    public var locale: Locale
    public var timeZone: TimeZone
    public var calendar: Calendar
    /// How long the document waits for images before it says it is ready (`motion.duration.printImageWait`), once for
    /// the bodies whose images print and once for those holding them back, whose inline images still load. An image
    /// still loading then prints as it stands, empty, rather than keeping the print panel away.
    public var imageWait: TimeInterval

    public init(locale: Locale = .current, timeZone: TimeZone = .current, calendar: Calendar = .current, imageWait: TimeInterval = 3) {
        self.locale = locale
        self.timeZone = timeZone
        self.calendar = calendar
        self.imageWait = imageWait
    }

    /// The print document. `sheets` holds what the reader shows of each message, by render key; a message missing from it
    /// prints as a fresh render shows it (`PrintSheetState.fresh`). `nonce` marks the document's own script, the only one
    /// its policy lets run (`PrintDocumentAssets.scriptPolicy`); a new one for every document, so no body can name it.
    public func document(for payload: RenderPayload, sheets: [String: PrintSheetState] = [:],
                         nonce: String = PrintDocumentBuilder.makeNonce()) -> String {
        let dates = makeDates()
        var html = "<!DOCTYPE html><html class=\"ss-print" + (payload.readingSans ? " ss-sf" : "") + "\" lang=\""
        html += Self.escape(locale.language.languageCode?.identifier ?? "en") + "\"><head><meta charset=\"utf-8\">"
        // Before anything else, so it holds from the first byte of every body.
        html += "<meta http-equiv=\"Content-Security-Policy\" content=\"" + PrintDocumentAssets.scriptPolicy(nonce: Self.escape(nonce)) + "\">"
        // Light whatever the app shows: the paper is light, and the web view printing it is set to Aqua as well.
        html += "<meta name=\"color-scheme\" content=\"light\"><title>" + Self.escape(Self.title(of: payload)) + "</title>"
        html += "<style>" + QuireCSS.head + "\n" + PrintDocumentAssets.css + "</style></head><body><main class=\"ss-pdoc\">"
        html += masthead(payload)
        for (index, message) in payload.messages.enumerated() {
            let state = sheets[message.id] ?? .fresh(loadRemoteImages: payload.loadRemoteImages)
            html += sheet(message, index: index, state: state, payload: payload, dates: dates)
        }
        html += "</main><script nonce=\"" + Self.escape(nonce) + "\">" + PrintDocumentAssets.script(imageWait: imageWait) + "</script></body></html>"
        return html
    }

    /// A fresh nonce for a document's script: 128 random bits, in base64.
    public static func makeNonce() -> String {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<16).map { _ in UInt8.random(in: .min ... .max, using: &generator) }).base64EncodedString()
    }

    /// The print job's name, which Save as PDF offers as the file's: the subject, or the reader's placeholder.
    public static func title(of payload: RenderPayload) -> String {
        let subject = payload.subject.trimmingCharacters(in: .whitespacesAndNewlines)
        return subject.isEmpty ? "No subject" : subject
    }

    // MARK: Parts

    private func masthead(_ payload: RenderPayload) -> String {
        let subject = payload.subject.trimmingCharacters(in: .whitespacesAndNewlines)
        var html = "<header class=\"ss-ptop\">"
        html += subject.isEmpty ? "<h1 class=\"ss-psubject ss-ph\">No subject</h1>" : "<h1 class=\"ss-psubject\">" + Self.escape(subject) + "</h1>"
        let count = payload.messages.count == 1 ? "1 message" : "\(payload.messages.count) messages"
        let line = payload.participants.isEmpty ? count : payload.participants + " · " + count
        html += "<p class=\"ss-pparts\">" + Self.escape(line) + "</p></header>"
        return html
    }

    private func sheet(_ message: RenderPayload.Message, index: Int, state: PrintSheetState, payload: RenderPayload,
                       dates: Dates) -> String {
        var html = "<article class=\"ss-pmsg\" data-id=\"" + Self.escape(message.id) + "\">"
        html += header(message, dates: dates)
        if let invitation = message.invitation { html += Self.invitationCard(invitation) }
        html += body(message, index: index, state: state, payload: payload)
        if !message.attachments.isEmpty {
            html += "<ul class=\"ss-patts ss-pind\">"
            for attachment in message.attachments {
                let meta = [attachment.kind, attachment.size].filter { !$0.isEmpty }.joined(separator: " · ")
                html += "<li><span class=\"ss-pattname\">" + Self.escape(attachment.name) + "</span>"
                if !meta.isEmpty { html += "<span class=\"ss-pattmeta\">" + Self.escape(meta) + "</span>" }
                html += "</li>"
            }
            html += "</ul>"
        }
        return html + "</article>"
    }

    /// The sheet header on paper: the avatar, the sender with the address always beside the name (there is no hover to
    /// reveal it), every recipient written out, and the date in full, since “Yesterday” means nothing a week later.
    private func header(_ message: RenderPayload.Message, dates: Dates) -> String {
        var html = "<header class=\"ss-phead\"><span class=\"ss-av ss-av36 ss-tint-\(max(0, min(7, message.from.tint)))\">"
        html += Self.escape(message.from.initials.isEmpty ? "?" : message.from.initials) + "</span><div class=\"ss-pwho\"><div class=\"ss-pnl\">"
        let name = message.from.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let address = message.from.address.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty {
            html += "<span class=\"ss-pname\">" + Self.escape(name) + "</span>"
            if !address.isEmpty, address.caseInsensitiveCompare(name) != .orderedSame {
                html += "<span class=\"ss-paddr\">" + Self.escape(address) + "</span>"
            }
        } else if !address.isEmpty {
            html += "<span class=\"ss-pname\">" + Self.escape(address) + "</span>"
        } else {
            html += "<span class=\"ss-pname ss-ph\">No sender</span>"
        }
        html += "</div>"
        for field in message.recipients where !field.people.isEmpty {
            html += "<div class=\"ss-prcpt\"><span class=\"ss-plabel\">" + Self.escape(field.label) + "</span><span class=\"ss-ppeople\">"
            html += field.people.enumerated().map { offset, person in
                let comma = offset == field.people.count - 1 ? "" : ","
                guard !person.name.isEmpty else { return "<span class=\"ss-pperson\">" + Self.escape(person.address) + comma + "</span>" }
                return "<span class=\"ss-pperson\">" + Self.escape(person.name) + " <span class=\"ss-pad\">&lt;"
                    + Self.escape(person.address) + "&gt;" + comma + "</span></span>"
            }.joined(separator: " ")
            html += "</span></div>"
        }
        html += "</div>" + dateLine(message, dates: dates) + "</header>"
        return html
    }

    /// A reply still in the outbox reads as the reader has it, “Sending…”; a draft says it is one, with when it was last
    /// edited; everything else the day and time it was sent, in this Mac's zone.
    private func dateLine(_ message: RenderPayload.Message, dates: Dates) -> String {
        if message.isPending { return "<span class=\"ss-pdate\">Sending…</span>" }
        let formatted = dates.iso.date(from: message.dateISO).map(dates.display.string(from:)) ?? message.dateDisplay
        let words = message.isDraft ? "Draft · edited " + formatted : formatted
        return "<time class=\"ss-pdate\" datetime=\"" + Self.escape(message.dateISO) + "\">" + Self.escape(words) + "</time>"
    }

    /// What stands where the body goes, and the lines that say what the reader is holding back (spec §5.48).
    private func body(_ message: RenderPayload.Message, index: Int, state: PrintSheetState, payload: RenderPayload) -> String {
        guard message.hasBody else {
            if message.bodyState == .inComposer { return Self.note("Open in a composer window") }
            let preview = message.snippet.trimmingCharacters(in: .whitespacesAndNewlines)
            var html = ""
            if !preview.isEmpty {
                let sans = payload.readingSans || !message.coveredByNewYork
                html += "<p class=\"ss-ppreview ss-pind" + (sans ? " ss-sans" : "") + "\">" + Self.escape(Self.trimmedPreview(preview)) + "</p>"
            }
            return html + Self.note("Only the preview has downloaded")
        }
        // Under an invitation card the message starts folded, its body most often the card again (spec §5.14).
        if message.invitation != nil, !state.messageShown { return Self.note("Message hidden", elided: true) }
        var html = ""
        let hidden = max(0, message.blockedRemoteImageCount) + max(0, state.liveRemoteImages)
        if !state.imagesShown, hidden > 0 {
            html += Self.note(hidden == 1 ? "1 remote image hidden" : "\(hidden) remote images hidden")
        }
        let typeset = message.typesetting == .plain || message.typesetting == .unstyled
        var classes: [String] = []
        if typeset {
            classes.append("ss-set")
            if message.isDraft { classes.append("ss-draft") } else if payload.readingSans || !message.coveredByNewYork { classes.append("ss-sans") }
        }
        if state.quotesShown { classes.append("ss-show-quotes") }
        html += "<div class=\"ss-pbody" + (typeset ? " ss-pind" : "") + "\" data-body=\"\(index)\" data-images=\""
            + (state.imagesShown ? "shown" : "hidden") + "\" data-classes=\"" + Self.escape(classes.joined(separator: " ")) + "\"></div>"
        // The stored body as the reader got it: sanitized at sync time, with no template, slot or script element and
        // every text node escaped, so nothing in it can close this template early.
        html += "<template id=\"ss-pb-\(index)\">" + message.html + "</template>"
        if message.hasQuotedContent, !state.quotesShown { html += Self.note("Quoted text hidden", elided: true) }
        return html
    }

    static func invitationCard(_ invitation: RenderPayload.Invitation) -> String {
        var html = "<section class=\"ss-pinvite ss-pind" + (invitation.isCancelled ? " ss-cancelled" : "") + "\">"
        html += "<div class=\"ss-pikick\">" + (invitation.isCancelled ? "Cancelled" : "Invitation") + "</div>"
        let title = invitation.title.trimmingCharacters(in: .whitespacesAndNewlines)
        html += title.isEmpty ? "<div class=\"ss-pititle ss-ph\">No title</div>" : "<div class=\"ss-pititle\">" + escape(title) + "</div>"
        html += "<div class=\"ss-piwhen\">" + escape(invitation.when) + "</div>"
        if let elsewhere = invitation.whenElsewhere { html += "<div class=\"ss-pielse\">" + escape(elsewhere) + "</div>" }
        if let repeats = invitation.repeats { html += "<div class=\"ss-pirep\">" + escape(repeats) + "</div>" }
        var rows: [(String, String)] = []
        if let location = invitation.location { rows.append(("Where", location)) }
        // A link is written out in full: on paper it cannot be clicked, only read.
        if let meeting = invitation.conferenceURL { rows.append((invitation.location == nil ? "Where" : "", meeting)) }
        if let organizer = invitation.organizer { rows.append(("Organizer", organizer)) }
        if let guests = invitation.guests { rows.append(("Guests", guests)) }
        if !invitation.isCancelled, let answer = invitation.response.flatMap(answerWords) { rows.append(("Your answer", answer)) }
        if !rows.isEmpty {
            html += "<dl class=\"ss-pidet\">" + rows.map { "<dt>" + escape($0.0) + "</dt><dd>" + escape($0.1) + "</dd>" }.joined() + "</dl>"
        }
        return html + "</section>"
    }

    /// The card's chosen answer, in the past tense the printout reports it in (the card's buttons are verbs).
    static func answerWords(_ response: InvitationResponse) -> String? {
        switch response {
        case .accepted: return "Accepted"
        case .tentative: return "Tentative"
        case .declined: return "Declined"
        case .needsAction: return nil
        }
    }

    /// A quiet line in place of what the reader folds or holds back; `elided` marks it with the elision glyph, as the
    /// reader's mark is (spec §5.15).
    static func note(_ words: String, elided: Bool = false) -> String {
        "<p class=\"ss-pnote ss-pind\">" + (elided ? PrintDocumentAssets.elideSVG : "") + "<span>" + escape(words) + "</span></p>"
    }

    /// The snippet as the reader's offline preview sets it: its trailing dots and spaces dropped, then one ellipsis.
    static func trimmedPreview(_ snippet: String) -> String {
        var text = Substring(snippet)
        while let last = text.last, last.isWhitespace || last == "." || last == "…" { text = text.dropLast() }
        return text + "…"
    }

    // MARK: Helpers

    static func escape(_ text: String) -> String { HTMLEscaping.escape(text) }

    /// The payload's ISO 8601 dates (with their offset) read back, and the printout's way of writing them.
    private struct Dates {
        let iso: ISO8601DateFormatter
        let display: DateFormatter
    }

    /// The display form is the weekday, the day, the month and the year, then the time in the system's 12- or 24-hour
    /// form, in the locale's order: “Fri, 13 Nov 2026 at 23:39” in British English.
    private func makeDates() -> Dates {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let display = DateFormatter()
        var calendar = self.calendar
        calendar.locale = locale
        calendar.timeZone = timeZone
        display.calendar = calendar
        display.locale = locale
        display.timeZone = timeZone
        display.setLocalizedDateFormatFromTemplate("EEEdMMMyyyyjmm")
        return Dates(iso: iso, display: display)
    }
}
