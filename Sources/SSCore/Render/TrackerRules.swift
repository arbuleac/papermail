import Foundation

/// What counts as a tracker in a message (spec §5.60), in one place: the known open-tracking endpoints and the two
/// heuristics for an image that is there only to be fetched. The sanitizer asks it about every remote `<img>` at sync
/// time, whatever the setting, and marks what it calls a tracker (`HTMLSanitizer.trackerAttribute`); the reader's content
/// blocker is compiled from `endpoints` (`contentRuleListJSON`), for bodies stored before the marks and for what a body
/// fetches outside an `<img>` (a stylesheet's `url()`).
///
/// False positives are kept low on purpose: a known endpoint is matched by host and path (and a parameter where the path
/// alone is common), never by a word in the address, and the heuristics read only the image's own attributes and inline
/// style. A spacer the heuristics take for a pixel loses nothing visible: a parked image keeps its size and shows the
/// sanitizer's transparent 1×1 stand-in.
public enum TrackerRules {
    /// Raised whenever `endpoints` changes, so the reader's compiled content blocker (cached by WebKit under an
    /// identifier carrying it) is compiled again.
    public static let version = 1

    /// Why an image was called a tracker; the value of the mark the sanitizer leaves on it.
    public enum Reason: String, Hashable, Sendable, CaseIterable {
        /// Its address is a known open-tracking endpoint.
        case known
        /// Drawn at 3 × 3 px or less (both sides), or at zero on either side.
        case tiny
        /// Its own style or the `hidden` attribute keeps it from being seen.
        case hidden
    }

    /// What an `<img>` says about its size and visibility, as written in its own attributes (before the sanitizer's CSS
    /// filter rewrites the style).
    public struct ImageHints: Hashable, Sendable {
        public var width: String?
        public var height: String?
        public var style: String?
        /// The element carries the `hidden` attribute.
        public var hidden: Bool

        public init(width: String? = nil, height: String? = nil, style: String? = nil, hidden: Bool = false) {
            self.width = width
            self.height = height
            self.style = style
            self.hidden = hidden
        }
    }

    /// Whether the remote image at `address` is a tracker, and why; nil for an image that is content. A known endpoint is
    /// a tracker however it is drawn.
    public static func reason(forImageAt address: String, hints: ImageHints) -> Reason? {
        if knownEndpoint(for: address) != nil { return .known }
        let style = hints.style.map(declarations) ?? [:]
        if hints.hidden || isHidden(style) { return .hidden }
        if isTiny(hints, style: style) { return .tiny }
        return nil
    }

    /// The known endpoint `address` is, if any.
    public static func knownEndpoint(for address: String) -> TrackerEndpoint? {
        guard let parts = TrackerAddress(address) else { return nil }
        return endpoints.first { $0.matches(parts) }
    }

    /// The largest side, in CSS pixels, an image may be drawn at on both sides and still count as tiny.
    static let tinySide = 3.0

    // MARK: Known endpoints

    /// Open-tracking endpoints of the mailing services and sales tools that send most tracked mail, by host and path. Some
    /// run under each sender's own domain and are told by a path no real image has (SendGrid, Mailgun, Customer.io,
    /// Marketo, HubSpot, Brevo, Campaign Monitor, Salesforce Marketing Cloud); a host that serves only tracking is matched
    /// whole. Services that send through another's infrastructure (Braze and Iterable through SendGrid or SparkPost,
    /// Substack through Mailgun) are caught by that one's rule, and any pixel these miss is still caught when it is tiny
    /// or hidden.
    public static let endpoints: [TrackerEndpoint] = [
        // Mailing services.
        TrackerEndpoint("Mailchimp", host: "list-manage.com", path: "/track/open.php", match: .exact),
        TrackerEndpoint("Mandrill", host: "mandrillapp.com", path: "/track/open.php", match: .exact),
        TrackerEndpoint("SendGrid", host: "sendgrid.net", path: "/wf/open", match: .exact),
        TrackerEndpoint("SendGrid, a sender's link domain", path: "/wf/open", match: .exact, query: "upn"),
        // Mailgun's tracking addresses carry a zlib stream in base64, which always begins “eJ”.
        TrackerEndpoint("Mailgun, a sender's tracking domain", path: "/o/eJ"),
        TrackerEndpoint("SparkPost", host: "spgo.io", path: "/q/"),
        TrackerEndpoint("SparkPost", host: "sparkpostmail.com", path: "/q/"),
        TrackerEndpoint("Postmark", host: "pstmrk.it"),
        TrackerEndpoint("Amazon SES", host: "awstrack.me"),
        TrackerEndpoint("Mailjet", host: "mjt.lu", path: "/oo/"),
        TrackerEndpoint("Brevo", path: "/tr/op/"),
        TrackerEndpoint("Campaign Monitor", path: "/t/*/o.gif", match: .exact),
        TrackerEndpoint("Constant Contact", host: "rs6.net", path: "/on.jsp", match: .exact),
        // Customer.io's tokens are base64 JSON, which always begins “eyJ”.
        TrackerEndpoint("Customer.io", host: "customer.io", path: "/e/o/"),
        TrackerEndpoint("Customer.io, a sender's tracking domain", path: "/e/o/eyJ"),
        TrackerEndpoint("Klaviyo", host: "klclick.com"),
        TrackerEndpoint("Klaviyo", host: "klclick1.com"),
        TrackerEndpoint("Klaviyo", host: "klclick2.com"),
        TrackerEndpoint("Klaviyo", host: "klclick3.com"),
        TrackerEndpoint("Iterable", host: "iterable.com", path: "/e/eo"),
        TrackerEndpoint("Intercom", host: "intercom-mail.com", path: "/via/o"),
        TrackerEndpoint("Intercom", host: "via.intercom.io", path: "/o", match: .exact),
        TrackerEndpoint("ConvertKit", host: "open.convertkit-mail.com"),
        TrackerEndpoint("ConvertKit", host: "open.convertkit-mail2.com"),
        TrackerEndpoint("Litmus", host: "emltrk.com"),
        // Marketing automation.
        TrackerEndpoint("HubSpot", path: "/e2t/to/"),
        TrackerEndpoint("HubSpot", host: "track.hubspot.com", path: "/__ptq.gif", match: .exact),
        TrackerEndpoint("Marketo", path: "/trk", match: .exact, query: "mid"),
        TrackerEndpoint("Pardot", host: "pardot.com", path: "/r/*/open/"),
        TrackerEndpoint("Salesforce Marketing Cloud", host: "exct.net"),
        TrackerEndpoint("Salesforce Marketing Cloud, a sender's domain", path: "/open.aspx", match: .exact),
        TrackerEndpoint("Oracle Eloqua", host: "eloqua.com", path: "/e/FooterImages/"),
        TrackerEndpoint("Oracle Responsys", path: "/pub/as", match: .exact, query: "_ri_"),
        // Sales tools and read receipts.
        TrackerEndpoint("Mailtrack", host: "mailtrack.io", path: "/trace/"),
        TrackerEndpoint("Mixmax", host: "mixmax.com", path: "/api/track/"),
        TrackerEndpoint("Yesware", host: "t.yesware.com"),
        TrackerEndpoint("Streak", host: "mailfoogae.appspot.com", path: "/t", match: .exact),
        TrackerEndpoint("Superhuman", host: "r.superhuman.com"),
        TrackerEndpoint("Notify", host: "email81.com"),
        TrackerEndpoint("Bananatag", host: "bl-1.com"),
        TrackerEndpoint("Mailbutler", host: "mailbutler.io", path: "/tracking/hit/"),
        TrackerEndpoint("Front", host: "frontapp.com", path: "/api/1/noauth/companies/*/seen"),
        // Social networks' and analytics' pixels.
        TrackerEndpoint("Facebook", host: "facebook.com", path: "/tr", match: .exact),
        TrackerEndpoint("LinkedIn", host: "linkedin.com", path: "/emimp/"),
        TrackerEndpoint("LinkedIn", host: "px.ads.linkedin.com"),
        TrackerEndpoint("X", host: "twitter.com", path: "/scribe/ibis", match: .exact),
        TrackerEndpoint("X", host: "x.com", path: "/scribe/ibis", match: .exact),
        TrackerEndpoint("X", host: "t.co", path: "/i/adsct", match: .exact),
        TrackerEndpoint("X", host: "analytics.twitter.com"),
        TrackerEndpoint("Google Analytics", host: "google-analytics.com"),
        TrackerEndpoint("Google Analytics", host: "stats.g.doubleclick.net"),
    ]

    // MARK: Content blocker

    /// The resource types the content blocker stops: everything a body can fetch without navigating. A link the user
    /// clicks (a document) is never blocked here; its parameters are the link stripping's (`TrackingParameters`).
    public static let blockedResourceTypes = ["image", "style-sheet", "font", "media", "raw"]

    /// `endpoints` as WebKit content blocker rules, one per endpoint since its expressions have no alternation. `scheme`
    /// is `https?` in the app; the tests give their stand-in scheme for the network.
    public static func contentRuleListJSON(scheme: String = "https?") -> String {
        let rules: [[String: Any]] = endpoints.map { endpoint in
            [
                "trigger": ["url-filter": endpoint.urlFilter(scheme: scheme), "resource-type": blockedResourceTypes],
                "action": ["type": "block"],
            ]
        }
        let data = (try? JSONSerialization.data(withJSONObject: rules, options: [.sortedKeys])) ?? Data("[]".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    /// The identifier the compiled rules are cached under: the version and a digest of the rules themselves, so a build
    /// whose rules differ never reuses another's compilation.
    public static func contentRuleListIdentifier(scheme: String = "https?") -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in contentRuleListJSON(scheme: scheme).utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return contentRuleListPrefix + "\(version)-" + String(hash, radix: 16)
    }

    /// What every identifier of these rules starts with, so a build can remove the compilations earlier ones left.
    public static let contentRuleListPrefix = "io.supersparrow.trackers-"

    // MARK: Heuristics

    /// The image's inline style as lowercased property names and values, `!important` dropped; the last declaration of a
    /// property wins, as in CSS.
    static func declarations(_ style: String) -> [String: String] {
        var result: [String: String] = [:]
        for declaration in style.split(separator: ";") {
            guard let colon = declaration.firstIndex(of: ":") else { continue }
            let name = declaration[..<colon].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            var value = declaration[declaration.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if let important = value.range(of: "!important") { value = value[..<important.lowerBound].trimmingCharacters(in: .whitespaces) }
            guard !name.isEmpty else { continue }
            result[name] = value
        }
        return result
    }

    static func isHidden(_ style: [String: String]) -> Bool {
        if style["display"] == "none" { return true }
        if let visibility = style["visibility"], visibility == "hidden" || visibility == "collapse" { return true }
        if let opacity = style["opacity"], let value = number(opacity), value <= 0 { return true }
        for side in ["max-width", "max-height"] {
            if let value = style[side].flatMap(cssLength), value <= 0 { return true }
        }
        return false
    }

    static func isTiny(_ hints: ImageHints, style: [String: String]) -> Bool {
        // The style wins over the attribute, as it does when the image is drawn.
        let width = style["width"].flatMap(cssLength) ?? hints.width.flatMap(attributeLength)
        let height = style["height"].flatMap(cssLength) ?? hints.height.flatMap(attributeLength)
        if width == 0 || height == 0 { return true }
        guard let width, let height else { return false }
        return width <= tinySide && height <= tinySide
    }

    /// A CSS length in pixels: unitless or `px`, or zero in any unit; nil for anything relative or unknown (`auto`, `50%`,
    /// `2em`), which can never make an image tiny.
    static func cssLength(_ value: String) -> Double? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        let digits = trimmed.prefix { $0.isNumber || $0 == "." || $0 == "-" || $0 == "+" }
        guard let number = Double(digits), number >= 0 else { return nil }
        let unit = trimmed.dropFirst(digits.count).trimmingCharacters(in: .whitespaces)
        if number == 0 { return 0 }
        return unit.isEmpty || unit == "px" ? number : nil
    }

    /// An HTML `width` or `height` attribute as browsers read it: the leading number, in pixels unless a `%` follows.
    static func attributeLength(_ value: String) -> Double? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let digits = trimmed.prefix { $0.isNumber || $0 == "." }
        guard let number = Double(digits) else { return nil }
        if trimmed.dropFirst(digits.count).hasPrefix("%") { return number == 0 ? 0 : nil }
        return number
    }

    /// An opacity: a number, or a percentage.
    static func number(_ value: String) -> Double? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        if trimmed.hasSuffix("%") { return Double(trimmed.dropLast()).map { $0 / 100 } }
        return Double(trimmed)
    }
}
