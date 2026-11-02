import CoreGraphics

extension QuireUnderlineTabs {
    /// The two places the underline-tab language is used.
    public enum Style: Sendable {
        /// The list header's filter tabs (§5.5): header row 2, 40 pt; labels 18 pt apart with their top at
        /// y = 12; the 2 pt underline on the row's bottom edge, over the header hairline.
        case filter
        /// The quick reply's modes (§5.18): the 28 pt tool row; labels 16 pt apart, label box y 6–22, a 12 pt
        /// glyph before each label; the underline's top at y = 24.
        case replyMode

        public var height: CGFloat {
            self == .filter ? Quire.Layout.ListHeader.row2 : Quire.Layout.QuickReply.toolRow
        }

        public var gap: CGFloat {
            self == .filter ? Quire.Layout.ListHeader.tabGap : Quire.Layout.QuickReply.modeGap
        }

        public var labelTop: CGFloat {
            self == .filter ? Quire.Layout.ListHeader.tabLabelY : (height - QuireFont.Role.label.lineHeight) / 2
        }

        public var underlineTop: CGFloat {
            self == .filter ? height - Quire.Border.TabUnderline.width : Quire.Layout.QuickReply.modeUnderlineY
        }
    }
}
