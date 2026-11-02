import AppKit
import SSCore
import os

/// Keeps composer drafts on this Mac (spec §5.20: drafts are local and autosaved, so closing a composer never
/// asks). One folder per draft, under its account's folder in Application Support: the `ComposeDraftRecord` as
/// JSON, the body as an archived attributed string (lists, quotes and links survive; colours are re-derived on
/// load because the Quire inks are dynamic colours an archive cannot carry), and the bytes of forwarded parts.
/// Grouping by account lets removing an account take its drafts with it (`removeDrafts(for:)`).
///
/// Writes happen off the main thread except `saveNow`, which closing uses so the last edit is never lost.
@MainActor
final class ComposeDraftStore {
    static let shared = ComposeDraftStore()

    private nonisolated static let logger = Logger(subsystem: "io.supersparrow.mac", category: "compose")
    private var directory: URL
    private let writer = DispatchQueue(label: "io.supersparrow.compose.drafts", qos: .utility)

    init(directory: URL = ComposeDraftStore.defaultDirectory) {
        self.directory = directory
    }

    nonisolated static var defaultDirectory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("SuperSparrow/Drafts", isDirectory: true)
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

    // MARK: Writing

    /// Writes the draft in the background; `completion` runs on the main actor with the outcome.
    func save(_ draft: ComposeDraft, completion: (@MainActor (Bool) -> Void)? = nil) {
        let package = Self.package(draft)
        let folder = folder(for: draft.id, account: draft.account.id)
        let stale = folders(for: draft.id).filter { $0.standardizedFileURL != folder.standardizedFileURL }
        writer.async {
            let ok = Self.write(package, to: folder)
            // A draft whose From changed moves to its new account's folder.
            if ok { stale.forEach { try? FileManager.default.removeItem(at: $0) } }
            if let completion {
                DispatchQueue.main.async { MainActor.assumeIsolated { completion(ok) } }
            }
        }
    }

    /// Writes the draft before returning: closing a window must not lose the last keystrokes.
    @discardableResult
    func saveNow(_ draft: ComposeDraft) -> Bool {
        let package = Self.package(draft)
        let folder = folder(for: draft.id, account: draft.account.id)
        let stale = folders(for: draft.id).filter { $0.standardizedFileURL != folder.standardizedFileURL }
        return writer.sync {
            let ok = Self.write(package, to: folder)
            if ok { stale.forEach { try? FileManager.default.removeItem(at: $0) } }
            return ok
        }
    }

    func remove(id: UUID) {
        let folders = folders(for: id)
        writer.async {
            folders.forEach { try? FileManager.default.removeItem(at: $0) }
        }
    }

    /// Removes every draft of an account (Settings › Remove takes the account's mail off this Mac).
    func removeDrafts(for accountID: AccountID) {
        let folder = directory.appendingPathComponent(accountID.rawValue, isDirectory: true)
        writer.async {
            try? FileManager.default.removeItem(at: folder)
        }
    }

    // MARK: Reading

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

    /// Whether draft `id` is on disk, without reading it.
    func contains(id: UUID) -> Bool {
        !folders(for: id).isEmpty
    }

    private static func record(in folder: URL) -> ComposeDraftRecord? {
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
        let record = ComposeDraftRecord(
            id: draft.id, kind: kind(of: draft.mode), originalMessageID: draft.mode.originalMessageID,
            accountID: draft.account.id, to: draft.to, cc: draft.cc, bcc: draft.bcc, subject: draft.subject,
            attachments: attachments, quoted: draft.quoted, threading: draft.threading, editedAt: Date(),
            sendFailure: draft.sendFailure)
        return Package(record: record, body: archive(draft.body), parts: parts)
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
        let draft = ComposeDraft(
            id: record.id, mode: Self.mode(record.kind, original: record.originalMessageID), account: account,
            to: record.to, cc: record.cc, bcc: record.bcc, subject: record.subject,
            body: Self.unarchive(bodyData), attachments: attachments, quoted: record.quoted, threading: record.threading,
            sendFailure: record.sendFailure)
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
