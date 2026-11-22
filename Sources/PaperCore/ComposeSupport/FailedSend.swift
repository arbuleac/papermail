import CryptoKit
import Foundation

/// A send that failed leaves the Outbox for Drafts (spec §5.53). The Outbox holds mail on its way, and a failed send is
/// not: it may have reached the provider, so it is never tried again. It is kept, once, as a draft holding its reason
/// (`SendFailureWording`), and its outbox row is cleared only after that draft is on disk, so the message is never lost.
///
/// The undo-send panel or the quick reply that sent it keeps it while it still watches the send, since it holds the
/// message as the composer held it; the app keeps every other (`settledByTheApp`): one whose panel or bar has gone, one the
/// app quit while handing over, a Send Later message. Whoever keeps it keeps it under one id (`draftID`), so keeping it a
/// second time (two windows on the outbox, a quit between keeping it and clearing its row) rewrites that draft rather than
/// adding another. Pure, so the choice and the names are tested without files or windows.
public enum FailedSend {
    /// The id of the draft `send` is kept as (`draftID(sendID:writtenIn:)`).
    public static func draftID(for send: PendingSendSummary) -> UUID {
        draftID(sendID: send.id, writtenIn: send.draftID)
    }

    /// The draft a Send Later message was written in, else one named by the send: its own id, which is a UUID for every
    /// send the app queues, or one derived from it for any other, the same each time.
    public static func draftID(sendID: String, writtenIn draftID: UUID?) -> UUID {
        if let draftID { return draftID }
        if let named = UUID(uuidString: sendID) { return named }
        var bytes = Array(SHA256.hash(data: Data(("failed-send:" + sendID).utf8)).prefix(16))
        // RFC 9562's version 8 (custom) and variant bits, so it reads as a well-formed UUID.
        bytes[6] = (bytes[6] & 0x0F) | 0x80
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    /// The failed sends the app keeps itself, in the outbox's order: those no live panel or quick reply answers for
    /// (`owned`), of an account the window knows, since a draft is kept under its account. One whose account is not
    /// known yet (the window has not read its accounts at launch) waits, listed, until it is.
    public static func settledByTheApp(_ sends: [PendingSendSummary], owned: (String) -> Bool,
                                       accounts: Set<AccountID>) -> [PendingSendSummary] {
        sends.filter { $0.status == .failed && accounts.contains($0.accountID) && !owned($0.id) }
    }
}
