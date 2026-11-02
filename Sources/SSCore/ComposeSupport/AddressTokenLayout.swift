import CoreGraphics

/// Where a recipient row puts its tokens (spec §5.21). Pure geometry so the wrapping, the three-line cap and
/// the collapsed “+N more” line can be tested without AppKit; the field measures the token widths and draws.
///
/// Focused, tokens flow into lines `lineGrow` apart, and the text being typed follows the last token, or
/// starts a new line when less than `minimumInputWidth` is left. Unfocused, the row collapses to one line:
/// the tokens that fit, then “+N more”; an invalid token is never hidden behind it.
public struct AddressTokenLayout: Equatable, Sendable {
    public struct Placement: Equatable, Sendable {
        /// The token's index in the field's list.
        public var index: Int
        public var line: Int
        public var x: CGFloat
        public var width: CGFloat

        public init(index: Int, line: Int, x: CGFloat, width: CGFloat) {
            self.index = index
            self.line = line
            self.x = x
            self.width = width
        }
    }

    /// Visible tokens in display order.
    public var placements: [Placement]
    /// Tokens left out of a collapsed line; 0 when every token shows.
    public var hiddenCount: Int
    /// Where “+N more” starts on line 0 when `hiddenCount` > 0.
    public var moreX: CGFloat?
    /// The text being typed: its line, start and width. nil in a collapsed layout.
    public var inputLine: Int?
    public var inputX: CGFloat
    public var inputWidth: CGFloat
    public var lineCount: Int

    public init(placements: [Placement], hiddenCount: Int = 0, moreX: CGFloat? = nil, inputLine: Int?, inputX: CGFloat,
                inputWidth: CGFloat, lineCount: Int) {
        self.placements = placements
        self.hiddenCount = hiddenCount
        self.moreX = moreX
        self.inputLine = inputLine
        self.inputX = inputX
        self.inputWidth = inputWidth
        self.lineCount = lineCount
    }

    /// The focused layout: every token, wrapped, with room for the text being typed. A token wider than the
    /// line is narrowed to it (the field truncates its label).
    public static func flow(widths: [CGFloat], availableWidth: CGFloat, gap: CGFloat,
                            minimumInputWidth: CGFloat) -> AddressTokenLayout {
        let lineWidth = max(1, availableWidth)
        var placements: [Placement] = []
        var line = 0
        var x: CGFloat = 0
        for (index, raw) in widths.enumerated() {
            let width = min(raw, lineWidth)
            if x > 0, x + width > lineWidth {
                line += 1
                x = 0
            }
            placements.append(Placement(index: index, line: line, x: x, width: width))
            x += width + gap
        }
        var inputLine = line
        var inputX = x
        if lineWidth - inputX < min(minimumInputWidth, lineWidth), inputX > 0 {
            inputLine += 1
            inputX = 0
        }
        return AddressTokenLayout(placements: placements, inputLine: inputLine, inputX: inputX,
                                  inputWidth: max(0, lineWidth - inputX), lineCount: inputLine + 1)
    }

    /// The collapsed layout: one line of the tokens that fit, in order, then “+N more” `moreGap` after the
    /// last. Invalid tokens are placed first so they always show (a row hiding a bad address would let the
    /// user send without seeing it); the rest fill what is left, in order, while the “+N more” for what
    /// remains still fits.
    public static func collapse(widths: [CGFloat], invalid: Set<Int>, availableWidth: CGFloat, gap: CGFloat,
                                moreGap: CGFloat, moreWidth: (Int) -> CGFloat) -> AddressTokenLayout {
        let lineWidth = max(1, availableWidth)
        var chosen = widths.indices.filter { invalid.contains($0) }
        func used(_ indices: [Int]) -> CGFloat {
            let tokens = indices.reduce(0) { $0 + widths[$1] } + CGFloat(max(0, indices.count - 1)) * gap
            let hidden = widths.count - indices.count
            guard hidden > 0 else { return tokens }
            return tokens + (indices.isEmpty ? 0 : moreGap) + moreWidth(hidden)
        }
        for index in widths.indices where !invalid.contains(index) {
            let candidate = (chosen + [index]).sorted()
            guard used(candidate) <= lineWidth else { break }
            chosen = candidate
        }
        chosen.sort()
        var placements: [Placement] = []
        var x: CGFloat = 0
        for index in chosen {
            let width = min(widths[index], max(0, lineWidth - x))
            placements.append(Placement(index: index, line: 0, x: x, width: width))
            x += width + gap
        }
        let hidden = widths.count - chosen.count
        var moreX: CGFloat?
        if hidden > 0 {
            moreX = placements.isEmpty ? 0 : (placements.last.map { $0.x + $0.width } ?? 0) + moreGap
        }
        return AddressTokenLayout(placements: placements, hiddenCount: hidden, moreX: moreX, inputLine: nil,
                                  inputX: 0, inputWidth: 0, lineCount: 1)
    }

    /// The row's height for `lines` token lines: `base` (36) plus `lineGrow` (26) per extra line, capped at
    /// `maxLines` (3), past which the row scrolls inside itself (`token.rowMax`, 88).
    public static func rowHeight(lines: Int, base: CGFloat, lineGrow: CGFloat, maxLines: Int) -> CGFloat {
        base + CGFloat(min(max(1, lines), max(1, maxLines)) - 1) * lineGrow
    }
}
