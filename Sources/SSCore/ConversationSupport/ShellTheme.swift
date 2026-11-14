import Foundation

/// What the reader shell is told of the theme (spec §4.16, §8.4): the id it stamps on the shell and every body document,
/// the sheet for the shell's `<style id="ss-theme">`, the cut of it each body document carries, and the modes in which
/// links are underlined at rest (R10).
///
/// SSCore holds no theme of its own (the flags are SSDesign's `QuireTheme`), so the app makes one of these from the
/// theme it draws; the sheets come from `QuireCSS`, which is generated into SSCore.
public struct ShellTheme: Equatable, Sendable {
    /// `QuireCSS.themeIDs`' id: `study`, `gallery`, `rain`, `grove` or `dusk`.
    public let id: String
    /// Per mode (`light`, `dark`, `lightHC`, `darkHC`): the ink sits too near the text ink for colour alone to mark a link,
    /// so every link is underlined at rest (`ss-links`). A mode left out reads as false.
    public let links: [String: Bool]
    /// Per mode: the ink sits too near `ink2`, so links inside quoted text are underlined at rest (`ss-qlinks`).
    public let quoteLinks: [String: Bool]
    /// `QuireCSS.themeSheet(id)`: empty for Study.
    public let shell: String
    /// The shell sheet cut to what a body document carries (`ConversationShellAssets.bodyCut(_:)`), so the two never
    /// disagree about a variable.
    public let body: String

    public init(id: String, links: [String: Bool] = [:], quoteLinks: [String: Bool] = [:]) {
        self.id = id
        self.links = links
        self.quoteLinks = quoteLinks
        shell = QuireCSS.themeSheet(id)
        body = ConversationShellAssets.bodyCut(shell)
    }

    /// The default theme, whose sheet is empty: the head alone is Study.
    public static let study = ShellTheme(id: QuireCSS.themeIDs[0])

    /// `ss.setTheme(…)` for a shell that is ready.
    public var script: String {
        "window.ss && window.ss.setTheme(" + json(includingShell: true) + ")"
    }

    /// The state a shell document starts in (`SS_THEME`): everything but the shell sheet, which the document carries in
    /// its `<style id="ss-theme">` already.
    var documentState: String {
        json(includingShell: false)
    }

    private struct Wire: Encodable {
        let id: String
        let shell: String?
        let body: String
        let links: [String: Bool]
        let quoteLinks: [String: Bool]
    }

    /// JSONEncoder escapes `/`, so the text stays inert inside the shell's `<script>` element.
    private func json(includingShell: Bool) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let wire = Wire(id: id, shell: includingShell ? shell : nil, body: body, links: links, quoteLinks: quoteLinks)
        guard let data = try? encoder.encode(wire) else { return "null" }
        return String(decoding: data, as: UTF8.self)
    }
}
