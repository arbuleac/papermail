import AppKit
import SSCore
import SSDesign

/// The visible content of one conversation row (spec §5.7), drawn by hand.
///
/// Everything is drawn in `draw(_:)` from frames computed by arithmetic: no Auto Layout, no labels, no layer per
/// mark, no shadow. The view's layer is transparent, so the row view's fill (`paper`, hover, either selection
/// wash) shows through, the avatar ring's gap included: the gap is never drawn, which is what lets one cached
/// face serve every row state. A selection or hover change redraws only the row view underneath; this layer
/// keeps its contents.
final class ConversationCellView: NSView {
    static let identifier = NSUserInterfaceItemIdentifier("ConversationCell")

    /// How the row marks its account: nothing in a single-account view; the ring (standard) or the square
    /// (compact) in unified views, plus the initial tile when Show account initials is on.
    struct AccountMark: Equatable {
        var inkSlot: Int
        var initial: String
        var isUnified: Bool
        var showsInitial: Bool
        /// What the mark's tooltip says: the account's address, which tells two Gmail accounts apart where the
        /// colour may not (spec §4.2, "the avatar's tooltip names it").
        var accountAddress = ""

        static let none = AccountMark(inkSlot: 0, initial: "", isUnified: false, showsInitial: false)
    }

    private typealias Row = Quire.Layout.Row
    private typealias Compact = Quire.Layout.RowCompact

    private(set) var content: ConversationRowContent?
    private var mark = AccountMark.none
    private var density = AppSettings.ListDensity.standard
    /// Bumped on every configure so a face that lands after the row was reused is ignored.
    private var generation = 0
    /// The words of each tooltip rect in place (see `toolTipRegions()`).
    private var toolTips: [NSView.ToolTipTag: String] = [:]

    /// Faces drawn before their cached bitmap was ready, across all rows. The list's hover-while-scrolling
    /// test reads it; a miss is also a signpost event so Instruments shows when one happens.
    private(set) static var faceMisses = 0

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override var wantsUpdateLayer: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = ConversationCellView.identifier
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    required init?(coder: NSCoder) {
        nil
    }

    func configure(with content: ConversationRowContent, mark: AccountMark, density: AppSettings.ListDensity) {
        guard content !== self.content || mark != self.mark || density != self.density else { return }
        self.content = content
        self.mark = mark
        self.density = density
        generation &+= 1
        updateToolTips()
        needsDisplay = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = newSize.width != frame.width
        super.setFrameSize(newSize)
        // The time cluster hangs from the trailing edge, so its tooltip rects move with the width.
        if widthChanged { updateToolTips() }
    }

    // MARK: Geometry

    private var isCompact: Bool { density == .compact }

    /// The time cluster's pieces, right to left: time, initial tile, the “Back” tag, queued or failed glyph. Rows carry
    /// no category tag: the Focused/Other category is never shown (§5.7).
    private struct Cluster {
        var time = NSRect.zero
        var tile: NSRect?
        var square: NSRect?
        var tag: NSRect?
        var status: NSRect?
        var leadingEdge: CGFloat = 0
    }

    private func cluster(for content: ConversationRowContent) -> Cluster {
        let lineTop = isCompact ? Compact.senderY : Row.senderY
        let lineMid = lineTop + Row.senderHeight / 2
        var c = Cluster()
        var x = bounds.width - Row.trailing
        let timeHeight = QuireFont.Role.meta.lineHeight
        c.time = NSRect(x: x - content.timeWidth, y: lineMid - timeHeight / 2, width: content.timeWidth, height: timeHeight)
        x = c.time.minX
        if mark.isUnified {
            if mark.showsInitial {
                // With initials on, the tile carries both the colour and the letter; it replaces the square.
                let size = Row.accountTile
                c.tile = NSRect(x: x - Row.tileGap - size, y: lineMid - size / 2, width: size, height: size)
                x = c.tile!.minX
            } else if isCompact {
                let size = Compact.accountSquare
                c.square = NSRect(x: x - Row.tileGap - size, y: lineMid - size / 2, width: size, height: size)
                x = c.square!.minX
            }
        }
        if content.showsBackTag {
            // In the slot the category tag had before 1.4, `tileGap` after the time or the account's tile or square.
            let size = ConversationCellView.backTagSize
            c.tag = NSRect(x: x - Row.tileGap - size.width, y: lineMid - size.height / 2, width: size.width, height: size.height)
            x = c.tag!.minX
        }
        if content.status != .none {
            let size = Row.queuedGlyph
            c.status = NSRect(x: x - Row.queuedGap - size, y: lineMid - size / 2, width: size, height: size)
            x = c.status!.minX
        }
        c.leadingEdge = x
        return c
    }

    private static let backTagSize = QuireTag.size(for: ConversationRowText.back)

    /// Where the “Back” tag is drawn, nil without one; for the app's tests.
    var backTagRect: NSRect? {
        content.flatMap { cluster(for: $0).tag }
    }

    /// The specimen's compact line 2 caps the subject at this share of the line.
    private static let compactSubjectShare: CGFloat = 0.6

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let content else { return }
        let compact = isCompact
        let textX = compact ? Compact.textX : Row.textX
        let right = bounds.width - Row.trailing

        if content.isUnread {
            let y = compact ? Compact.pipY : Row.pipY
            QuireDraw.fillCircle(NSRect(x: Row.pipX, y: y, width: Row.pip, height: Row.pip), .qAccent)
        }

        if !compact {
            let inset = (Row.avatarBox - Row.avatarFace) / 2
            let face = NSRect(x: Row.avatarBoxX + inset, y: Row.avatarBoxY + inset, width: Row.avatarFace, height: Row.avatarFace)
            drawFace(content, in: face)
            if mark.isUnified {
                QuireAvatarRenderer.drawRing(around: face, accountSlot: mark.inkSlot)
            }
        }

        // Line 1: sender, then the time cluster.
        let c = cluster(for: content)
        let senderTop = compact ? Compact.senderY : Row.senderY
        drawLine(content.sender, x: textX, top: senderTop, width: c.leadingEdge - Row.timeGap - textX, height: Row.senderHeight)
        drawLine(content.time, x: c.time.minX, top: c.time.minY, width: c.time.width + 1, height: c.time.height)
        if let tile = c.tile {
            drawInitialTile(in: tile)
        }
        if let square = c.square {
            QuireDraw.fill(square, radius: Compact.accountSquareRadius, .qAccount(mark.inkSlot))
        }
        if let tag = c.tag {
            QuireTag.draw(ConversationRowText.back, in: tag)
        }
        if let status = c.status {
            switch content.status {
            case .queued:
                QuireSymbol.draw(Quire.Icon.pending, size: .custom(Row.queuedGlyph), color: .qInk3, centredIn: status)
            case .failed:
                QuireSymbol.draw(Quire.Icon.failed, size: .row, color: .qDanger, centredIn: status)
            case .none:
                break
            }
        }

        // Line 2: subject (compact: subject — snippet), then the glyph cluster.
        let line2Top = compact ? Compact.line2Y : Row.subjectY
        let line2Mid = line2Top + Row.subjectHeight / 2
        var x = right
        if content.isStarred {
            let rect = NSRect(x: x - Row.glyph, y: line2Mid - Row.glyph / 2, width: Row.glyph, height: Row.glyph)
            QuireSymbol.draw(Quire.Icon.unstar, size: .row, color: .qStar, centredIn: rect)
            x = rect.minX - Row.glyphGap
        }
        if content.isMuted {
            // Beside the star: both are what the user set, before what the mail holds.
            let rect = NSRect(x: x - Row.glyph, y: line2Mid - Row.glyph / 2, width: Row.glyph, height: Row.glyph)
            QuireSymbol.draw(Quire.Icon.mute, size: .row, color: .qInk3, centredIn: rect)
            x = rect.minX - Row.glyphGap
        }
        if content.hasAttachments {
            let rect = NSRect(x: x - Row.glyph, y: line2Mid - Row.glyph / 2, width: Row.glyph, height: Row.glyph)
            QuireSymbol.draw(Quire.Icon.attach, size: .row, color: .qInk2, centredIn: rect)
            x = rect.minX - Row.glyphGap
        }
        if let count = content.messageCount {
            let size = content.badgeSize
            let rect = NSRect(x: x - size.width, y: line2Mid - size.height / 2, width: size.width, height: size.height)
            QuireBadge.draw(.messageCount(count), in: rect)
            x = rect.minX - Row.glyphGap
        }
        let line2Width = line2End(for: content) - textX
        if compact, let snippet = content.compactSnippet {
            // The subject keeps at most 60 % of the line so some of the snippet always shows after it.
            let cap = (line2Width * ConversationCellView.compactSubjectShare).rounded()
            var subjectWidth = content.subjectWidth
            if subjectWidth > cap {
                // Truncation ends on a glyph, short of the cap; the snippet follows the ellipsis, not the cap.
                let size = NSSize(width: cap, height: Row.subjectHeight)
                subjectWidth = min(cap, ceil(content.subject.boundingRect(with: size, options: QuireFont.drawingOptions).width))
            }
            drawLine(content.subject, x: textX, top: line2Top, width: subjectWidth, height: Row.subjectHeight)
            drawLine(snippet, x: textX + subjectWidth, top: line2Top, width: line2Width - subjectWidth, height: Row.subjectHeight)
        } else {
            drawLine(content.subject, x: textX, top: line2Top, width: line2Width, height: Row.subjectHeight)
        }

        if !compact {
            drawLine(content.snippet, x: textX, top: Row.snippetY, width: right - textX, height: Row.snippetHeight)
        }
    }

    /// Where line 2's text ends: before the count badge, the clip, the muted glyph and the star, from the trailing edge in.
    private func line2End(for content: ConversationRowContent) -> CGFloat {
        let right = bounds.width - Row.trailing
        var x = right
        if content.isStarred { x -= Row.glyph + Row.glyphGap }
        if content.isMuted { x -= Row.glyph + Row.glyphGap }
        if content.hasAttachments { x -= Row.glyph + Row.glyphGap }
        if content.messageCount != nil { x -= content.badgeSize.width + Row.glyphGap }
        return x == right ? right : x + Row.glyphGap - Row.clusterGap
    }

    /// One line, truncated at its width with a tail ellipsis; the role's paragraph style and baseline offset
    /// centre the glyphs in the line box.
    private func drawLine(_ string: NSAttributedString, x: CGFloat, top: CGFloat, width: CGFloat, height: CGFloat) {
        guard width > 0, string.length > 0 else { return }
        string.draw(with: NSRect(x: x, y: top, width: width, height: height), options: QuireFont.drawingOptions, context: nil)
    }

    /// The cached, ring-less face; until it lands, the same face drawn in place, so a row never shows an empty
    /// circle (spec §5.7, avatars).
    private func drawFace(_ content: ConversationRowContent, in rect: NSRect) {
        let scale = window?.backingScaleFactor ?? 2
        let expected = generation
        let face = QuireAvatarRenderer.shared.face(initials: content.initials, tint: content.tint, diameter: rect.width,
                                                   appearance: effectiveAppearance, scale: scale) { [weak self] _ in
            guard let self, self.generation == expected else { return }
            self.needsDisplay = true
        }
        if let face {
            face.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        } else {
            ConversationCellView.faceMisses += 1
            ListSignposts.signposter.emitEvent("list.faceMiss")
            QuireAvatarRenderer.drawFace(initials: content.initials, tint: content.tint, in: rect)
        }
    }

    /// The optional account initial tile (spec §4.2): no fill of its own, so the row's fill shows through, a
    /// 1.5 pt edge in the account ink and the monogram's first letter in `tag` `ink2`.
    private func drawInitialTile(in rect: NSRect) {
        QuireDraw.strokeInside(rect, radius: Row.accountTileRadius, width: Row.accountTileBorder, .qAccount(mark.inkSlot))
        let letter = ConversationCellView.tileLetter(mark.initial)
        let size = letter.size()
        let lineHeight = QuireFont.Role.tag.lineHeight
        drawLine(letter, x: (rect.midX - size.width / 2).rounded(), top: (rect.midY - lineHeight / 2).rounded(), width: ceil(size.width) + 1,
                 height: lineHeight)
    }

    private static var tileLetters: [String: NSAttributedString] = [:]

    private static func tileLetter(_ letter: String) -> NSAttributedString {
        if let cached = tileLetters[letter] { return cached }
        let string = QuireFont.attributedString(letter, role: .tag, color: .qInk2)
        tileLetters[letter] = string
        return string
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    // MARK: Tooltips

    /// Where the row's tooltips answer and what they say, never overlapping, so each shows its own words: the
    /// account mark (the ringed face, the compact square, the initial tile) names the account in unified views
    /// (spec §4.2), and the failed triangle says what failed, “Couldn't archive” (spec §5.7). A row-wide tooltip
    /// would cover the face and hide the account. Internal so the list's tests can read it.
    func toolTipRegions() -> [(rect: NSRect, text: String)] {
        guard let content else { return [] }
        let c = cluster(for: content)
        // Small marks (the 6 pt square, the 12 pt glyph) answer over the whole sender line box around them.
        func lineBox(_ rect: NSRect) -> NSRect {
            rect.insetBy(dx: min(0, (rect.width - Row.senderHeight) / 2), dy: min(0, (rect.height - Row.senderHeight) / 2))
        }
        var regions: [(rect: NSRect, text: String)] = []
        if mark.isUnified, !mark.accountAddress.isEmpty {
            if !isCompact {
                regions.append((NSRect(x: Row.avatarBoxX, y: Row.avatarBoxY, width: Row.avatarBox, height: Row.avatarBox), mark.accountAddress))
            }
            if let mark = c.tile ?? c.square {
                regions.append((lineBox(mark), self.mark.accountAddress))
            }
        }
        if let failure = content.failureText, let status = c.status {
            // 16 pt around the 12 pt glyph: 2 pt into its 4 pt gap, so it never reaches the tag, tile or time.
            regions.append((lineBox(status), failure))
        }
        // A cut sender or subject answers over its own words (§5.34), and only when it is cut: these regions
        // start at the text column, clear of the face, and end before the time cluster and the glyphs.
        let textX = isCompact ? Compact.textX : Row.textX
        let senderSlot = c.leadingEdge - Row.timeGap - textX
        if content.senderWidth > senderSlot, senderSlot > 0 {
            regions.append((NSRect(x: textX, y: isCompact ? Compact.senderY : Row.senderY, width: senderSlot, height: Row.senderHeight),
                            content.sender.string))
        }
        let line2Width = line2End(for: content) - textX
        let subjectSlot = isCompact && content.compactSnippet != nil
            ? (line2Width * ConversationCellView.compactSubjectShare).rounded() : line2Width
        if content.subjectWidth > subjectSlot, subjectSlot > 0, !content.subject.string.isEmpty {
            regions.append((NSRect(x: textX, y: isCompact ? Compact.line2Y : Row.subjectY, width: subjectSlot, height: Row.subjectHeight),
                            content.subject.string))
        }
        return regions
    }

    private func updateToolTips() {
        removeAllToolTips()
        toolTips = [:]
        for region in toolTipRegions() {
            toolTips[addToolTip(region.rect, owner: self, userData: nil)] = region.text
        }
    }

    // MARK: Accessibility

    /// The conversation the row shows now, for its VoiceOver actions; the cell is reused, so it is set on every configure.
    var conversationID: ConversationID?
    /// The list's actions for a conversation (spec §5.7, Swipe), asked when VoiceOver asks, so they follow the row's
    /// state (Mark as Read becomes Mark as Unread) without rebuilding anything on a refresh.
    var rowActions: ((ConversationID) -> [NSAccessibilityCustomAction])?

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .staticText }
    override func accessibilityLabel() -> String? { content?.accessibilityLabel }

    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        guard let conversationID, let actions = rowActions?(conversationID), !actions.isEmpty else { return nil }
        return actions
    }
}

extension ConversationCellView: NSViewToolTipOwner {
    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        toolTips[tag] ?? ""
    }
}
