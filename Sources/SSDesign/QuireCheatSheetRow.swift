/// One row of the cheat sheet: the keys as tokens.json writes them and the sentence-case label.
public struct QuireCheatSheetRow: Equatable, Sendable {
    /// Keycaps separated by spaces; "then" and "…" are words between keycaps, not keycaps.
    public let keys: String
    public let label: String

    public init(keys: String, label: String) {
        self.keys = keys
        self.label = label
    }

    /// Each part in order, marked as a keycap or a connecting word.
    public var parts: [(text: String, isKeycap: Bool)] {
        keys.split(separator: " ").map { part in
            let s = String(part)
            return (s, s != "then" && s != "…")
        }
    }
}
