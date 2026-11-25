import Foundation

/// The service an event's call runs on, as the provider names it (Google's conference solution, Graph's
/// `onlineMeetingProvider`) or as its join address's host says (docs/DATA-MODEL.md, `calendar_events.call_service`). The
/// face and the details name the call after it: “Google Meet”, “Teams”, “Zoom”, “Webex”, “Skype”, else “Video call”.
public enum CallService: String, Codable, Sendable, CaseIterable {
    case meet, teams, zoom, webex, skype, other

    /// The service a join address's host belongs to, or nil for a host it does not know. Only the service's own domain
    /// or a subdomain of it counts: a bare suffix would name a look-alike (`securezoom.us`, a link from a stranger's
    /// invitation) after the service it imitates.
    public init?(host: String?) {
        guard let host = host?.lowercased(), !host.isEmpty else { return nil }
        if Self.isDomain(host, "meet.google.com") {
            self = .meet
        } else if Self.isDomain(host, "teams.microsoft.com") || Self.isDomain(host, "teams.live.com") {
            self = .teams
        } else if Self.isDomain(host, "zoom.us") || Self.isDomain(host, "zoom.com") {
            self = .zoom
        } else if Self.isDomain(host, "webex.com") {
            self = .webex
        } else {
            return nil
        }
    }

    /// The service of a join address (`init(host:)` on its host), nil when the address does not parse or its host is
    /// not a known one.
    public init?(joinURL: String?) {
        guard let joinURL, let host = URL(string: joinURL.trimmingCharacters(in: .whitespacesAndNewlines))?.host else {
            return nil
        }
        self.init(host: host)
    }

    /// `host` is `domain` or one of its subdomains.
    private static func isDomain(_ host: String, _ domain: String) -> Bool {
        host == domain || host.hasSuffix("." + domain)
    }
}
