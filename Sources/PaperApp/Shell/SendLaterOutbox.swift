import AppKit
import PaperCore
import os

/// The app's half of Send Later (spec §5.19, §5.23): one per main window, it observes the outbox and
///
/// - hands the waiting messages to the Drafts view, each in place of its kept draft, and every send the provider has not
///   taken yet to the Outbox (`LocalDrafts.setOutbox`, spec §5.53);
/// - once one has gone (`sent`), removes the draft it was written in, sends the provider's draft it continued to the
///   Trash, as sending it from the composer would, and then clears the row;
/// - once any send has failed that no live undo-send panel or quick reply answers for (`SendOwnership`): a Send Later
///   message, an undo-send whose panel or bar has gone (its window closed, the app quit), one the app quit while handing
///   over (`SendRunner` marks it failed at the next launch), keeps its draft with the reason (`FailedSend`), clears the row
///   once that draft is on disk, so it leaves the Outbox for Drafts (§5.53), and says so once (`onFailed`); a send its
///   owner still answers for is left to it, and looked at again when the owner lets go (`SendOwnership.didRelease`);
/// - when the engine found times missed while the app was closed (`missed`), asks the user once per launch whether they
///   go now (`onMissed`).
///
/// It also turns an outbox row back into a draft for the composer: the kept draft it was written in, or, when that is
/// gone (the demo's, or a draft removed by hand), one built from the message as it would have been sent.
///
/// It reads the outbox as summaries (`PendingSendSummary`), which leave the attachments out: a Send Later message waits for
/// days, and the outbox changes with every send. The whole message is read only to make a draft of it.
@MainActor
final class SendLaterOutbox {
    private static let log = Logger(subsystem: AppIdentity.bundleIdentifier, category: "send-later")

    private let client: MailClient
    private let localDrafts: LocalDrafts
    private let draftStore: ComposeDraftStore
    private var observation: StoreObservation?
    private var releaseObserver: NSObjectProtocol?
    /// Stopped for good (`stop`): its window is going, and the draft store may already be another mailbox's (the demo's,
    /// or the user's again), where a draft kept now would be lost.
    private var isStopped = false
    /// The missed sends already asked about this launch: an answer that is still being carried out, or a Keep in Drafts
    /// whose row has not left yet, is not asked again.
    private var asked: Set<String> = []
    /// Rows this window is clearing away, so a second observation before the delete lands does not act twice.
    private var settling: Set<String> = []

    /// Times missed while the app was closed, not yet asked about: the window asks Send Now or Keep in Drafts.
    var onMissed: (([PendingSendSummary]) -> Void)?
    /// A send nobody else answered for failed; its draft is kept with the reason, its row cleared, and the window offers
    /// it, with the outbox's description of what stopped it (`PendingSendSummary.lastError`) for the words.
    var onFailed: ((ComposeDraft, _ lastError: String?) -> Void)?

    /// `draftStore` defaults to the shared one; tests pass their own.
    init(client: MailClient, localDrafts: LocalDrafts, draftStore: ComposeDraftStore? = nil) {
        self.client = client
        self.localDrafts = localDrafts
        self.draftStore = draftStore ?? .shared
    }

    func start() {
        guard observation == nil, !isStopped else { return }
        observation = client.store.observePendingSends { [weak self] sends in
            if Thread.isMainThread {
                MainActor.assumeIsolated { self?.sendsChanged(sends) }
            } else {
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.sendsChanged(sends) } }
            }
        }
        // An owner let go of a send without settling it (its panel dismissed, its reader gone, its draft not written): the
        // outbox did not change, so nothing else would bring a failed row back to this window. On the next turn of the run
        // loop, never inside the owner's own bookkeeping, which posted it.
        releaseObserver = NotificationCenter.default.addObserver(forName: SendOwnership.didRelease, object: nil, queue: nil) { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.refresh() } }
        }
    }

    func stop() {
        isStopped = true
        observation?.cancel()
        observation = nil
        if let releaseObserver { NotificationCenter.default.removeObserver(releaseObserver) }
        releaseObserver = nil
    }

    /// Reads the outbox again: the window calls it once it knows its accounts, which settling a message needs.
    func refresh() {
        guard !isStopped else { return }
        sendsChanged((try? client.store.pendingSendSummaries()) ?? [])
    }

    /// Internal so the app's tests can hand it an outbox without waiting for the observation.
    func sendsChanged(_ sends: [PendingSendSummary]) {
        guard !isStopped else { return }
        let present = Set(sends.map(\.id))
        settling.formIntersection(present)
        asked.formIntersection(present)
        // A message that went or failed is settled against its draft and account, which the window may not know yet at
        // launch; `refresh` comes back to it once it does. Before the Drafts rows change, so a failed one's draft is
        // listed with its reason at once; a sent one's draft stays out of the list (`LocalDrafts`) until it is removed.
        // A failed row this pass cleared is not listed again from this (older) word of the outbox, which a store that
        // delivers its observation at once has already followed with the newer one.
        let accounts = Set(localDrafts.accounts.map(\.id))
        for send in sends where !accounts.isEmpty && send.status == .sent && send.draftID != nil && !settling.contains(send.id) {
            settleSent(send)
        }
        var cleared: Set<String> = []
        for send in FailedSend.settledByTheApp(sends, owned: SendOwnership.isOwned, accounts: accounts) where !settling.contains(send.id) {
            if settleFailed(send) { cleared.insert(send.id) }
        }
        let listed = cleared.isEmpty ? sends : sends.filter { !cleared.contains($0.id) }
        localDrafts.setOutbox(listed)
        let missed = listed.filter { $0.status == .missed && !asked.contains($0.id) }
        if !missed.isEmpty, let onMissed {
            asked.formUnion(missed.map(\.id))
            onMissed(missed)
        }
    }

    /// Gone: the draft goes with it, and the provider's draft it continued goes to the Trash, as sending it from the
    /// composer would have done once it left (§5.19). Then the row, which the runner kept for this.
    private func settleSent(_ send: PendingSendSummary) {
        settling.insert(send.id)
        if let draftID = send.draftID {
            let continued = localDrafts.records.first { $0.id == draftID }?.continuesDraft
            draftStore.remove(id: draftID)
            if let continued {
                do {
                    try client.perform(.trash, on: [continued])
                } catch {
                    Self.log.error("discarding the continued draft failed: \(String(describing: error), privacy: .public)")
                }
            }
        }
        delete(send)
    }

    /// Failed, with nobody else to keep it: the draft is kept with the provider's reason, so it opens with the banner, and
    /// only then does the row go; the window's toast offers it, once, as the row is cleared. Nothing is retried, as for any
    /// send that may have reached the provider. Read again first: the observation's word may be older than the owner's own
    /// clearing of the row (it kept the draft and let go meanwhile), and a row gone is nothing to keep. True once the row
    /// is cleared.
    private func settleFailed(_ send: PendingSendSummary) -> Bool {
        guard let current = try? client.store.pendingSendSummaries().first(where: { $0.id == send.id }), current.status == .failed,
              !SendOwnership.isOwned(send.id) else { return false }
        settling.insert(send.id)
        if var draft = draft(for: current) {
            draft.sendFailure = SendFailureWording.banner(lastError: current.lastError, provider: draft.account.kind)
            guard draftStore.saveNow(draft) else {
                // With nowhere to keep it, the row stays failed rather than losing the message, and the next look tries again.
                settling.remove(send.id)
                Self.log.error("keeping a failed send as a draft failed")
                return false
            }
            // A row that could not be cleared is kept again, under the same id, at the next look.
            guard delete(current) else { return false }
            onFailed?(draft, current.lastError)
            return true
        }
        settling.remove(send.id)
        Self.log.error("a failed send has no message or account to keep a draft from")
        return false
    }

    @discardableResult
    private func delete(_ send: PendingSendSummary) -> Bool {
        do {
            try client.store.deleteSend(id: send.id)
            return true
        } catch {
            settling.remove(send.id)
            Self.log.error("clearing an outbox row failed: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    // MARK: Drafts

    /// The drafts Send Later messages were written in, while those messages wait or go: a reply composer must not
    /// reopen one of them as the kept draft answering its original (R again on the conversation), or the message would
    /// be both scheduled and open for sending. Opening one from its Drafts row cancels the schedule first instead.
    static func heldDraftIDs(in store: MailStoring) -> Set<UUID> {
        Set(((try? store.pendingSendSummaries()) ?? []).filter { SendLaterState($0) != nil }.compactMap(\.draftID))
    }

    /// The Send Later message waiting or going with kept draft `draftID`, if one is.
    static func send(writtenIn draftID: UUID, in store: MailStoring) -> PendingSendSummary? {
        ((try? store.pendingSendSummaries()) ?? []).first { $0.draftID == draftID && SendLaterState($0) != nil }
    }

    /// The draft `send` was written in, as kept on this Mac (or kept already for its failure); failing that, one made from
    /// the message as it would have been sent: its recipients, subject, text and attachments, its threading, and under the
    /// draft id it names (or one named by the send, `FailedSend.draftID`), so keeping it puts it where the kept draft would
    /// be, and keeping it twice rewrites one draft. Only then is the whole message read.
    func draft(for send: PendingSendSummary) -> ComposeDraft? {
        let accounts = localDrafts.accounts
        let id = FailedSend.draftID(for: send)
        if let kept = draftStore.draft(id: id, accounts: accounts) { return kept }
        guard let message = (try? client.store.pendingSend(id: send.id))?.message,
              let account = accounts.first(where: { $0.id == message.accountID }) else { return nil }
        let threading = message.inReplyTo.map {
            ReplyThreading(inReplyTo: $0, inReplyToInternetMessageID: message.inReplyToInternetMessageID, references: message.references,
                           isForward: message.isForward)
        }
        let mode: ComposeMode
        if let original = message.inReplyTo {
            mode = message.isForward ? .forward(original) : .reply(original, all: false)
        } else {
            mode = .new
        }
        let attachments = message.attachments.map {
            ComposeAttachment(id: UUID(), filename: $0.filename, mimeType: $0.mimeType, sizeBytes: $0.data.count, source: .data($0.data),
                              contentID: $0.contentID)
        }
        // The text as it would have gone holds the quoted original and the signature too, unmarked: the draft says so,
        // so Help Me Write never takes that body for the user's notes (§5.56).
        return ComposeDraft(id: id, mode: mode, account: account, to: message.to, cc: message.cc, bcc: message.bcc,
                            subject: message.subject, body: ComposeTextView.plainBody(message.text), attachments: attachments,
                            quoted: nil, threading: threading, bodyIsAsSent: true)
    }

    /// Schedules kept draft `draft` for `date` (Undo of Cancel and of Discard), built as the composer builds a message it
    /// schedules: its attachments read off the main thread, then the message made from the draft as it is now, so the
    /// outbox's copy of a cancelled message is never kept just for an Undo. `completion` gets the new send id, or nil when
    /// an attachment could not be read or the outbox refused it.
    func schedule(_ draft: ComposeDraft, at date: Date, completion: @escaping @MainActor (String?) -> Void) {
        let normalized = ComposeBodyNormalizer.normalize(draft.body)
        let pending = draft.attachments.filter(\.isSendable)
        let client = client
        Task { @MainActor in
            let parts: [OutgoingAttachment]? = await Task.detached(priority: .userInitiated) {
                try? pending.map { try $0.outgoing() }
            }.value
            guard let parts else {
                Self.log.error("scheduling a draft again failed: an attachment could not be read")
                completion(nil)
                return
            }
            let message = draft.outgoingMessage(normalizedBody: normalized, loadedAttachments: parts)
            do {
                completion(try client.scheduleSend(message, at: date, draftID: draft.id))
            } catch {
                Self.log.error("scheduling a draft again failed: \(String(describing: error), privacy: .public)")
                completion(nil)
            }
        }
    }

    /// Takes a waiting (or missed) message back and keeps it as a draft: Cancel, Keep in Drafts, and the first step of
    /// opening one. Nil when it could not be taken back (already on its way), or there was nothing to keep it as.
    @discardableResult
    func cancel(_ send: PendingSendSummary) -> ComposeDraft? {
        // Read first: the row is gone once cancelled, and with a kept draft gone too there is nothing else to build from.
        guard let draft = draft(for: send) else { return nil }
        do {
            guard try client.cancelSend(id: send.id) else { return nil }
        } catch {
            Self.log.error("cancelling a Send Later message failed: \(String(describing: error), privacy: .public)")
            return nil
        }
        // A kept draft that was there stays as it is; one built from the message is kept now, so the Drafts view lists it.
        if !draftStore.contains(id: draft.id) { draftStore.saveNow(draft) }
        return draft
    }
}
