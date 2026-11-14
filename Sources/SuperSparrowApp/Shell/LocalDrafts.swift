import AppKit
import SSCore

/// The drafts kept on this Mac (`ComposeDraftStore`), as the Drafts view lists them and the reader shows them
/// (spec §5.19), beside the provider's drafts that sync into the store. Records (small JSON files) are read
/// again whenever the drafts folder changes; a draft's body is read only when the reader shows it.
///
/// Send Later messages waiting in the outbox (`laterSends`, which `SendLaterOutbox` keeps from the outbox's observation)
/// are a row kind beside them (`SendLaterConversation`): each stands in for the kept draft it was written in, which
/// stays on disk, out of the list, until the message has gone or its schedule is cancelled.
@MainActor
final class LocalDrafts {
    private let store: ComposeDraftStore
    private(set) var records: [ComposeDraftRecord] = []
    /// The accounts whose drafts count; a removed account's drafts never show.
    var accounts: [Account] = [] {
        didSet { if oldValue != accounts { reload() } }
    }
    /// The Send Later messages the Drafts view lists (`SendLaterConversation.listed`), oldest first.
    private(set) var laterSends: [PendingSendSummary] = []
    /// The drafts of Send Later messages that went: out of the list from the moment the outbox says so (`sent`) until
    /// the draft store has removed them, which happens on its own queue, so the row never turns back into its draft.
    private var departed: Set<UUID> = []
    /// After the kept drafts changed on disk, or the Send Later messages changed.
    var onChange: (() -> Void)?
    private var bodies: [UUID: (editedAt: Date, body: StoredBody)] = [:]
    private var observer: NSObjectProtocol?

    /// `store` defaults to the shared one; tests pass their own.
    init(store: ComposeDraftStore? = nil) {
        let store = store ?? .shared
        self.store = store
        observer = NotificationCenter.default.addObserver(forName: ComposeDraftStore.didChange, object: store, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.reload()
                self.onChange?()
            }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    func reload() {
        records = accounts.isEmpty ? [] : store.records(accounts: accounts)
        let live = Set(records.map(\.id))
        bodies = bodies.filter { live.contains($0.key) }
        departed.formIntersection(live)
    }

    /// Takes the outbox's Send Later messages; tells `onChange` when what the Drafts view shows of them changed.
    func setLaterSends(_ sends: [PendingSendSummary]) {
        let listed = SendLaterConversation.listed(sends)
        let gone = departed.union(sends.filter { $0.status == .sent }.compactMap(\.draftID))
        guard listed != laterSends || gone != departed else { return }
        laterSends = listed
        departed = gone
        onChange?()
    }

    /// The Drafts rows: the kept drafts, newest first, then the Send Later messages, each in place of its kept draft.
    var summaries: [ConversationSummary] {
        let known = Set(accounts.map(\.id))
        let later = laterSends.filter { known.contains($0.accountID) }
        let hidden = departed.union(later.compactMap(\.draftID))
        return records.filter { !hidden.contains($0.id) }.map(LocalDraftConversation.summary(for:))
            + later.compactMap(SendLaterConversation.summary(for:))
    }

    /// The provider's drafts a kept draft continues: the kept one stands in for them in the Drafts view.
    var continuedDrafts: Set<MessageID> {
        Set(records.compactMap(\.continuesDraft))
    }

    func record(for id: ConversationID) -> ComposeDraftRecord? {
        guard let draftID = LocalDraftConversation.draftID(of: id) else { return nil }
        return records.first { $0.id == draftID }
    }

    /// The Send Later message behind a Drafts row, while the outbox holds it.
    func laterSend(for id: ConversationID) -> PendingSendSummary? {
        guard let sendID = SendLaterConversation.sendID(of: id) else { return nil }
        return laterSends.first { $0.id == sendID }
    }

    /// The state the draft sheet of a Send Later message shows, by its message id.
    var sendLaterStates: [MessageID: SendLaterState] {
        var states: [MessageID: SendLaterState] = [:]
        for send in laterSends {
            guard let state = SendLaterState(send) else { continue }
            states[SendLaterConversation.messageID(sendID: send.id, account: send.accountID)] = state
        }
        return states
    }

    /// The kept draft's (or Send Later message's) one message, empty once it is gone (sent, discarded), nil for mail in
    /// the store.
    func messages(in id: ConversationID) -> [MessageMetadata]? {
        guard LocalDraftConversation.isLocal(id) else { return nil }
        if SendLaterConversation.sendID(of: id) != nil {
            guard let send = laterSend(for: id), let account = accounts.first(where: { $0.id == send.accountID }) else { return [] }
            return [SendLaterConversation.message(for: send, sender: EmailAddress(name: account.displayName, address: account.email))]
        }
        guard let record = record(for: id), let account = accounts.first(where: { $0.id == record.accountID }) else { return [] }
        return [LocalDraftConversation.message(for: record, sender: EmailAddress(name: account.displayName, address: account.email))]
    }

    /// The kept draft's body as the reader renders it, read once per edit; a Send Later message's from its outbox row.
    func body(for id: MessageID) -> StoredBody? {
        if let sendID = SendLaterConversation.sendID(of: id) {
            return laterSends.first { $0.id == sendID }.map(SendLaterConversation.body(for:))
        }
        guard let draftID = LocalDraftConversation.draftID(of: id), let record = records.first(where: { $0.id == draftID }) else { return nil }
        if let cached = bodies[draftID], cached.editedAt == record.editedAt { return cached.body }
        // The record and the archived body alone: a picture shows as its plain-text placeholder, never an empty box, and
        // its bytes are neither read nor decoded on the way to the screen.
        guard let draft = store.readerBody(id: draftID) else { return nil }
        let body = LocalDraftConversation.body(text: draft.text, quoted: draft.quoted)
        bodies[draftID] = (record.editedAt, body)
        return body
    }

    func draft(_ id: UUID) -> ComposeDraft? {
        store.draft(id: id, accounts: accounts)
    }
}
