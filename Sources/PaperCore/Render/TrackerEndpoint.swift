import Foundation

/// One known open-tracking endpoint (spec §5.60): the address a sender's pixel loads so the sender learns that, when and
/// where a message was opened. `TrackerRules.endpoints` lists them; the sanitizer matches an image's address against them
/// and the reader's content blocker is compiled from the same values (`TrackerRules.contentRuleListJSON`), so the two
/// layers can never disagree about what a known tracker is.
///
/// A rule names a host, a path and at most one query parameter, all compared without case, as WebKit's content blocker
/// compares them. A host also matches its subdomains (`list-manage.com` matches `us21.list-manage.com`); a rule with no
/// host matches any host and has to be precise in its path instead, which is how an ESP serving pixels from each sender's
/// own branded domain is told (SendGrid's `/wf/open?upn=`). Where a host also serves real images the path narrows it.
public struct TrackerEndpoint: Hashable, Sendable {
    public enum PathMatch: Hashable, Sendable {
        /// The address's path begins with `path`; anything may follow.
        case prefix
        /// The address's path is `path` and nothing more; a query may follow.
        case exact
    }

    /// Who runs it, for the tests' names and the source's readers; never shown.
    public let service: String
    /// The host, or the domain the host is under, lowercased; nil matches any host.
    public let host: String?
    /// Where the path starts, lowercased. One `*` stands for any run of characters inside the path (“/t/*/o.gif”).
    public let path: String
    public let match: PathMatch
    /// A query parameter the address must carry (`upn` for SendGrid's pixel on a sender's own domain), lowercased.
    public let query: String?
    /// `path` around its `*`, or all of it as `head`; worked out once, since every remote image is matched against every
    /// endpoint at sync time.
    private let head: String
    private let tail: String?
    private let dottedHost: String?

    public init(_ service: String, host: String? = nil, path: String = "/", match: PathMatch = .prefix, query: String? = nil) {
        self.service = service
        self.host = host?.lowercased()
        self.path = path.lowercased()
        self.match = match
        self.query = query?.lowercased()
        if let star = self.path.firstIndex(of: "*") {
            head = String(self.path[..<star])
            tail = String(self.path[self.path.index(after: star)...])
        } else {
            head = self.path
            tail = nil
        }
        dottedHost = self.host.map { "." + $0 }
    }

    /// Whether `address` (an http or https URL as the sanitizer keeps it) is this endpoint.
    public func matches(_ address: String) -> Bool {
        guard let parts = TrackerAddress(address) else { return false }
        return matches(parts)
    }

    func matches(_ parts: TrackerAddress) -> Bool {
        if let host, let dottedHost {
            guard parts.host == host || parts.host.hasSuffix(dottedHost) else { return false }
        }
        let path = parts.path
        guard path.hasPrefix(head) else { return false }
        if let tail {
            let rest = path.dropFirst(head.count)
            switch match {
            case .exact: guard rest.hasSuffix(tail) else { return false }
            case .prefix: guard rest.range(of: tail) != nil else { return false }
            }
        } else if match == .exact {
            guard path == head else { return false }
        }
        guard let query else { return true }
        return parts.query.split(separator: "&", omittingEmptySubsequences: true).contains { piece in
            (piece.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).first ?? "") == query
        }
    }

    /// The rule as a WebKit content blocker `url-filter`: the same host, path and parameter, in the subset of regular
    /// expressions WebKit compiles (no alternation, no counted repetition, `$` only at the end). `scheme` is the scheme
    /// part, `https?` in the app; the tests give their stand-in scheme for the network.
    public func urlFilter(scheme: String = "https?") -> String {
        var filter = "^" + scheme + "://"
        if let host {
            filter += "([^/?#]*\\.)?" + Self.escaped(host) + "(:[0-9]+)?"
        } else {
            filter += "[^/?#]+"
        }
        filter += Self.escaped(head)
        if let tail { filter += "[^?#]*" + Self.escaped(tail) }
        switch (match, query) {
        case (.exact, nil):
            filter += "([?#].*)?$"
        case (.exact, let name?):
            filter += "\\?(.*&)?" + Self.escaped(name) + "="
        case (.prefix, nil):
            break
        case (.prefix, let name?):
            filter += "[^?#]*\\?(.*&)?" + Self.escaped(name) + "="
        }
        return filter
    }

    private static func escaped(_ literal: String) -> String {
        var out = ""
        for character in literal {
            if "\\^$.|?*+()[]{}".contains(character) { out.append("\\") }
            out.append(character)
        }
        return out
    }
}

/// The parts of an http or https address a tracker rule reads: the host (without user, port or a trailing dot), the path
/// (`/` when there is none, backslashes read as slashes, as browsers read them in these schemes) and the query, all
/// lowercased, since the rules compare without case.
struct TrackerAddress: Hashable, Sendable {
    var host: String
    var path: String
    var query: String

    init?(_ address: String) {
        guard let separator = address.range(of: "://") else { return nil }
        let scheme = address[..<separator.lowerBound].lowercased()
        guard scheme == "http" || scheme == "https" else { return nil }
        let rest = address[separator.upperBound...]
        let authorityEnd = rest.firstIndex { $0 == "/" || $0 == "?" || $0 == "#" || $0 == "\\" } ?? rest.endIndex
        var authority = rest[..<authorityEnd]
        if let at = authority.lastIndex(of: "@") { authority = authority[authority.index(after: at)...] }
        if authority.hasPrefix("[") {
            if let close = authority.firstIndex(of: "]") { authority = authority[...close] }
        } else if let colon = authority.firstIndex(of: ":") {
            authority = authority[..<colon]
        }
        var host = authority.lowercased()
        while host.hasSuffix(".") { host.removeLast() }
        guard !host.isEmpty else { return nil }
        self.host = host
        let tail = rest[authorityEnd...]
        let pathEnd = tail.firstIndex { $0 == "?" || $0 == "#" } ?? tail.endIndex
        let path = tail[..<pathEnd].replacingOccurrences(of: "\\", with: "/").lowercased()
        self.path = path.isEmpty ? "/" : path
        if pathEnd < tail.endIndex, tail[pathEnd] == "?" {
            let queryStart = tail.index(after: pathEnd)
            let queryEnd = tail[queryStart...].firstIndex(of: "#") ?? tail.endIndex
            query = tail[queryStart..<queryEnd].lowercased()
        } else {
            query = ""
        }
    }
}
