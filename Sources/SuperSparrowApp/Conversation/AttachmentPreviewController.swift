import AppKit
import QuickLookUI
import SSCore

/// Opens attachments in Quick Look. Bytes are written to a per-session temporary directory because
/// `QLPreviewPanel` previews files, not data; the directory is removed when the controller goes away.
@MainActor
final class AttachmentPreviewController: NSObject, @MainActor QLPreviewPanelDataSource, @MainActor QLPreviewPanelDelegate {
    private let client: MailClient
    private let directory: URL
    private var files: [String: URL] = [:]
    private(set) var items: [URL] = []
    private var pendingBatch: UInt64 = 0

    init(client: MailClient) {
        self.client = client
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SuperSparrow-Preview-" + UUID().uuidString, isDirectory: true)
        super.init()
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    var isPanelVisible: Bool {
        QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared()?.isVisible == true
    }

    func closePanel() {
        guard isPanelVisible else { return }
        QLPreviewPanel.shared()?.orderOut(nil)
    }

    /// Shows `attachment` and then fetches its siblings in the background so the panel's arrows work. False
    /// when the attachment itself could not be fetched, so its chip can say so (spec §5.17).
    @discardableResult
    func preview(_ attachment: AttachmentInfo, of message: MessageID, siblings: [AttachmentInfo]) async -> Bool {
        pendingBatch &+= 1
        let batch = pendingBatch
        guard let url = await file(for: attachment, of: message) else { return false }
        guard batch == pendingBatch else { return true }
        items = [url]
        presentPanel()
        for sibling in siblings where sibling.id != attachment.id && !sibling.isInline {
            guard batch == pendingBatch else { return true }
            if let siblingURL = await file(for: sibling, of: message), batch == pendingBatch {
                items.append(siblingURL)
                if isPanelVisible { QLPreviewPanel.shared()?.reloadData() }
            }
        }
        return true
    }

    private func presentPanel() {
        guard let panel = QLPreviewPanel.shared() else { return }
        // Setting the data source directly covers the case where nothing in the responder chain claims the
        // panel (focus is in the message list); the view controller re-asserts it when it does.
        panel.dataSource = self
        panel.delegate = self
        if panel.isVisible {
            panel.reloadData()
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
    }

    private func file(for attachment: AttachmentInfo, of message: MessageID) async -> URL? {
        let key = message.accountID.rawValue + "/" + message.providerID + "/" + attachment.id
        if let existing = files[key], FileManager.default.fileExists(atPath: existing.path) { return existing }
        do {
            let data = try await client.attachmentData(for: message, attachmentID: attachment.id)
            let folder = directory.appendingPathComponent(Self.folderName(for: key), isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent(Self.safeFilename(attachment.filename))
            try data.write(to: url, options: .atomic)
            files[key] = url
            return url
        } catch {
            ConversationSignposts.log.error("attachment preview failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// Keeps the original name (Quick Look picks the previewer from it) but never a path separator.
    static func safeFilename(_ filename: String) -> String {
        let cleaned = filename
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty || cleaned == "." || cleaned == ".." ? "Attachment" : cleaned
    }

    private static func folderName(for key: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in key.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }

    // MARK: QLPreviewPanelDataSource

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        items.count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        guard items.indices.contains(index) else { return nil }
        return items[index] as NSURL
    }

    // MARK: QLPreviewPanelDelegate

    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        false
    }
}
