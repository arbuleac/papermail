import AppKit
import SSCore

/// The drafts kept on this Mac (`ComposeDraftStore`), as the Drafts view lists them and the reader shows them
/// (spec §5.19), beside the provider's drafts that sync into the store. Records (small JSON files) are read
/// again whenever the drafts folder changes; a draft's body is read only when the reader shows it.
@MainActor
final class LocalDrafts {
    private let store: ComposeDraftStore
    private(set) var records: [ComposeDraftRecord] = []
    /// The accounts whose drafts count; a removed account's drafts never show.
    var accounts: [Account] = [] {
        didSet { if oldValue != accounts { reload() } }
    }
    /// After the kept drafts changed on disk.
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
    }

    /// The Drafts rows, newest first.
    var summaries: [ConversationSummary] {
        records.map(LocalDraftConversation.summary(for:))
    }

    /// The provider's drafts a kept draft continues: the kept one stands in for them in the Drafts view.
    var continuedDrafts: Set<MessageID> {
        Set(records.compactMap(\.continuesDraft))
    }

    func record(for id: ConversationID) -> ComposeDraftRecord? {
        guard let draftID = LocalDraftConversation.draftID(of: id) else { return nil }
        return records.first { $0.id == draftID }
    }

    /// The kept draft's one message, empty once it is gone (sent or discarded), nil for mail in the store.
    func messages(in id: ConversationID) -> [MessageMetadata]? {
        guard LocalDraftConversation.isLocal(id) else { return nil }
        guard let record = record(for: id), let account = accounts.first(where: { $0.id == record.accountID }) else { return [] }
        return [LocalDraftConversation.message(for: record, sender: EmailAddress(name: account.displayName, address: account.email))]
    }

    /// The kept draft's body as the reader renders it, read once per edit.
    func body(for id: MessageID) -> StoredBody? {
        guard let draftID = LocalDraftConversation.draftID(of: id), let record = records.first(where: { $0.id == draftID }) else { return nil }
        if let cached = bodies[draftID], cached.editedAt == record.editedAt { return cached.body }
        guard let draft = store.draft(id: draftID, accounts: accounts) else { return nil }
        let body = LocalDraftConversation.body(text: draft.body.string, quoted: draft.quoted)
        bodies[draftID] = (record.editedAt, body)
        return body
    }

    func draft(_ id: UUID) -> ComposeDraft? {
        store.draft(id: id, accounts: accounts)
    }
}
