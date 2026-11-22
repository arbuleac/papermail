import CoreGraphics

/// A list row's vertical metrics at a Text size (spec §5.7, §4.12, §4.15). At Default they are `layout.row` and
/// `layout.rowCompact` exactly; every step moves each text line by its role's step, the lines below it by the
/// lines above, and the row's top by the step once more: a standard row gains one step per line plus one above
/// them (64 / 68 / 72 / 76 pt), a compact row one per line plus one above and one below (44 / 48 / 52 / 56 pt).
/// The marks (pip, face, ring, tile, tag, glyphs, badge) keep their sizes and stay centred on what they mark;
/// nothing horizontal moves.
public struct QuireRowMetrics: Equatable, Sendable {
    public let textSize: QuireFont.TextSize
    public let isCompact: Bool
    public let height: CGFloat
    public let marginRuleY: CGFloat
    public let marginRuleHeight: CGFloat
    public let pipY: CGFloat
    /// The standard row's avatar box, centred in the row; unused in compact rows, which have no face.
    public let avatarBoxY: CGFloat
    public let senderY: CGFloat
    /// The sender line, which the time cluster is centred on.
    public let senderHeight: CGFloat
    /// Line 2: the subject (standard), or the subject and “ — ” snippet (compact).
    public let subjectY: CGFloat
    public let subjectHeight: CGFloat
    /// The standard row's snippet line; zero in compact rows.
    public let snippetY: CGFloat
    public let snippetHeight: CGFloat
    /// The time's line, `meta` at this size, centred on the sender line.
    public let timeHeight: CGFloat
    public let textX: CGFloat
    public let separatorX: CGFloat

    /// How far each line's centre moved from Default, for the skeleton's bars.
    let senderShift: CGFloat
    let subjectShift: CGFloat
    let snippetShift: CGFloat

    public init(textSize: QuireFont.TextSize, compact: Bool) {
        typealias Row = Quire.Layout.Row
        typealias Compact = Quire.Layout.RowCompact
        let pad = CGFloat(textSize.delta)
        let sender = QuireFont.Role.sender.step(at: textSize)
        let subject = QuireFont.Role.subject.step(at: textSize)
        let snippet = QuireFont.Role.snippet.step(at: textSize)
        self.textSize = textSize
        isCompact = compact
        senderHeight = Row.senderHeight + sender
        subjectHeight = Row.subjectHeight + subject
        timeHeight = QuireFont.Role.meta.lineHeight(at: textSize)
        senderShift = pad + sender / 2
        subjectShift = pad + sender + subject / 2
        if compact {
            height = Compact.height + pad + sender + subject + pad
            marginRuleY = Compact.marginRuleY
            pipY = Compact.pipY + senderShift
            senderY = Compact.senderY + pad
            subjectY = Compact.line2Y + pad + sender
            snippetY = 0
            snippetHeight = 0
            snippetShift = 0
            textX = Compact.textX
            separatorX = Compact.separatorX
        } else {
            height = Row.height + pad + sender + subject + snippet
            marginRuleY = Row.marginRuleY
            pipY = Row.pipY + senderShift
            senderY = Row.senderY + pad
            subjectY = Row.subjectY + pad + sender
            snippetY = Row.snippetY + pad + sender + subject
            snippetHeight = Row.snippetHeight + snippet
            snippetShift = pad + sender + subject + snippet / 2
            textX = Row.textX
            separatorX = Row.separatorX
        }
        marginRuleHeight = height - 2 * marginRuleY
        avatarBoxY = (height - Row.avatarBox) / 2
    }

    public static func standard(_ textSize: QuireFont.TextSize) -> QuireRowMetrics {
        QuireRowMetrics(textSize: textSize, compact: false)
    }

    public static func compact(_ textSize: QuireFont.TextSize) -> QuireRowMetrics {
        QuireRowMetrics(textSize: textSize, compact: true)
    }
}
