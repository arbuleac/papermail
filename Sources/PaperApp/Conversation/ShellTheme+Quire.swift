import PaperCore
import PaperDesign

extension ShellTheme {
    /// What the reader shell is told of `theme`: its sheets by id, and its two R10 flags for each mode, which only
    /// PaperDesign knows (spec §4.16).
    init(_ theme: QuireTheme) {
        var links: [String: Bool] = [:]
        var quoteLinks: [String: Bool] = [:]
        for mode in QuireMode.allCases {
            links[mode.rawValue] = theme.underlinesLinksAtRest(mode)
            quoteLinks[mode.rawValue] = theme.underlinesQuoteLinksAtRest(mode)
        }
        self.init(id: theme.rawValue, links: links, quoteLinks: quoteLinks)
    }
}
