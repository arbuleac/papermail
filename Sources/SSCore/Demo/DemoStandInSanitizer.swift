import Foundation

/// The demo's sanitizer (spec §5.43): `base`, then the demo's remote images pointed at pictures made on this Mac, so a
/// demo message can show remote images loading, and trackers held back beside them (spec §5.60), without a request
/// leaving the Mac. Every demo newsletter's hero is one, so loading images anywhere in the demo fetches nothing but its
/// open pixels, which Block trackers holds back. A demo body names such an image at `host` (`https://stand-in.demo.test/hero.svg`); the sanitizer parks
/// it like any remote image (or keeps it live while Load remote images is on), and this puts a `data:` picture where its
/// address was, in either form. So Load images restores a picture that is already here, and the banner still counts it as
/// a remote image. Nothing else in a body changes.
public struct DemoStandInSanitizer: BodySanitizing {
    public let base: any BodySanitizing

    public init(base: any BodySanitizing) {
        self.base = base
    }

    public func sanitize(_ body: MessageBody, messageID: MessageID) -> SanitizedBody {
        var sanitized = base.sanitize(body, messageID: messageID)
        sanitized.html = Self.pointingAtStandIns(sanitized.html)
        return sanitized
    }

    /// The host demo bodies name their stand-in images at: reserved for tests (RFC 2606), so it can never be a real one.
    public static let host = "stand-in.demo.test"

    /// The address a demo body writes for the stand-in called `name`.
    public static func address(_ name: String) -> String {
        "https://" + host + "/" + name
    }

    /// `html` with every stand-in address that names a known picture replaced by the picture.
    static func pointingAtStandIns(_ html: String) -> String {
        let prefix = address("")
        guard html.contains(prefix) else { return html }
        var result = ""
        var rest = html[...]
        while let found = rest.range(of: prefix) {
            result += rest[..<found.lowerBound]
            let tail = rest[found.upperBound...]
            let end = tail.firstIndex { $0 == "\"" || $0 == "'" || $0 == "?" || $0 == "#" || $0 == " " } ?? tail.endIndex
            let name = String(tail[..<end])
            if let picture = pictures[name] {
                result += picture
            } else {
                result += prefix + name
            }
            rest = tail[end...]
        }
        result += rest
        return result
    }

    /// The pictures, as SVG `data:` URIs: small, sharp at any scale, and drawn only (an SVG in an `<img>` runs nothing).
    static let pictures: [String: String] = {
        var pictures: [String: String] = [:]
        for (name, svg) in svgs {
            pictures[name] = "data:image/svg+xml;base64," + Data(svg.utf8).base64EncodedString()
        }
        return pictures
    }()

    /// Every demo newsletter's hero (`DemoHTML.newsletter`), and Trailhead Outfitters' issue (the tracker sample): a hero
    /// and three product tiles of its own.
    private static let svgs: [String: String] = [
        "newsletter-hero.svg": """
            <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 600 240" width="600" height="240">\
            <rect width="600" height="240" fill="#E9EEF3"/><circle cx="120" cy="84" r="40" fill="#F2C46D"/>\
            <path d="M0 180 C120 130 220 210 340 160 C440 120 520 150 600 130 L600 240 L0 240 Z" fill="#B9C9D8"/>\
            <path d="M0 206 C140 178 260 230 400 196 C480 178 540 190 600 182 L600 240 L0 240 Z" fill="#8FA6BC"/></svg>
            """,
        "trailhead-hero.svg": """
            <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 600 240" width="600" height="240">\
            <defs><linearGradient id="s" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#F6C98B"/>\
            <stop offset="1" stop-color="#F3E6CF"/></linearGradient></defs>\
            <rect width="600" height="240" fill="url(#s)"/><circle cx="430" cy="92" r="34" fill="#F7A24B"/>\
            <path d="M0 190 L110 92 L170 140 L260 60 L360 160 L430 118 L520 176 L600 130 L600 240 L0 240 Z" fill="#6E8F7A"/>\
            <path d="M260 60 L292 88 L276 86 L262 98 L246 84 L232 90 Z" fill="#F7F3EA"/>\
            <path d="M0 214 L90 160 L180 200 L290 140 L400 206 L500 168 L600 204 L600 240 L0 240 Z" fill="#2E7D4F"/>\
            <path d="M60 240 L60 214 M52 222 L60 206 L68 222 Z M540 240 L540 208 M531 218 L540 198 L549 218 Z" \
            stroke="#1F5A39" stroke-width="3" fill="#1F5A39"/></svg>
            """,
        "trailhead-pack.svg": """
            <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 180 120" width="180" height="120">\
            <rect width="180" height="120" fill="#EEF3EF"/>\
            <rect x="62" y="24" width="56" height="78" rx="14" fill="#2E7D4F"/><rect x="70" y="56" width="40" height="30" rx="6" fill="#256641"/>\
            <path d="M74 26 C74 12 106 12 106 26" stroke="#1F5A39" stroke-width="5" fill="none"/>\
            <rect x="76" y="40" width="28" height="5" rx="2.5" fill="#F7A24B"/></svg>
            """,
        "trailhead-lamp.svg": """
            <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 180 120" width="180" height="120">\
            <rect width="180" height="120" fill="#F4EFE6"/>\
            <path d="M40 70 C40 44 140 44 140 70" stroke="#3B4A42" stroke-width="7" fill="none"/>\
            <rect x="72" y="50" width="36" height="28" rx="8" fill="#3B4A42"/><circle cx="90" cy="64" r="9" fill="#F7D774"/>\
            <path d="M90 78 L60 108 L120 108 Z" fill="#F7D774" opacity="0.45"/></svg>
            """,
        "trailhead-mug.svg": """
            <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 180 120" width="180" height="120">\
            <rect width="180" height="120" fill="#EAF0F2"/>\
            <rect x="64" y="40" width="44" height="52" rx="6" fill="#2F6F8F"/>\
            <path d="M108 52 C126 52 126 80 108 80" stroke="#2F6F8F" stroke-width="7" fill="none"/>\
            <path d="M76 20 C70 28 82 30 76 36 M90 18 C84 26 96 28 90 34" stroke="#9DB3BC" stroke-width="3" fill="none"/></svg>
            """,
    ]
}
