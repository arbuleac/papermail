import AppKit

extension QuireFont {
    /// Everything tokens.json says about a typography role. The generator fills one per role and refuses a
    /// field it does not know, so a new field cannot be dropped silently.
    public struct Spec: Equatable, Sendable {
        public let family: Family
        /// Points. 0 for `monogram`, whose size derives from the avatar diameter.
        public let size: CGFloat
        /// CSS weight: 400 Regular, 500 Medium, 600 Semibold.
        public let weight: CGFloat
        /// Exact line height in points; 0 means 1.0 × size (`monogram`).
        public let lineHeight: CGFloat
        /// Points at the stated size; 0 keeps the system's optical tracking.
        public let tracking: CGFloat
        public let italic: Bool
        /// Tabular (monospaced) digits, so times and counts do not jitter.
        public let tabular: Bool
        /// Uppercased at string-build time, in the user's locale.
        public let uppercase: Bool
        /// The weight unread items use instead of `weight`.
        public let unreadWeight: CGFloat?
        /// The SF Pro role used when New York cannot set the text.
        public let twin: Role?
        public let twinOf: Role?
        public let variantOf: Role?
        /// `monogram`: size = max(minSize, sizeRatio × diameter).
        public let sizeRatio: CGFloat?
        public let minSize: CGFloat?
        public let use: String

        public init(family: Family, size: CGFloat, weight: CGFloat, lineHeight: CGFloat, tracking: CGFloat,
                    italic: Bool, tabular: Bool, uppercase: Bool, unreadWeight: CGFloat?,
                    twin: Role?, twinOf: Role?, variantOf: Role?, sizeRatio: CGFloat?, minSize: CGFloat?, use: String) {
            self.family = family
            self.size = size
            self.weight = weight
            self.lineHeight = lineHeight
            self.tracking = tracking
            self.italic = italic
            self.tabular = tabular
            self.uppercase = uppercase
            self.unreadWeight = unreadWeight
            self.twin = twin
            self.twinOf = twinOf
            self.variantOf = variantOf
            self.sizeRatio = sizeRatio
            self.minSize = minSize
            self.use = use
        }

        /// The size AppKit sets: the stated size, or the minimum for the diameter-driven monogram.
        public var pointSize: CGFloat { size > 0 ? size : (minSize ?? Quire.Platform.minTextSizePoints) }

        /// The exact line height in points.
        public var resolvedLineHeight: CGFloat { lineHeight > 0 ? lineHeight : pointSize }
    }
}

extension Quire.Platform {
    /// `minTextSize` as points.
    static var minTextSizePoints: CGFloat { CGFloat(minTextSize) }
}
