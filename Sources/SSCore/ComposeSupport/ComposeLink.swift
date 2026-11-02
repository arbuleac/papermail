import Foundation

/// What the link popover accepts (spec §5.20): a web address, with or without its scheme, or an email
/// address, which becomes a `mailto:` link. Anything else gets the field error `invalidMessage`.
public enum ComposeLink {
    public static let invalidMessage = "Enter a web address or an email address."

    /// The link target for `raw`, or nil when it is empty or not an address. Bare domains get `https://`.
    public static func normalized(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: \.isWhitespace) else { return nil }
        let lower = trimmed.lowercased()
        if lower.hasPrefix("mailto:") {
            return AddressListParser.isValid(String(trimmed.dropFirst("mailto:".count))) ? trimmed : nil
        }
        if trimmed.contains("://") {
            // A web address means http or https: `javascript://`, `file://` and `smb://` would go out as links
            // the popover never promised.
            guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
                  let host = url.host, !host.isEmpty else { return nil }
            return trimmed
        }
        if trimmed.contains("@"), !trimmed.contains("/") {
            return AddressListParser.isValid(trimmed) ? "mailto:" + trimmed : nil
        }
        let candidate = "https://" + trimmed
        guard let url = URL(string: candidate), let host = url.host, isPlausibleHost(host) else { return nil }
        return candidate
    }

    /// A dotted host whose labels are non-empty and whose last label has at least two letters, or localhost.
    static func isPlausibleHost(_ host: String) -> Bool {
        if host == "localhost" { return true }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, labels.allSatisfy({ !$0.isEmpty }), let last = labels.last else { return false }
        return last.count >= 2 && last.allSatisfy(\.isLetter)
    }
}
