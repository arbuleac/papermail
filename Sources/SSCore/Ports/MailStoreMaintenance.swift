import Foundation

/// Housekeeping a store kept in a file can do between bursts of work (docs/ARCHITECTURE.md, "Storage bounds"). The
/// engine runs the steps at idle moments, off the main thread; the app runs `optimize` once as it closes the store.
/// Each step is its own short transaction, so a write the user makes meanwhile waits for one step at most.
public protocol MailStoreMaintenance: AnyObject, Sendable {
    /// `PRAGMA optimize`: SQLite refreshes the planner statistics that need it. Cheap; for the moment before a close.
    func optimize() throws
    /// One step of merging the full-text index into one b-tree (FTS5's optimize, done as 'merge' steps of about
    /// `pages` pages), in its own transaction. `startingOver` begins a merge of every b-tree, as the first step of an
    /// optimize; the later steps carry that merge on. Returns false once a step finds nothing left to merge. The caller
    /// loops, so it can stop between steps.
    func mergeFullTextIndex(pages: Int, startingOver: Bool) throws -> Bool
    /// Hands up to `pages` free pages back to the file system (`PRAGMA incremental_vacuum`) in one transaction and
    /// returns how many it gave back; fewer than `pages` means none are left. Nil when the file was not created for
    /// incremental vacuum: such a file keeps its size and reuses its free pages, since switching it over takes a full
    /// VACUUM.
    func reclaimFreePages(upTo pages: Int) throws -> Int?
}
