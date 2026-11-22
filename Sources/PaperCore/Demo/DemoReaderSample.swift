import Foundation

/// The demo's conversation for reader mode (spec §5.59), in the personal account: one message of each kind of text
/// reader mode shows, so `--snapshot-state=reader-mode` names every source on one page.
///
/// 1. Theo writes in plain text: a text/plain message, with nothing to replace.
/// 2. Alex answers from a client that sends HTML with a real text part: reader mode shows the text part, its “>” quote
///    folded.
/// 3. Theo answers from Outlook, HTML only: reader mode shows the text taken from the HTML when it was stored, his words
///    first and the history under Outlook's From:/Sent: header folded behind the elision mark.
public enum DemoReaderSample {
    public static let subject = "Sync engine: notes from Thursday"

    static let notes = """
    Hi Alex,

    Notes from Thursday, as promised:

    - Conflicts resolve per field, the newest write wins
    - The outbox replays in order; a failed write parks, it never holds back the rest
    - Tombstones stay for 30 days

    The benchmark numbers are on the wiki: https://wiki.nakamura.test/sync-bench

    Theo
    """

    static let question = "Thanks Theo, this matches what I took away.\nOne question on tombstones: do we keep them per device or per account?\nAlex"

    static let answer = "Per account. A device that comes back after 30 days does a full resync, so it never needs them.\n"
        + "I'll write it up properly next week.\nTheo"

    /// Four days back, in the inbox but not its first row, so every other render still opens on the conversation it did.
    static let daysAgo = 4.0
}
