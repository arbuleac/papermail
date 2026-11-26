import Foundation

/// How the words beside a rewritten selection came out (spec §5.56), for analytics: carried on the writer's milestone
/// as a DRAFT-form rewrite finishes, so it is known without racing the session's commit.
public enum WriteJoinOutcome: String, Sendable, CaseIterable {
    /// No seam line came.
    case none
    /// The before side's words were accepted.
    case before
    case after
    case both
    /// One or more seam lines came and none passed the checks.
    case refused
}
