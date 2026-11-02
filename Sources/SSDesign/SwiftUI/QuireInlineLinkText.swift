import SwiftUI

/// Wrapping words with a link inline after them, on their last line: the multi-line banner (spec §5.38) and the
/// OAuth caption's “How to create these…” (§5.40). The link is a text link handled in place, so it wraps with
/// the words as a button could not. The words take the foreground style; the link is `accent`.
struct QuireInlineLinkText: View {
    let message: String
    let link: (title: String, action: () -> Void)?
    let role: QuireFont.Role
    let linkRole: QuireFont.Role

    static let linkURL = URL(string: "quire-inline:link")!

    init(_ message: String, link: (title: String, action: () -> Void)?, role: QuireFont.Role, linkRole: QuireFont.Role) {
        self.message = message
        self.link = link
        self.role = role
        self.linkRole = linkRole
    }

    var body: some View {
        Text(attributed)
            .quireParagraph(role)
            .tint(Color.qAccent)
            .fixedSize(horizontal: false, vertical: true)
            .environment(\.openURL, OpenURLAction { url in
                guard url == QuireInlineLinkText.linkURL, let link else { return .systemAction }
                link.action()
                return .handled
            })
    }

    var attributed: AttributedString {
        var text = AttributedString(message)
        if let link {
            var title = AttributedString(link.title)
            title.link = QuireInlineLinkText.linkURL
            title.font = .quire(linkRole)
            title.foregroundColor = Color.qAccent
            text += AttributedString(" ") + title
        }
        return text
    }
}
