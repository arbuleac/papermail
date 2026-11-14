extension QuireFont {
    /// Settings › General › Text size (spec §4.15): the step, in points, every role where mail is read and written
    /// moves by. The raw values are what the app saves, so they never change.
    public enum TextSize: String, CaseIterable, Sendable {
        case small
        case `default`
        case large
        case larger

        /// The step in points: −1, 0, +1, +2 (`textSize.deltas`).
        public var delta: Int {
            Quire.TextSize.deltas[Self.allCases.firstIndex(of: self) ?? 1]
        }

        /// The popup's words: Small, Default, Large, Larger (`textSize.names`).
        public var title: String {
            Quire.TextSize.names[Self.allCases.firstIndex(of: self) ?? 1]
        }

        /// The next size up, nil at Larger: what ⌘+ gives the reader.
        public var larger: TextSize? {
            guard let index = Self.allCases.firstIndex(of: self), index + 1 < Self.allCases.count else { return nil }
            return Self.allCases[index + 1]
        }

        /// The next size down, nil at Small: what ⌘− gives the reader.
        public var smaller: TextSize? {
            guard let index = Self.allCases.firstIndex(of: self), index > 0 else { return nil }
            return Self.allCases[index - 1]
        }
    }
}
