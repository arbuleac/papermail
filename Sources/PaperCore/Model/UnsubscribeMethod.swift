import Foundation

/// The one way Paper asks a mailing list to stop sending a message, read from its `List-Unsubscribe`
/// (RFC 2369) and `List-Unsubscribe-Post` (RFC 8058) headers, in this order of preference:
///
/// - `oneClick`: both headers allow an RFC 8058 one-click request, a POST of `List-Unsubscribe=One-Click` to the
///   https URI. The engine sends it itself, with no cookie or credential of the user's.
/// - `mailto`: a mailto URI naming one recipient. The engine sends the message it describes from the account, silently.
/// - `browser`: the sender's page, opened in the browser: an https URI, or an http one when nothing else is offered.
///
/// Reading the headers is a scan of two short strings, never of HTML, so the reader asks as it renders.
public enum UnsubscribeMethod: Hashable, Codable, Sendable {
    case oneClick(URL)
    case mailto(URL)
    case browser(URL)

    /// The exact `List-Unsubscribe-Post` value RFC 8058 defines; anything else is not a one-click promise.
    public static let oneClickPostValue = "List-Unsubscribe=One-Click"
    /// The body a one-click request carries, form encoded (RFC 8058 §3.2).
    public static let oneClickBody = "List-Unsubscribe=One-Click"
    /// The subject a mailto request goes out with when its link names none.
    public static let defaultMailSubject = "Unsubscribe"

    /// A header longer than this is not a list's: nothing is read from it.
    static let maxHeaderLength = 8 * 1024
    /// A URI longer than this is skipped.
    static let maxURILength = 2048

    /// The method the headers offer, or nil when they offer none Paper uses (no usable mailto, https or http
    /// URI). `post` counts only beside an https URI and only when it is exactly `List-Unsubscribe=One-Click`.
    public init?(listUnsubscribe: String?, post: String?) {
        guard let list = listUnsubscribe, list.utf8.count <= Self.maxHeaderLength else { return nil }
        var https: URL?
        var mailto: URL?
        var http: URL?
        for uri in Self.uris(in: list) where uri.utf8.count <= Self.maxURILength {
            guard let url = URL(string: uri), let scheme = url.scheme?.lowercased() else { continue }
            switch scheme {
            case "https" where https == nil && Self.isWebPage(url): https = url
            case "http" where http == nil && Self.isWebPage(url): http = url
            case "mailto" where mailto == nil && Self.recipient(of: MailtoLink(string: uri)) != nil: mailto = url
            default: continue
            }
        }
        if let https, Self.isOneClick(post) {
            self = .oneClick(https)
        } else if let mailto {
            self = .mailto(mailto)
        } else if let page = https ?? http {
            self = .browser(page)
        } else {
            return nil
        }
    }

    /// A header value as the providers store it: trimmed, nil when empty or longer than any list's.
    public static func capturedHeader(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty,
              trimmed.utf8.count <= maxHeaderLength else { return nil }
        return trimmed
    }

    /// The method `message`'s stored headers offer; nil for a message stored before they were kept.
    public init?(message: MessageMetadata) {
        self.init(listUnsubscribe: message.listUnsubscribe, post: message.listUnsubscribePost)
    }

    /// The URI the method uses.
    public var url: URL {
        switch self {
        case .oneClick(let url), .mailto(let url), .browser(let url): return url
        }
    }

    /// Whether the engine sends it (a one-click POST or a mailto request) rather than the browser opening a page.
    public var isRequest: Bool {
        if case .browser = self { return false }
        return true
    }

    /// What a mailto method sends from `accountID`: to the link's one recipient, with its subject (“Unsubscribe” when
    /// it gives none) and its body as plain text. Its Cc and Bcc are never used. Nil for the other methods.
    public func mailMessage(from accountID: AccountID) -> OutgoingMessage? {
        guard case .mailto(let url) = self, let link = MailtoLink(url: url), let recipient = Self.recipient(of: link) else { return nil }
        let subject = link.subject.trimmingCharacters(in: .whitespaces)
        let lines = link.body.components(separatedBy: "\n").map(HTMLEscaping.escape)
        return OutgoingMessage(
            accountID: accountID,
            to: [recipient],
            subject: subject.isEmpty ? Self.defaultMailSubject : subject,
            // Graph sends the HTML alone, so it carries the same words as the text.
            html: link.body.isEmpty ? "" : "<div>" + lines.joined(separator: "<br>") + "</div>",
            text: link.body
        )
    }

    // MARK: Parsing

    /// The angle-bracketed URIs of an RFC 2369 header, in order. Comments (nested, with quoted pairs) are skipped,
    /// the white space RFC 2369 lets a long URI be broken with is removed, and anything else outside the brackets
    /// (the commas, stray words) is ignored. An unclosed bracket ends the list.
    static func uris(in header: String) -> [String] {
        var result: [String] = []
        var current: String?
        var commentDepth = 0
        var escaped = false
        for character in header {
            if var uri = current {
                if character == ">" {
                    result.append(uri)
                    current = nil
                } else if !character.isWhitespace {
                    uri.append(character)
                    current = uri
                }
                continue
            }
            if commentDepth > 0 {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "(" {
                    commentDepth += 1
                } else if character == ")" {
                    commentDepth -= 1
                }
                continue
            }
            if character == "(" {
                commentDepth = 1
            } else if character == "<" {
                current = ""
            }
        }
        return result
    }

    /// The one address a mailto request goes to. The mail leaves silently, from the user's account, with words the
    /// sender chose, so it goes to the list's own address and nowhere else: a link naming several recipients is not a
    /// usable request (the page, if offered, is used instead), and its Cc and Bcc are ignored.
    private static func recipient(of link: MailtoLink?) -> EmailAddress? {
        guard let to = link?.to, to.count == 1 else { return nil }
        return to[0]
    }

    /// RFC 8058 asks for exactly this value; the white space around a header value is not part of it.
    static func isOneClick(_ post: String?) -> Bool {
        post?.trimmingCharacters(in: .whitespacesAndNewlines) == oneClickPostValue
    }

    /// A page with a host and no user name or password in it: a request carries nothing that identifies the user
    /// beyond what the sender put in the path.
    private static func isWebPage(_ url: URL) -> Bool {
        guard let host = url.host, !host.isEmpty else { return false }
        return url.user == nil && url.password == nil
    }
}
