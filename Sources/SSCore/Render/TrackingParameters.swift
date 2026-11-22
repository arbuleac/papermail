import Foundation

/// The query parameters a sender adds to a link so the page it opens can tell who clicked and from which mail
/// (spec §5.60). While Block trackers is on, a link the user opens from a message reaches the browser without them.
///
/// Conservative on purpose: only parameters that exist to track (campaign tags, click ids, a mailing service's subscriber
/// ids) are listed, never one a page may need to work. The rest of the address is left exactly as written: the other
/// parameters in their order and spelling, the path and the fragment. A link whose query carries another address is a
/// redirect (a mailing service's click tracking, a safe-links wrapper), which may check its own parameters, so it is left
/// whole: it reaches the browser as the sender wrote it. So is a link to an unsubscribe, preferences or web-view page,
/// where the same ids are how the sender knows who is asking (Marketo's `mkt_tok` on `UnsubscribePage.html` and
/// `emailWebview`, HubSpot's `_hsenc` on its preference centre): stripped, the user would be asked who they are, or the
/// request would not be applied.
public enum TrackingParameters {
    /// Names compared without case. Any name starting with one of `prefixes` counts too.
    public static let names: Set<String> = [
        // Ad networks' click ids.
        "fbclid", "gclid", "dclid", "gbraid", "wbraid", "msclkid", "yclid", "igshid", "twclid", "ttclid", "li_fat_id", "epik",
        // Mailing services' subscriber and campaign ids.
        "mc_cid", "mc_eid", "_hsenc", "_hsmi", "__hssc", "__hstc", "__hsfp", "hsctatracking", "mkt_tok", "oly_anon_id",
        "oly_enc_id", "vero_id", "vero_conv", "_kx", "ck_subscriber_id", "ml_subscriber", "ml_subscriber_hash", "_bta_tid",
        "_bta_c", "trk_contact", "trk_msg", "trk_module", "trk_sid", "ss_email_id", "rb_clickid", "wickedid",
    ]

    /// Google Analytics' campaign tags: `utm_source`, `utm_medium`, `utm_campaign` and the rest.
    public static let prefixes = ["utm_"]

    /// Words in a path, compared without case, that make it a page about the subscription itself (an unsubscribe,
    /// preferences or web-view page), whose links are left whole.
    public static let subscriptionPathWords = ["unsubscribe", "optout", "opt-out", "opt_out", "preference", "subscription", "webview"]

    /// `url` without its tracking parameters; `url` itself when it has none, is not http or https, is a redirect, or leads
    /// to a page about the subscription.
    public static func stripped(_ url: URL) -> URL {
        let address = url.absoluteString
        let result = stripped(address)
        guard result != address else { return url }
        return URL(string: result) ?? url
    }

    /// `address` without its tracking parameters, as `stripped(_:)` for a URL.
    public static func stripped(_ address: String) -> String {
        guard let scheme = URLPolicy.scheme(of: address), scheme == "http" || scheme == "https",
              let mark = address.firstIndex(of: "?") else { return address }
        // A fragment before the mark holds the mark: the address has no query.
        let fragment = address.firstIndex(of: "#")
        if let fragment, fragment < mark { return address }
        let queryEnd = fragment ?? address.endIndex
        if isSubscriptionPage(address[..<mark]) { return address }
        let query = address[address.index(after: mark)..<queryEnd]
        var kept: [Substring] = []
        var removed = false
        for piece in query.split(separator: "&", omittingEmptySubsequences: false) {
            let parts = piece.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let name = decoded(parts.first ?? "")
            if parts.count == 2, isAddress(decoded(parts[1])) { return address }
            if isTracking(name) {
                removed = true
            } else {
                kept.append(piece)
            }
        }
        guard removed else { return address }
        let head = address[..<mark]
        let tail = address[queryEnd...]
        let rest = kept.joined(separator: "&")
        return String(head) + (rest.isEmpty ? "" : "?" + rest) + String(tail)
    }

    /// Whether a parameter of this name is there to track.
    public static func isTracking(_ name: String) -> Bool {
        let lowered = name.lowercased()
        return names.contains(lowered) || prefixes.contains { lowered.hasPrefix($0) && lowered.count > $0.count }
    }

    /// Whether the address up to its query (`https://host/path`) leads to a page about the subscription: only the path is
    /// read, so a host's name never counts.
    private static func isSubscriptionPage(_ head: Substring) -> Bool {
        guard let separator = head.range(of: "://") else { return false }
        let rest = head[separator.upperBound...]
        guard let slash = rest.firstIndex(of: "/") else { return false }
        let path = decoded(rest[slash...]).lowercased()
        return subscriptionPathWords.contains { path.contains($0) }
    }

    private static func decoded(_ part: Substring) -> String {
        let text = String(part).replacingOccurrences(of: "+", with: " ")
        return text.removingPercentEncoding ?? text
    }

    private static func isAddress(_ value: String) -> Bool {
        let lowered = value.trimmingCharacters(in: .whitespaces).lowercased()
        return lowered.hasPrefix("http://") || lowered.hasPrefix("https://") || lowered.hasPrefix("//")
    }
}
