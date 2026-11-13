import AppKit
import SSCore
import os

/// The app's half of Send Later (spec §5.19, §5.23): one per main window, it observes the outbox and
///
/// - hands the waiting messages to the Drafts view (`LocalDrafts.setLaterSends`), each in place of its kept draft;
/// - once one has gone (`sent`), removes the draft it was written in, sends the provider's draft it continued to the
///   Trash, as sending it from the composer would, and then clears the row;
/// - once one has failed, keeps its draft with the reason, as a failed undo-send does, clears the row and says so;
/// - when the engine found times missed while the app was closed (`missed`), asks the user once per launch whether they
///   go now (`onMissed`).
///
/// It also turns an outbox row back into a draft for the composer: the kept draft it was written in, or, when that is
/// gone (the demo's, or a draft removed by hand), one built from the message as it would have been sent.
@MainActor
final class SendLaterOutbox {
    private static let log = Logger(subsystem: "io.supersparrow.mac", category: "send-later")

    private let client: MailClient
    private let localDrafts: LocalDrafts
    private let draftStore: ComposeDraftStore
    private var observation: StoreObservation?
    /// The missed sends already asked about this launch: an answer that is still being carried out, or a Keep in Drafts
    /// whose row has not left yet, is not asked again.
    private var asked: Set<String> = []
    /// Rows this window is clearing away, so a second observation before the delete lands does not act twice.
    private var settling: Set<String> = []

    /// Times missed while the app was closed, not yet asked about: the window asks Send Now or Keep in Drafts.
    var onMissed: (([PendingSend]) -> Void)?
    /// A Send Later message failed after its time; its draft is kept with the reason, and the window offers it.
    var onFailed: ((ComposeDraft) -> Void)?

    /// `draftStore` defaults to the shared one; tests pass their own.
    init(client: MailClient, localDrafts: LocalDrafts, draftStore: ComposeDraftStore? = nil) {
        self.client = client
        self.localDrafts = localDrafts
        self.draftStore = draftStore ?? .shared
    }

    func start() {
        guard observation == nil else { return }
        observation = client.store.observePendingSends { [weak self] sends in
            if Thread.isMainThread {
                MainActor.assumeIsolated { self?.sendsChanged(sends) }
            } else {
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.sendsChanged(sends) } }
            }
        }
    }

    func stop() {
        observation?.cancel()
        observation = nil
    }

    /// Internal so the app's tests can hand it an outbox without waiting for the observation.
    func sendsChanged(_ sends: [PendingSend]) {
        localDrafts.setLaterSends(sends)
        let present = Set(sends.map(\.id))
        settling.formIntersection(present)
        asked.formIntersection(present)
        for send in sends where send.draftID != nil && !settling.contains(send.id) {
            switch send.status {
            case .sent: settleSent(send)
            case .failed: settleFailed(send)
            case .scheduled, .later, .missed, .sending: break
            }
        }
        let missed = sends.filter { $0.status == .missed && !asked.contains($0.id) }
        if !missed.isEmpty, let onMissed {
            asked.formUnion(missed.map(\.id))
            onMissed(missed)
        }
    }

    /// Gone: the draft goes with it, and the provider's draft it continued goes to the Trash, as sending it from the
    /// composer would have done once it left (§5.19). Then the row, which the runner kept for this.
    private func settleSent(_ send: PendingSend) {
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

    /// Failed after its time: the draft is kept with the provider's reason, so it opens with the banner, and the row
    /// goes; the window's toast offers it. Nothing is retried, as for any send that may have reached the provider.
    private func settleFailed(_ send: PendingSend) {
        settling.insert(send.id)
        if var draft = draft(for: send) {
            draft.sendFailure = SendFailureWording.banner(lastError: send.lastError, provider: draft.account.kind)
            if draftStore.saveNow(draft) {
                delete(send)
                onFailed?(draft)
                return
            }
        }
        // With nowhere to keep it, the row stays failed rather than losing the message.
        Self.log.error("keeping a failed Send Later message as a draft failed")
    }

    private func delete(_ send: PendingSend) {
        do {
            try client.store.deleteSend(id: send.id)
        } catch {
            settling.remove(send.id)
            Self.log.error("clearing a Send Later row failed: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: Drafts

    /// The draft `send` was written in, as kept on this Mac; failing that, one made from the message as it would have
    /// been sent: its recipients, subject, text and attachments, its threading, and under the draft id it names (or a
    /// new one), so keeping it puts it where the kept draft would be.
    func draft(for send: PendingSend) -> ComposeDraft? {
        let accounts = localDrafts.accounts
        if let id = send.draftID, let kept = draftStore.draft(id: id, accounts: accounts) { return kept }
        let message = send.message
        guard let account = accounts.first(where: { $0.id == message.accountID }) else { return nil }
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
        return ComposeDraft(id: send.draftID ?? UUID(), mode: mode, account: account, to: message.to, cc: message.cc, bcc: message.bcc,
                            subject: message.subject, body: ComposeTextView.plainBody(message.text), attachments: attachments,
                            quoted: nil, threading: threading)
    }

    /// Takes a waiting (or missed) message back and keeps it as a draft: Cancel, Keep in Drafts, and the first step of
    /// opening one. Nil when it could not be taken back (already on its way), or there was nothing to keep it as.
    @discardableResult
    func cancel(_ send: PendingSend) -> ComposeDraft? {
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
