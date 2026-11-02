import CoreGraphics

extension QuireIconButton {
    /// Icon button squares (`layout.button.icon` / `iconRadius`, spec §5.24).
    public enum Size: Int, CaseIterable, Sendable {
        /// 22 pt, radius 5: tool rows and Settings.
        case small
        /// 24 pt, radius 5: the sheet header's hover actions, the cheat sheet's close button, dismiss buttons.
        case medium
        /// 28 pt, radius 6: window-level actions (reader header, composer bar, rail utilities, compose).
        case large

        public var side: CGFloat { Quire.Layout.Button.icon[rawValue] }
        public var cornerRadius: CGFloat { Quire.Layout.Button.iconRadius[rawValue] }

        /// The default symbol size: 15 pt on window-level buttons, 14 pt inside tool rows and sheets (§4.11).
        public var defaultSymbolSize: QuireSymbolSize {
            self == .large ? .window : .inText
        }
    }
}
