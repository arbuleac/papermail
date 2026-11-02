extension QuireUnderlineTabs {
    /// One tab: its label, an optional 12 pt glyph before it (the quick reply's modes), and whether it can be
    /// chosen (Reply all with one other participant is not, and Tab skips it).
    public struct Item: Equatable, Sendable {
        public var title: String
        public var symbolName: String?
        public var isEnabled: Bool

        public init(_ title: String, symbolName: String? = nil, isEnabled: Bool = true) {
            self.title = title
            self.symbolName = symbolName
            self.isEnabled = isEnabled
        }
    }
}
