import Foundation

/// A walk of the folder tree spread over several calls, kept in the cursor between them. A large tree listed in one
/// call would hold that poll, and the new mail it carries, for as long as the listings take, one after another; a
/// call takes a few listing pages and leaves the rest to the next one.
///
/// `found` is every folder the walk has met, which is also what keeps it from listing a folder twice whatever shape
/// the listing takes (a duplicate, or a child that is also its own ancestor). `pending` holds the listings still to
/// send, shallowest first, so the tree is walked a level at a time; the top level is the first of them.
struct GraphFolderWalk: Codable, Equatable, Sendable {
    struct Parent: Codable, Equatable, Sendable {
        /// Empty for the top level, which has no folder of its own.
        var id: String
        /// The parent's level, the top level's folders being 1 and the top level itself 0.
        var depth: Int
        /// The next page of this listing, where a step stopped partway through it; nil before its first page.
        var nextLink: String?
        /// Calls in a row on which this listing failed; nil before the first failure and after a page succeeds.
        var failures: Int?

        static let top = Parent(id: "", depth: 0)

        var isTop: Bool { id.isEmpty }
    }

    var found: [String]
    var pending: [Parent]
    /// Set once the walk gives up on a listing that kept failing: the folders below it were not looked at, so what
    /// the walk did not find may still be there and its end drops nothing. Absent otherwise.
    var gaveUp: Bool?

    var isFinished: Bool { pending.isEmpty }
}
