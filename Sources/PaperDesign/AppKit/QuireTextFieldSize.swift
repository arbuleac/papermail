import CoreGraphics

extension QuireTextField {
    /// Field heights (`layout.textField`, spec §5.25).
    public enum Size: Sendable {
        /// 28 pt.
        case regular
        /// 24 pt, in Settings rows.
        case settings

        public var height: CGFloat {
            self == .regular ? Quire.Layout.TextField.height : Quire.Layout.TextField.settingsHeight
        }
    }
}
