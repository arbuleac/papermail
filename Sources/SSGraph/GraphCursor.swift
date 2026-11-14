import Foundation
import SSCore

/// The opaque change cursor: one delta link per folder plus what is needed to seed folders that have none yet.
///
/// JSON shape: `{"folders": {folderId: deltaLink | null}, "nextLinks": {folderId: nextLink}, "wellKnown":
/// {name: folderId}, "since": ISO date, "foldersResolvedAt": ISO date, "fullVisitAt": ISO date, "fullVisitAfter":
/// folderId, "polledAt": ISO date, "walk": {"found": [folderId], "pending": [{"id": folderId, "depth": n,
/// "nextLink": link, "failures": n}], "gaveUp": true}, "missed": [folderId], "recheck": {messageId: n},
/// "folderFailures": {folderId: n}, "folderScope": "tree", "deltaScope": "mailbox"}`. `recheck` and `folderFailures`
/// are absent while empty, so a healthy poll's cursor does not grow. `fullVisitAt` is absent from cursors written before polls were thinned; a cursor without it starts a
/// full visit on its next call. `fullVisitAfter` and `walk` are absent from older cursors and whenever no full visit
/// or folder walk is under way; a walk's `pending` names the top level with an empty id, and its optional keys are
/// absent until a listing stops partway, fails or is given up on. `polledAt` is absent only from cursors written
/// before visits were spread over calls and from a bootstrap cursor: every changes call writes it. `missed` is
/// absent while the last finished walk found every folder.
///
/// `folderScope` marks a folder set found by walking the whole tree. Cursors without it were listed two levels
/// deep, so their folder refresh is due on decode and their next call starts a walk rather than waiting out the
/// day since that listing.
///
/// `deltaScope` marks links seeded without a `$filter`. Graph keeps a delta's original query inside its
/// state token, and the only filter message delta accepts (`receivedDateTime ge …`) also limits which
/// messages the delta tracks; links from cursors without the marker were seeded with that filter, so
/// they are dropped on decode and every folder starts a fresh, unfiltered delta.
struct GraphCursor: Equatable, Sendable {
    static let folderRefreshInterval: TimeInterval = 24 * 60 * 60
    /// How often a full visit may start: a round over every quiet folder (outside the priority set, sitting on its
    /// delta link). The live lane calls every 5 s and Outlook allows 10,000 requests per 10 minutes per mailbox:
    /// polling forty folders on every call would spend 4,800 of them, while the inbox, sent and drafts every call
    /// and the rest twice a minute spend 1,100. New mail lands in the priority folders; a rule filing mail
    /// elsewhere or a move made on another device can wait half a minute.
    static let fullVisitInterval: TimeInterval = 30
    /// How fast a full visit goes through the quiet folders, for each second since the last call. A visit of every
    /// folder in one call cost one request per folder, and past the 33 requests the live lane counts as a heavy page
    /// its next poll, the inbox's included, waited for its share of the quota to cover that much again; a tree of
    /// 200 folders held new mail back about 36 s a poll. Two folders a second keeps the quiet folders' spend to 120
    /// requests a minute, under half the live share of 333 with the priority folders' 36, so the share also has room
    /// for new mail's bodies. Up to 60 quiet folders that is still a visit every 30 s; beyond, a visit takes a
    /// second for every two folders.
    static let quietVisitsPerSecond: Double = 2
    /// The most quiet folders one call polls, however long since the last: with the three priority folders, a seed
    /// page and a step of a folder walk (at most seven: six system folder lookups and a listing page to start one,
    /// `GraphProvider.maxWalkPagesPerCall` pages to go on with one), a call stays within the 33 requests past which
    /// the live lane counts a page as heavy, so a quiet poll never holds back the next one. Polled every 30 s in the
    /// background, it is what paces a visit: twenty folders a poll.
    static let maxQuietVisitsPerCall = 20
    /// Every delta link in a cursor carrying this scope tracks the folder's whole content.
    static let mailboxScope = "mailbox"
    /// The folders of a cursor carrying this scope were found at any depth.
    static let treeScope = "tree"

    /// `nil` means the folder's delta has not been seeded yet.
    var folders: [String: String?]
    /// Pages still to fetch before a folder reaches its next delta link; kept so an interrupted poll resumes.
    var nextLinks: [String: String]
    var wellKnown: [String: String]
    /// Bootstrap start. Kept for diagnostics and older cursors; deltas are no longer filtered by it.
    var since: String
    var foldersResolvedAt: String?
    /// When the latest full visit started; `nil` until the first one.
    var fullVisitAt: String?
    /// While a full visit is under way, spread over calls: the last quiet folder it polled, the visit going on in
    /// folder id order after it, so a folder added or dropped meanwhile shifts nothing. Empty when the visit has
    /// started and polled none yet; `nil` when none is under way.
    var fullVisitAfter: String?
    /// When the last call ran: the time since is what earns the next call its quiet folders.
    var polledAt: String?
    /// A folder walk under way, spread over calls; `nil` between walks.
    var walk: GraphFolderWalk?
    /// Folders the last finished walk did not find, still polled on their delta links until a second walk in a row
    /// misses them. A walk spread over calls misses a folder moved meanwhile out of a listing still to come into one
    /// already sent; dropped at once, it would go unpolled until the next walk a day later.
    var missed: Set<String>
    /// Messages a delta reported (a removal, or a change with only what changed) whose lookup the service failed (a
    /// 5xx or the network, for the part or its whole `$batch`), with the calls that have failed it so far. The next
    /// call looks them up again first; the delta links move on meanwhile, so the outage holds no new mail back.
    var recheck: [String: Int]
    /// Folders whose delta request failed on the last calls in a row (anything but a throttle, a refused token or a
    /// 404: a 5xx, the network, a 403 or 400), and how many. A folder that failed waits behind the others for the seed
    /// page; at `GraphProvider.maxFolderFailures` it is asked only on full visits, and one Graph refused (not the
    /// service failing) starts a fresh round. Cleared for a folder once it answers.
    var folderFailures: [String: Int]

    init(
        folders: [String: String?],
        nextLinks: [String: String] = [:],
        wellKnown: [String: String],
        since: String,
        foldersResolvedAt: String? = nil,
        fullVisitAt: String? = nil,
        fullVisitAfter: String? = nil,
        polledAt: String? = nil,
        walk: GraphFolderWalk? = nil,
        missed: Set<String> = [],
        recheck: [String: Int] = [:],
        folderFailures: [String: Int] = [:]
    ) {
        self.folders = folders
        self.nextLinks = nextLinks
        self.wellKnown = wellKnown
        self.since = since
        self.foldersResolvedAt = foldersResolvedAt
        self.fullVisitAt = fullVisitAt
        self.fullVisitAfter = fullVisitAfter
        self.polledAt = polledAt
        self.walk = walk
        self.missed = missed
        self.recheck = recheck
        self.folderFailures = folderFailures
    }

    func deltaLink(for folderID: String) -> String? {
        folders[folderID] ?? nil
    }

    func needsFolderRefresh(at now: Date) -> Bool {
        guard let stamp = foldersResolvedAt, let resolved = GraphDate.parse(stamp) else { return true }
        return now.timeIntervalSince(resolved) >= Self.folderRefreshInterval
    }

    /// Whether a new full visit may start. A missing or unreadable stamp, or one in the future because the clock was
    /// set back, counts as due so the other folders are never starved. The stamp has second precision and is
    /// truncated, so a visit is at most a second early, never late.
    func needsFullVisit(at now: Date) -> Bool {
        guard let stamp = fullVisitAt, let visited = GraphDate.parse(stamp) else { return true }
        let elapsed = now.timeIntervalSince(visited)
        return elapsed < 0 || elapsed >= Self.fullVisitInterval
    }

    /// How many quiet folders a call at `now` may poll: `quietVisitsPerSecond` for each second since the last call,
    /// at most `maxQuietVisitsPerCall`. Without a readable stamp, or with one in the future because the clock was set
    /// back, the call gets the most, so the quiet folders are never starved. The stamp is truncated to the second,
    /// which can add up to two folders to a call; so the engine's further calls while a page says `hasMore`, which
    /// come within a second, poll two at most.
    func quietVisitAllowance(at now: Date) -> Int {
        guard let stamp = polledAt, let last = GraphDate.parse(stamp) else { return Self.maxQuietVisitsPerCall }
        let elapsed = now.timeIntervalSince(last)
        guard elapsed >= 0 else { return Self.maxQuietVisitsPerCall }
        return Int(Swift.min(Double(Self.maxQuietVisitsPerCall), elapsed * Self.quietVisitsPerSecond))
    }

    /// Takes in a step of a folder walk: each folder `found` in it that the cursor lacks gets an entry with no delta
    /// link yet, so it starts seeding before the walk ends. Once the walk is finished, a folder it did not find is
    /// dropped with its nextLink if the walk before missed it too, and otherwise kept in `missed`; the system folders
    /// always stay (they are looked up by name, in case the listing missed one). A walk that gave up on a listing
    /// did not look under every folder, so it drops nothing and adds nothing to `missed`.
    mutating func takeIn(_ step: GraphFolderWalk, found: [String]) {
        for id in found + wellKnown.values where folders.index(forKey: id) == nil {
            folders.updateValue(nil, forKey: id)
        }
        guard step.isFinished else {
            walk = step
            return
        }
        walk = nil
        let unfound = Set(folders.keys).subtracting(step.found).subtracting(wellKnown.values)
        guard step.gaveUp != true else {
            missed.formIntersection(unfound)
            return
        }
        let dropped = unfound.intersection(missed)
        folders = folders.filter { !dropped.contains($0.key) }
        nextLinks = nextLinks.filter { folders.keys.contains($0.key) }
        missed = unfound.subtracting(dropped)
    }

    /// A cursor that cannot be read cannot be continued; the engine's answer to `resetRequired` is a fresh bootstrap.
    static func decode(_ string: String) throws -> GraphCursor {
        do {
            return try JSONDecoder().decode(GraphCursor.self, from: Data(string.utf8))
        } catch {
            throw ProviderError.resetRequired
        }
    }

    func encoded() throws -> String {
        String(decoding: try GraphJSON.encode(self), as: UTF8.self)
    }
}

extension GraphCursor: Codable {
    private enum CodingKeys: String, CodingKey {
        case folders, nextLinks, wellKnown, since, foldersResolvedAt, fullVisitAt, fullVisitAfter, polledAt, walk, missed
        case recheck, folderFailures
        case folderScope, deltaScope
    }

    private struct FolderKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let nested = try container.nestedContainer(keyedBy: FolderKey.self, forKey: .folders)
        var folders: [String: String?] = [:]
        for key in nested.allKeys {
            folders.updateValue(try nested.decodeIfPresent(String.self, forKey: key), forKey: key.stringValue)
        }
        nextLinks = try container.decodeIfPresent([String: String].self, forKey: .nextLinks) ?? [:]
        if try container.decodeIfPresent(String.self, forKey: .deltaScope) != Self.mailboxScope {
            // Seeded with a receivedDateTime filter: those links would never report changes to older mail.
            folders = folders.mapValues { _ in nil }
            nextLinks = [:]
        }
        self.folders = folders
        wellKnown = try container.decodeIfPresent([String: String].self, forKey: .wellKnown) ?? [:]
        since = try container.decode(String.self, forKey: .since)
        foldersResolvedAt = try container.decodeIfPresent(String.self, forKey: .foldersResolvedAt)
        if try container.decodeIfPresent(String.self, forKey: .folderScope) != Self.treeScope {
            // Listed two levels deep: anything below went untracked, so the walk is due now, not a day after.
            foldersResolvedAt = nil
        }
        fullVisitAt = try container.decodeIfPresent(String.self, forKey: .fullVisitAt)
        fullVisitAfter = try container.decodeIfPresent(String.self, forKey: .fullVisitAfter)
        polledAt = try container.decodeIfPresent(String.self, forKey: .polledAt)
        walk = try container.decodeIfPresent(GraphFolderWalk.self, forKey: .walk)
        missed = Set(try container.decodeIfPresent([String].self, forKey: .missed) ?? [])
        recheck = try container.decodeIfPresent([String: Int].self, forKey: .recheck) ?? [:]
        folderFailures = try container.decodeIfPresent([String: Int].self, forKey: .folderFailures) ?? [:]
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        var nested = container.nestedContainer(keyedBy: FolderKey.self, forKey: .folders)
        for (id, link) in folders.sorted(by: { $0.key < $1.key }) {
            if let link {
                try nested.encode(link, forKey: FolderKey(stringValue: id))
            } else {
                try nested.encodeNil(forKey: FolderKey(stringValue: id))
            }
        }
        try container.encode(nextLinks, forKey: .nextLinks)
        try container.encode(wellKnown, forKey: .wellKnown)
        try container.encode(since, forKey: .since)
        try container.encodeIfPresent(foldersResolvedAt, forKey: .foldersResolvedAt)
        try container.encodeIfPresent(fullVisitAt, forKey: .fullVisitAt)
        try container.encodeIfPresent(fullVisitAfter, forKey: .fullVisitAfter)
        try container.encodeIfPresent(polledAt, forKey: .polledAt)
        try container.encodeIfPresent(walk, forKey: .walk)
        if !missed.isEmpty {
            try container.encode(missed.sorted(), forKey: .missed)
        }
        if !recheck.isEmpty {
            try container.encode(recheck, forKey: .recheck)
        }
        if !folderFailures.isEmpty {
            try container.encode(folderFailures, forKey: .folderFailures)
        }
        try container.encode(Self.treeScope, forKey: .folderScope)
        try container.encode(Self.mailboxScope, forKey: .deltaScope)
    }
}
