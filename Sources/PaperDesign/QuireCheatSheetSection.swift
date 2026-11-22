/// One section of the keyboard cheat sheet (spec §5.32), generated from `cheatSheetContent` so the key map,
/// the overlay and the specimen cannot drift apart.
public struct QuireCheatSheetSection: Equatable, Sendable {
    public let title: String
    public let rows: [QuireCheatSheetRow]

    public init(title: String, rows: [QuireCheatSheetRow]) {
        self.title = title
        self.rows = rows
    }
}
