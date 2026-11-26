import Foundation

/// The one rule for a link that comes from a calendar event (its join address, its place, a link in its notes, a phone
/// number): what the notes reader keeps as a link at sync time, what the providers take as a call from a place, and what
/// the window's opener opens on a click (docs/DESIGN-LANGUAGE.md §5.54, §5.60). Everything else stays text.
public enum EventLinkPolicy {
    /// The longest address kept as a link: a longer one is someone hiding something in it.
    public static let maxLength = 2_048

    /// `url` when it may open: https with a host and no user name or password (`https://zoom.us@evil.test` names
    /// `evil.test`), or a `tel:` number of dialling characters only; nil for anything else (http, mailto, javascript,
    /// data, file, a scheme an app registered).
    public static func checked(_ url: URL) -> URL? {
        let text = url.absoluteString
        guard text.count <= maxLength, let scheme = url.scheme?.lowercased() else { return nil }
        switch scheme {
        case "https":
            guard let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else { return nil }
            // A user name with no password parses as no user on some inputs: an `@` before the host is refused outright.
            let afterScheme = text.dropFirst("https://".count)
            let authority = afterScheme.prefix { $0 != "/" && $0 != "?" && $0 != "#" }
            guard !authority.contains("@") else { return nil }
            return url
        case "tel":
            return isDialable(String(text.dropFirst("tel:".count))) ? url : nil
        default:
            return nil
        }
    }

    /// `checked` on an address as written, trimmed; nil when it does not parse or contains white space.
    public static func checked(_ address: String) -> URL? {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: \.isWhitespace), let url = URL(string: trimmed) else { return nil }
        return checked(url)
    }

    /// An https address only (a join address, a place, Open in…, More phone numbers).
    public static func web(_ address: String?) -> URL? {
        guard let address, let url = checked(address), url.scheme?.lowercased() == "https" else { return nil }
        return url
    }

    /// A place that is exactly one https address on a known call host (a Zoom link pasted into the location): the call
    /// to join, as written. Never any other host.
    public static func callAddress(inLocation location: String?) -> String? {
        guard let location = location?.trimmingCharacters(in: .whitespacesAndNewlines), let url = web(location),
              CallService(host: url.host) != nil else { return nil }
        return location
    }

    /// The `tel:` URL that dials `dial` (“+15550134,,601225430#”): `#` written `%23`, as a URL must carry it.
    public static func phoneURL(_ dial: String) -> URL? {
        let encoded = dial.replacingOccurrences(of: "#", with: "%23").replacingOccurrences(of: " ", with: "")
        guard isDialable(encoded), let url = URL(string: "tel:" + encoded) else { return nil }
        return url
    }

    /// Only `+`, digits, `-`, `.`, `(`, `)`, `,`, `;`, `*`, spaces (as `%20`) and `%23`, with at least one digit.
    static func isDialable(_ number: String) -> Bool {
        var rest = Substring(number)
        var digits = 0
        while let first = rest.first {
            if rest.hasPrefix("%23") || rest.hasPrefix("%20") {
                rest = rest.dropFirst(3)
                continue
            }
            if first.isASCII, first.isNumber {
                digits += 1
            } else if !"+-.(),;* ".contains(first) {
                return false
            }
            rest = rest.dropFirst()
        }
        return digits > 0
    }
}
