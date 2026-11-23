import Foundation

/// One step of a streamed write. A provider's stream yields text in order and ends with exactly one `.finished`, or
/// throws one `AIError`.
public enum AIWriteEvent: Sendable, Hashable {
    /// More of the reply: append it.
    case text(String)
    /// The whole reply so far, replacing everything appended before. Codex delivers its message only at the end, and
    /// Claude Code's `assistant`/`result` lines repeat the full text: both are authoritative, never appended.
    case replaceAll(String)
    /// The subject a new message's write proposes with its draft, cleaned to one line (`WriteSubjectLine`). `AIWriter`
    /// makes it from the answer's first line, once, just before `.finished`, and only for a request that asked for one
    /// (`AIWriteRequest.wantsSubject`); a provider never yields it. Nothing is to be set from it unless the write then
    /// finishes: a Stop can still follow it.
    case subject(String)
    case usage(AIUsage)
    case finished(AIStop)
}
