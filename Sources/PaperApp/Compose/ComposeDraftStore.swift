import AppKit
import PaperCore
import os

/// Keeps composer drafts on this Mac (spec §5.20: drafts are local and autosaved, so closing a composer never
/// asks). One folder per draft, under its account's folder in Application Support: the `ComposeDraftRecord` as
/// JSON, the body as an archived attributed string (lists, quotes and links survive; colours are re-derived on
/// load because the Quire inks are dynamic colours an archive cannot carry), the bytes of forwarded parts, and the
/// bytes of the pictures in the body, which the archive holds only as marked characters (`ComposeInlineImages`), so
/// a draft reopened after a relaunch has its pictures where they were. Files a draft no longer refers to (a picture
/// deleted, a forwarded part removed) are removed as it is saved again.
/// Grouping by account lets removing an account take its drafts with it (`removeDrafts(for:)`).
///
/// Writes happen off the main thread except `saveNow`, which closing uses so the last edit is never lost.
/// Every write and removal posts `didChange` on the main thread once it is on disk, so the Drafts view can
/// list what is kept.
@MainActor
final class ComposeDraftStore {
    static let shared = ComposeDraftStore()

    /// Posted on the main thread after a draft was written or removed; `object` is the store.
    static let didChange = Notification.Name("ComposeDraftStore.didChange")

    private nonisolated static let logger = Logger(subsystem: AppIdentity.bundleIdentifier, category: "compose")
    private var directory: URL
    private let writer = DispatchQueue(label: "app.paperinbox.compose.drafts", qos: .utility)

    init(directory: URL = ComposeDraftStore.defaultDirectory) {
        self.directory = directory
    }

    nonisolated static var defaultDirectory: URL {
        AppIdentity.applicationSupportDirectory.appendingPathComponent("Drafts", isDirectory: true)
    }

    /// The demo's drafts, kept apart from real ones: every demo reset makes new accounts, and wiping the demo
    /// (`AppEnvironment.wipeDemoData`) must take its drafts along instead of leaving them beside the user's.
    nonisolated static var demoDirectory: URL {
        defaultDirectory.deletingLastPathComponent().appendingPathComponent("Drafts-demo", isDirectory: true)
    }

    /// Points the shared store at the demo's drafts or the real ones; the app calls it as it opens a mailbox.
    func useDemoDirectory(_ demo: Bool) {
        directory = demo ? Self.demoDirectory : Self.defaultDirectory
    }

    /// Points the store at `folder`: the app's tests keep their drafts in a temporary folder, never the user's.
    func useDirectory(_ folder: URL) {
        directory = folder
    }

    /// Runs on the writer queue after `work`, then tells observers on the main thread.
    private func write(_ work: @escaping @Sendable () -> Void, then completion: (@MainActor () -> Void)? = nil) {
        writer.async { [weak self] in
            work()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    completion?()
                    if let self { NotificationCenter.default.post(name: Self.didChange, object: self) }
                }
            }
        }
    }

    // MARK: Writing

    /// Writes the draft in the background; `completion` runs on the main actor with the outcome.
    func save(_ draft: ComposeDraft, completion: (@MainActor (Bool) -> Void)? = nil) {
        let package = Self.package(draft)
        let folder = folder(for: draft.id, account: draft.account.id)
        let stale = folders(for: draft.id).filter { $0.standardizedFileURL != folder.standardizedFileURL }
        let outcome = WriteOutcome()
        write({
            let ok = Self.write(package, to: folder)
            // A draft whose From changed moves to its new account's folder.
            if ok { stale.forEach { try? FileManager.default.removeItem(at: $0) } }
            outcome.ok = ok
        }, then: { completion?(outcome.ok) })
    }

    /// Writes the draft before returning: closing a window must not lose the last keystrokes, nor a picture pasted
    /// just before, which is waited for.
    @discardableResult
    func saveNow(_ draft: ComposeDraft) -> Bool {
        ComposeInlineImages.finishPreparing(in: draft.body)
        let package = Self.package(draft)
        let folder = folder(for: draft.id, account: draft.account.id)
        let stale = folders(for: draft.id).filter { $0.standardizedFileURL != folder.standardizedFileURL }
        let ok = writer.sync {
            let ok = Self.write(package, to: folder)
            if ok { stale.forEach { try? FileManager.default.removeItem(at: $0) } }
            return ok
        }
        NotificationCenter.default.post(name: Self.didChange, object: self)
        return ok
    }

    func remove(id: UUID) {
        let folders = folders(for: id)
        write({ folders.forEach { try? FileManager.default.removeItem(at: $0) } })
    }

    /// Removes every draft of an account (Settings › Remove takes the account's mail off this Mac).
    func removeDrafts(for accountID: AccountID) {
        let folder = directory.appendingPathComponent(accountID.rawValue, isDirectory: true)
        write({ try? FileManager.default.removeItem(at: folder) })
    }

    /// Waits for every write queued so far; for tests that read what they just saved.
    func waitForWrites() {
        writer.sync {}
    }

    // MARK: Reading

    /// Every kept draft's record for `accounts`, newest first: only the small JSON files are read, so the
    /// Drafts view can list them on every change.
    func records(accounts: [Account]) -> [ComposeDraftRecord] {
        let known = Set(accounts.map(\.id))
        return accounts.flatMap { account -> [ComposeDraftRecord] in
            let accountFolder = directory.appendingPathComponent(account.id.rawValue, isDirectory: true)
            let folders = (try? FileManager.default.contentsOfDirectory(at: accountFolder, includingPropertiesForKeys: nil)) ?? []
            return folders.compactMap(Self.record(in:)).filter { known.contains($0.accountID) }
        }
        .sorted { $0.editedAt > $1.editedAt }
    }

    /// The kept draft that continues the provider's draft `message`, if one was started from it.
    func keptDraft(continuing message: MessageID, accounts: [Account]) -> ComposeDraft? {
        guard let record = records(accounts: accounts).first(where: { $0.continuesDraft == message }) else { return nil }
        return draft(id: record.id, accounts: accounts)
    }

    /// Every kept draft of `accounts`, newest first.
    func keptDrafts(accounts: [Account]) -> [ComposeDraft] {
        accounts.flatMap { account -> [(draft: ComposeDraft, editedAt: Date)] in
            let accountFolder = directory.appendingPathComponent(account.id.rawValue, isDirectory: true)
            let folders = (try? FileManager.default.contentsOfDirectory(at: accountFolder, includingPropertiesForKeys: nil)) ?? []
            return folders.compactMap { load(folder: $0, accounts: accounts) }
        }
        .sorted { $0.editedAt > $1.editedAt }
        .map(\.draft)
    }

    /// The kept draft answering `original` in `mode`, so reopening a reply brings back what was written. Only
    /// the small JSON records are read to find it: every reply and forward asks, and the bodies and forwarded
    /// parts of the other drafts are no business of a window that is about to open.
    func keptDraft(for mode: ComposeMode, accounts: [Account]) -> ComposeDraft? {
        guard let original = mode.originalMessageID else { return nil }
        let kind = Self.kind(of: mode)
        // Under any account: the draft lives in its From account's folder, which the user may have changed.
        let folders = accounts.flatMap { account in
            (try? FileManager.default.contentsOfDirectory(at: directory.appendingPathComponent(account.id.rawValue, isDirectory: true),
                                                          includingPropertiesForKeys: nil)) ?? []
        }
        let match = folders
            .compactMap { folder in Self.record(in: folder).map { (folder: folder, record: $0) } }
            .filter { $0.record.kind == kind && $0.record.originalMessageID == original }
            .max { $0.record.editedAt < $1.record.editedAt }
        return match.flatMap { load(folder: $0.folder, accounts: accounts)?.draft }
    }

    func draft(id: UUID, accounts: [Account]) -> ComposeDraft? {
        folders(for: id).lazy.compactMap { self.load(folder: $0, accounts: accounts)?.draft }.first
    }

    /// Kept draft `id` as the reader's draft sheet shows it (spec §5.19): its body as text, each picture named as the
    /// plain-text alternative names it, and its folded original. Only the record and the archived body are read, never
    /// a picture's or a forwarded part's bytes, which `draft(id:accounts:)` reads and decodes for Continue Editing:
    /// showing a draft is opening a conversation, and stays in that budget.
    func readerBody(id: UUID) -> (text: String, quoted: QuotedReply.Rendering?)? {
        for folder in folders(for: id) {
            guard let record = Self.record(in: folder) else { continue }
            let bodyData = (try? Data(contentsOf: folder.appendingPathComponent(ComposeDraftRecord.bodyFile))) ?? Data()
            let filenames = Dictionary((record.images ?? []).map { ($0.contentID, $0.filename) }, uniquingKeysWith: { first, _ in first })
            return (ComposeInlineImages.readerText(of: Self.unarchive(bodyData), filenames: filenames), record.quoted)
        }
        return nil
    }

    /// Whether draft `id` is on disk, without reading it.
    func contains(id: UUID) -> Bool {
        !folders(for: id).isEmpty
    }

    nonisolated private static func record(in folder: URL) -> ComposeDraftRecord? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(ComposeDraftRecord.recordFile)) else { return nil }
        return try? ComposeDraftRecord.decode(data)
    }

    // MARK: Packaging

    private struct Package: Sendable {
        var record: ComposeDraftRecord
        var body: Data
        var parts: [String: Data]
    }

    private func folder(for id: UUID, account: AccountID) -> URL {
        directory.appendingPathComponent(account.rawValue, isDirectory: true).appendingPathComponent(id.uuidString, isDirectory: true)
    }

    /// Where draft `id` is stored now, under whichever account.
    private func folders(for id: UUID) -> [URL] {
        let accounts = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return accounts.map { $0.appendingPathComponent(id.uuidString, isDirectory: true) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    private static func package(_ draft: ComposeDraft) -> Package {
        var parts: [String: Data] = [:]
        let attachments: [ComposeDraftRecord.Attachment] = draft.attachments.compactMap { attachment in
            guard attachment.isSendable else { return nil }
            var stored: String?
            var url: URL?
            switch attachment.source {
            case .file(let fileURL): url = fileURL
            case .data(let data):
                let name = attachment.id.uuidString
                parts[name] = data
                stored = name
            }
            return ComposeDraftRecord.Attachment(id: attachment.id, filename: attachment.filename, mimeType: attachment.mimeType,
                                                 sizeBytes: attachment.sizeBytes, contentID: attachment.contentID,
                                                 fileURL: url, storedFile: stored)
        }
        // A picture still being prepared has no bytes yet: it goes into the save after it is in (the text view asks for
        // one), and `saveNow` waits for it.
        let images: [ComposeDraftRecord.Image] = ComposeInlineImages.readyPictures(in: draft.body).map { picture in
            let name = ComposeDraftRecord.Image.storedFile(for: picture.inlineImage.contentID)
            parts[name] = picture.data
            return ComposeDraftRecord.Image(contentID: picture.inlineImage.contentID, filename: picture.inlineImage.filename,
                                            mimeType: picture.inlineImage.mimeType, sizeBytes: picture.data.count, storedFile: name)
        }
        let record = ComposeDraftRecord(
            id: draft.id, kind: kind(of: draft.mode), originalMessageID: draft.mode.originalMessageID,
            accountID: draft.account.id, to: draft.to, cc: draft.cc, bcc: draft.bcc, subject: draft.subject,
            attachments: attachments, quoted: draft.quoted, threading: draft.threading, editedAt: Date(),
            sendFailure: draft.sendFailure, preview: ComposeDraftRecord.preview(of: draft.body.string),
            continuesDraft: draft.continuesDraft, images: images.isEmpty ? nil : images)
        return Package(record: record, body: archive(ComposeInlineImages.detached(draft.body)), parts: parts)
    }

    private nonisolated static func write(_ package: Package, to folder: URL) -> Bool {
        do {
            let fileManager = FileManager.default
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            for (name, data) in package.parts {
                let url = folder.appendingPathComponent(name)
                if !fileManager.fileExists(atPath: url.path) { try data.write(to: url, options: .atomic) }
            }
            try package.body.write(to: folder.appendingPathComponent(ComposeDraftRecord.bodyFile), options: .atomic)
            try package.record.encoded().write(to: folder.appendingPathComponent(ComposeDraftRecord.recordFile), options: .atomic)
            // Pasting and deleting pictures would otherwise leave their bytes behind until the draft is sent or discarded.
            let kept = Set(package.parts.keys).union([ComposeDraftRecord.bodyFile, ComposeDraftRecord.recordFile])
            for file in (try? fileManager.contentsOfDirectory(atPath: folder.path)) ?? [] where !kept.contains(file) {
                try? fileManager.removeItem(at: folder.appendingPathComponent(file))
            }
            return true
        } catch {
            logger.error("Saving a draft failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private func load(folder: URL, accounts: [Account]) -> (draft: ComposeDraft, editedAt: Date)? {
        guard let record = Self.record(in: folder),
              let account = accounts.first(where: { $0.id == record.accountID }) else { return nil }
        let bodyData = (try? Data(contentsOf: folder.appendingPathComponent(ComposeDraftRecord.bodyFile))) ?? Data()
        let attachments: [ComposeAttachment] = record.attachments.compactMap { item in
            let source: ComposeAttachment.Source
            if let url = item.fileURL {
                source = .file(url)
            } else if let stored = item.storedFile, let bytes = try? Data(contentsOf: folder.appendingPathComponent(stored)) {
                source = .data(bytes)
            } else {
                return nil
            }
            return ComposeAttachment(id: item.id, filename: item.filename, mimeType: item.mimeType, sizeBytes: item.sizeBytes,
                                     source: source, contentID: item.contentID)
        }
        var pictures: [String: ComposeImageAttachment] = [:]
        for item in record.images ?? [] {
            guard let bytes = try? Data(contentsOf: folder.appendingPathComponent(item.storedFile)),
                  let picture = ComposeImageAttachment.restore(data: bytes, contentID: item.contentID, filename: item.filename,
                                                               mimeType: item.mimeType) else { continue }
            pictures[item.contentID] = picture
        }
        let body = ComposeInlineImages.attached(Self.unarchive(bodyData), pictures: pictures)
        let draft = ComposeDraft(
            id: record.id, mode: Self.mode(record.kind, original: record.originalMessageID), account: account,
            to: record.to, cc: record.cc, bcc: record.bcc, subject: record.subject,
            body: body, attachments: attachments, quoted: record.quoted, threading: record.threading,
            sendFailure: record.sendFailure, continuesDraft: record.continuesDraft)
        return (draft, record.editedAt)
    }

    private static func kind(of mode: ComposeMode) -> ComposeDraftRecord.Kind {
        switch mode {
        case .new: return .new
        case .reply(_, let all): return all ? .replyAll : .reply
        case .forward: return .forward
        }
    }

    private static func mode(_ kind: ComposeDraftRecord.Kind, original: MessageID?) -> ComposeMode {
        guard let original else { return .new }
        switch kind {
        case .new: return .new
        case .reply: return .reply(original, all: false)
        case .replyAll: return .reply(original, all: true)
        case .forward: return .forward(original)
        }
    }

    // MARK: Body archive

    /// The body without colours: the inks are dynamic and come back from the text's structure on load.
    private static func archive(_ body: NSAttributedString) -> Data {
        let plain = NSMutableAttributedString(attributedString: body)
        plain.removeAttribute(.foregroundColor, range: NSRange(location: 0, length: plain.length))
        return (try? NSKeyedArchiver.archivedData(withRootObject: plain, requiringSecureCoding: true)) ?? Data()
    }

    private static func unarchive(_ data: Data) -> NSAttributedString {
        guard !data.isEmpty else { return NSAttributedString() }
        let classes: [AnyClass] = [NSAttributedString.self, NSFont.self, NSParagraphStyle.self, NSTextList.self, NSTextTab.self,
                                   NSURL.self, NSString.self, NSNumber.self, NSDictionary.self, NSArray.self, NSColor.self]
        let body = try? NSKeyedUnarchiver.unarchivedObject(ofClasses: classes, from: data) as? NSAttributedString
        return body ?? NSAttributedString()
    }
}

/// Carries a background write's result to the main-thread completion.
private final class WriteOutcome: @unchecked Sendable {
    var ok = false
}
