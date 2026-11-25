import Foundation

/// What a selection's rewrite sends of the user's own draft around it (the DRAFT form, spec §5.56), piece by piece:
/// the text before the selection (`lead`), the few words right before it that the model may change (`before`, when
/// offered), the blanks between them and the selection, the selection, and the mirror of each after it. Built off the
/// main thread inside the request builders (`WritePrompt.rewriteRequest`) from `WriteAsk.Around`; it stays on this Mac
/// on the request (`AIWriteRequest.rewrite`) so the writer can read the answer against what was sent.
///
/// Every piece is cleaned as the rest of a request is (invisible characters and pictures out, line breaks normalised,
/// empty lines folded, the fence code stripped). A window is offered only when cleaning leaves it exactly as the field
/// holds it, so the words the model may change are the words in the field. Text around a body a mail link or a Service
/// filled in is redacted, cut only at blanks.
public struct WriteRewriteFrame: Sendable, Hashable {
    /// The user's text before the selection, up to the before window; cut at its start for length (“[…] ”).
    public var lead: String
    /// The words right before the selection the model may change, exactly as the field holds them; nil when none is
    /// offered (it is then part of `lead`).
    public var before: String?
    /// The blanks between `before` (or `lead`) and the selection, as typed.
    public var gapBefore: String
    /// The selection as the context cleaned it.
    public var selection: String
    public var gapAfter: String
    /// The words right after the selection the model may change; nil when none is offered.
    public var after: String?
    /// The user's text after the selection, from the after window on; cut at its end for length (“ […]”).
    public var trail: String
    /// The instruction as sent, fence-stripped: a run of the draft the answer repeats is no echo when the user asked
    /// for it.
    public var instruction: String

    public init(lead: String = "", before: String? = nil, gapBefore: String = "", selection: String, gapAfter: String = "",
                after: String? = nil, trail: String = "", instruction: String = "") {
        self.lead = lead
        self.before = before
        self.gapBefore = gapBefore
        self.selection = selection
        self.gapAfter = gapAfter
        self.after = after
        self.trail = trail
        self.instruction = instruction
    }

    /// The most characters sent before the selection (lead, window and gap), and after it; what one side leaves unused
    /// goes to the other, up to `maxTotal`.
    public static let maxBefore = 6_000
    public static let maxAfter = 2_000
    public static var maxTotal: Int { maxBefore + maxAfter }
    /// What stands for the start of a lead left out for length.
    public static let leadCutMarker = "[\u{2026}] "

    /// Everything sent before the selection, as sent.
    public var sentBefore: String { lead + (before ?? "") + gapBefore }
    /// Everything sent after the selection, as sent.
    public var sentAfter: String { gapAfter + (after ?? "") + trail }
    /// A window was offered on either side, so the answer may carry a BEFORE or an AFTER line.
    public var offersWindow: Bool { before != nil || after != nil }

    /// The frame for `around`. `selection` is the context's cleaned selection; `redacts` is true for a body that is still
    /// what a mail link or a Service filled in, whose text goes through `AIRedactor` in pieces cut only at blanks.
    public static func make(around: WriteAsk.Around, selection: String, redacts: Bool, fence: String,
                            instruction: String = "") -> WriteRewriteFrame {
        let before = around.before as NSString
        let after = around.after as NSString
        let beforeGap = clamped(around.beforeGap, to: before.length)
        let beforeWindow = clamped(around.beforeWindow, to: before.length - beforeGap)
        let afterGap = clamped(around.afterGap, to: after.length)
        let afterWindow = clamped(around.afterWindow, to: after.length - afterGap)

        var lead = before.substring(to: before.length - beforeGap - beforeWindow)
        var windowBefore = before.substring(with: NSRange(location: before.length - beforeGap - beforeWindow, length: beforeWindow))
        var gapBefore = before.substring(from: before.length - beforeGap)
        var gapAfter = after.substring(to: afterGap)
        var windowAfter = after.substring(with: NSRange(location: afterGap, length: afterWindow))
        var trail = after.substring(from: afterGap + afterWindow)
        // A gap is blanks and nothing else: anything else is text, sent as text.
        if !isBlanks(gapBefore) {
            lead += windowBefore + gapBefore
            (windowBefore, gapBefore) = ("", "")
        }
        if !isBlanks(gapAfter) {
            trail = gapAfter + windowAfter + trail
            (gapAfter, windowAfter) = ("", "")
        }

        if redacts {
            // A selection that starts or ends inside a run of characters (a link, an address, a code, a card number)
            // takes the rest of that run with it out of the request: nothing beside it is a fragment of one.
            if gapBefore.isEmpty, let last = (lead + windowBefore).unicodeScalars.last, !last.properties.isWhitespace {
                lead = droppingTrailingRun(of: lead + windowBefore)
                windowBefore = ""
            }
            if gapAfter.isEmpty, let first = (windowAfter + trail).unicodeScalars.first, !first.properties.isWhitespace {
                trail = droppingLeadingRun(of: windowAfter + trail)
                windowAfter = ""
            }
        }

        let offersBefore = offers(windowBefore, gap: gapBefore, outerEdgeIsBlank: lead.isEmpty || endsInBlank(lead),
                                  redacts: redacts, fence: fence)
        let offersAfter = offers(windowAfter, gap: gapAfter, outerEdgeIsBlank: trail.isEmpty || startsWithBlank(trail),
                                 redacts: redacts, fence: fence)
        if !offersBefore { lead += windowBefore }
        if !offersAfter { trail = windowAfter + trail }

        lead = clean(lead, fence: fence)
        trail = clean(trail, fence: fence)
        if redacts {
            let redactor = AIRedactor()
            lead = redactor.redact(lead)
            trail = redactor.redact(trail)
        }

        let sentWindowBefore = offersBefore ? windowBefore : nil
        let sentWindowAfter = offersAfter ? windowAfter : nil
        let beforeFixed = (sentWindowBefore?.count ?? 0) + gapBefore.count
        let afterFixed = (sentWindowAfter?.count ?? 0) + gapAfter.count
        let leadRoom = max(0, maxBefore - beforeFixed)
        let trailRoom = max(0, maxAfter - afterFixed)
        let leadCount = lead.count
        let trailCount = trail.count
        lead = cutLead(lead, to: min(leadCount, leadRoom + max(0, trailRoom - trailCount)))
        trail = cutTrail(trail, to: min(trailCount, trailRoom + max(0, leadRoom - leadCount)))

        return WriteRewriteFrame(lead: lead, before: sentWindowBefore, gapBefore: gapBefore,
                                 selection: WritePrompt.stripAll(selection, fence: fence), gapAfter: gapAfter,
                                 after: sentWindowAfter, trail: trail, instruction: WritePrompt.stripAll(instruction, fence: fence))
    }

    /// The DRAFT block's body: the pieces in order, the offered windows and the selection between markers that carry
    /// the request's code. Every piece was stripped of the code before it was joined.
    public func markedBody(fence: String) -> String {
        var body = lead
        if let before { body += "<<<BEFORE \(fence)>>>" + before + "<<<END BEFORE \(fence)>>>" }
        body += gapBefore + "<<<SELECTION \(fence)>>>" + selection + "<<<END SELECTION \(fence)>>>" + gapAfter
        if let after { body += "<<<AFTER \(fence)>>>" + after + "<<<END AFTER \(fence)>>>" }
        return body + trail
    }

    // MARK: Cleaning

    /// A piece as it is sent: invisible characters and pictures out, CR LF and CR made LF, runs of empty lines folded to
    /// one (its ends kept: they are where it meets the selection), and the fence code stripped.
    static func clean(_ text: String, fence: String) -> String {
        var text = AIRedactor.removingInvisibleCharacters(text)
        text = text.replacingOccurrences(of: WriteAsk.pictureCharacter, with: "", options: .literal)
        text = ReplyContextBuilder.normalizedNewlines(text)
        text = foldingEmptyLines(text)
        return WritePrompt.stripAll(text, fence: fence)
    }

    /// `text` with every run of empty lines (blanks alone) between its first and last line folded to one; the first
    /// and the last line are the partial lines the selection's line and the piece's other end cut, and stay.
    static func foldingEmptyLines(_ text: String) -> String {
        guard text.contains("\n\n") || text.contains("\n \n") || text.contains("\n\t\n") else { return text }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count > 3 else { return text }
        var kept: [Substring] = [lines[0]]
        var previousWasEmpty = false
        for index in 1..<(lines.count - 1) {
            let isEmpty = lines[index].allSatisfy { $0 == " " || $0 == "\t" }
            if isEmpty, previousWasEmpty { continue }
            kept.append(lines[index])
            previousWasEmpty = isEmpty
        }
        kept.append(lines[lines.count - 1])
        return kept.joined(separator: "\n")
    }

    /// Whether `window` goes as a window the model may change: there is one, cleaning leaves it as it is, it holds no
    /// fence syntax, and for a redacted body its outer edge and its gap are blanks and redaction leaves it as it is.
    private static func offers(_ window: String, gap: String, outerEdgeIsBlank: Bool, redacts: Bool, fence: String) -> Bool {
        guard !window.isEmpty, clean(window, fence: fence) == window, !window.contains("<<<"), !window.contains(">>>") else {
            return false
        }
        guard redacts else { return true }
        return outerEdgeIsBlank && !gap.isEmpty && AIRedactor().redact(window) == window
    }

    // MARK: Length

    /// `lead` in at most `room` characters, keeping its end (what is nearest the selection), cut after a blank, with
    /// “[…] ” before it.
    static func cutLead(_ lead: String, to room: Int) -> String {
        guard lead.count > room else { return lead }
        var kept = Substring(lead.suffix(max(0, room - leadCutMarker.count)))
        if let blank = kept.firstIndex(where: \.isWhitespace) { kept = kept[kept.index(after: blank)...] }
        return leadCutMarker + kept
    }

    /// `trail` in at most `room` characters, keeping its start, cut before a blank, with “ […]” after it.
    static func cutTrail(_ trail: String, to room: Int) -> String {
        guard trail.count > room else { return trail }
        var kept = Substring(trail.prefix(max(0, room - ReplyContextBuilder.cutMarker.count)))
        if let blank = kept.lastIndex(where: \.isWhitespace) { kept = kept[..<blank] }
        return kept + ReplyContextBuilder.cutMarker
    }

    // MARK: Text

    private static func clamped(_ value: Int, to limit: Int) -> Int {
        min(max(0, value), max(0, limit))
    }

    private static func isBlanks(_ text: String) -> Bool {
        text.utf16.allSatisfy(WriteSeamWindows.isGapBlank)
    }

    private static func endsInBlank(_ text: String) -> Bool {
        text.unicodeScalars.last?.properties.isWhitespace ?? true
    }

    private static func startsWithBlank(_ text: String) -> Bool {
        text.unicodeScalars.first?.properties.isWhitespace ?? true
    }

    private static func droppingTrailingRun(of text: String) -> String {
        var scalars = text.unicodeScalars
        while let last = scalars.last, !last.properties.isWhitespace { scalars.removeLast() }
        return String(scalars)
    }

    private static func droppingLeadingRun(of text: String) -> String {
        let scalars = text.unicodeScalars
        guard let start = scalars.firstIndex(where: { $0.properties.isWhitespace }) else { return "" }
        return String(scalars[start...])
    }
}
