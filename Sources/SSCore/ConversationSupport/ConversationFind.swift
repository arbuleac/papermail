import Foundation

/// Find in conversation (spec §5.19a): the shell's calls, what it reports back, and the words the find bar shows.
///
/// The search itself runs in the shell (`ConversationShellAssets`), which owns the documents; the app sends it the
/// query and the steps and shows what it reports. Every report carries the query it answers, so one that a newer
/// keystroke has overtaken is dropped instead of flashing a stale count.
public enum ConversationFind {
    /// The shell's report after a find, a step, a refresh from the store, or the end of a find.
    public struct Result: Hashable, Sendable {
        /// The query as typed.
        public var query: String
        public var count: Int
        /// The current match, from 0; nil while there is none.
        public var index: Int?

        public init(query: String, count: Int, index: Int?) {
            self.query = query
            self.count = max(0, count)
            self.index = index.flatMap { $0 >= 0 && $0 < max(0, count) ? $0 : nil }
        }

        /// The shell's `{kind: "find", query, count, index}` post. Bodies are untrusted: anything malformed is nil.
        public init?(body: [String: Any]) {
            guard let query = body["query"] as? String, let count = (body["count"] as? NSNumber)?.intValue, count >= 0 else {
                return nil
            }
            self.init(query: query, count: count, index: (body["index"] as? NSNumber)?.intValue)
        }

        /// The bar's count: “3 of 12”, “No matches”, or nil while the query holds nothing to find.
        public var countText: String? {
            guard ConversationFind.isSearchable(query) else { return nil }
            guard count > 0 else { return "No matches" }
            let current = (index ?? 0) + 1
            return "\(ConversationFind.grouped(current)) of \(ConversationFind.grouped(count))"
        }

        /// What VoiceOver hears as the count changes: “Match 3 of 12”, “No matches”.
        public var announcement: String? {
            guard let text = countText else { return nil }
            return count > 0 ? "Match " + text : text
        }

        public var hasMatches: Bool { count > 0 }
    }

    /// A query of white space alone finds nothing, as the shell folds it.
    public static func isSearchable(_ query: String) -> Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Finds `query` in the shown conversation, from the current match on.
    public static func findScript(_ query: String) -> String {
        "window.ss.find(" + ConversationShellAssets.jsStringLiteral(query) + ")"
    }

    /// Moves the current match by `delta` (1 next, -1 previous), wrapping at either end.
    public static func stepScript(_ delta: Int) -> String {
        "window.ss.findStep(" + String(delta < 0 ? -1 : 1) + ")"
    }

    /// Ends the find: the marks go, and what the find opened stays open.
    public static let clearScript = "window.ss.findClear()"

    static func grouped(_ value: Int) -> String {
        value.formatted(.number.grouping(.automatic))
    }
}
