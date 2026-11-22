import SwiftUI

/// Wrapping words with a link inline after them, on their last line: the multi-line banner (spec §5.38) and the
/// OAuth caption's “How to create these…” (§5.40). The link is a text link handled in place, so it wraps with
/// the words as a button could not. The words take the foreground style; the link is `accent`, underlined at rest
/// where colour alone does not mark it (under Graphite and in a theme whose ink sits near its text ink, §4.16).
///
/// SwiftUI shows no pointing hand over a link in text, so a clear box lies over each line the link's words take, found in
/// the text's own layout, with the hand on it (§4.17); a click there runs the link, as one on the words would.
struct QuireInlineLinkText: View {
    let message: String
    let link: (title: String, action: () -> Void)?
    let role: QuireFont.Role
    let linkRole: QuireFont.Role

    static let linkURL = URL(string: "quire-inline:link")!

    @Environment(\.quireTheme) private var theme
    @Environment(\.quireDrawingFlags) private var flags
    @Environment(\.quireUnderlinesLinksAtRest) private var underlinesLinksAtRest

    init(_ message: String, link: (title: String, action: () -> Void)?, role: QuireFont.Role, linkRole: QuireFont.Role) {
        self.message = message
        self.link = link
        self.role = role
        self.linkRole = linkRole
    }

    var body: some View {
        text
            .quireParagraph(role)
            .tint(accent)
            .fixedSize(horizontal: false, vertical: true)
            .environment(\.openURL, OpenURLAction { url in
                guard url == QuireInlineLinkText.linkURL, let link else { return .systemAction }
                link.action()
                return .handled
            })
            .overlayPreferenceValue(Text.LayoutKey.self) { layouts in
                if let link {
                    GeometryReader { proxy in
                        ForEach(Array(Self.linkBoxes(layouts, in: proxy).enumerated()), id: \.offset) { _, box in
                            // A button, not a tap gesture, so it acts on mouse-up as the words' link does. Keyboard and
                            // VoiceOver keep the link in the text.
                            Button(action: link.action) {
                                Color.clear.contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .focusable(false)
                            .accessibilityHidden(true)
                            .frame(width: box.width, height: box.height)
                            .quirePointer()
                            .position(x: box.midX, y: box.midY)
                        }
                    }
                }
            }
    }

    /// An attributed string's colour is a `Color`, never a style: the theme's, from the environment.
    private var accent: Color { .quire(.accent, theme: theme, flags: flags) }

    /// The words, then the link marked so its runs can be found in the layout.
    private var text: Text {
        guard let link else { return Text(message) }
        let title = Text(linkTitle(link.title)).customAttribute(QuireInlineLinkMark())
        // A link on its own (the Senders sheet's foot before a read counts the other rules) starts the line.
        guard !message.isEmpty else { return title }
        return Text("\(Text(message)) \(title)")
    }

    private func linkTitle(_ words: String) -> AttributedString {
        var title = AttributedString(words)
        title.link = QuireInlineLinkText.linkURL
        title.font = .quire(linkRole)
        title.foregroundColor = accent
        if underlinesLinksAtRest { title.underlineStyle = .single }
        return title
    }

    /// The boxes of the link's runs, one per line it takes, in `proxy`'s coordinates.
    static func linkBoxes(_ layouts: [Text.LayoutKey.AnchoredLayout], in proxy: GeometryProxy) -> [CGRect] {
        var boxes: [CGRect] = []
        for anchored in layouts {
            let origin = proxy[anchored.origin]
            for line in anchored.layout {
                for run in line where run[QuireInlineLinkMark.self] != nil {
                    boxes.append(run.typographicBounds.rect.offsetBy(dx: origin.x, dy: origin.y))
                }
            }
        }
        return boxes
    }
}

/// Marks the link's words in a `QuireInlineLinkText`, so their runs can be found in the text's layout.
struct QuireInlineLinkMark: TextAttribute {}
