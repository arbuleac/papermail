import Foundation
import SSCore

/// Saves attachment files into a folder the user sees (Downloads for the chip's Download, Download all and Save to
/// Downloads; the folder Save Attachments… asks for), spec §5.17. The files come from the reader's per-session folder,
/// already quarantined (`AttachmentSafety`); a copy keeps the mark, and one that somehow lost it is marked again, so
/// nothing saved from mail ever runs without Gatekeeper asking.
@MainActor
enum AttachmentSaver {
    /// Copies `file` into `folder` under its own name, numbered like the Finder (“plan 2.pdf”) when the name is taken.
    /// Nil when it could not be written; the error is logged by domain and code only, since it names the file.
    static func copy(_ file: URL, into folder: URL) -> URL? {
        let manager = FileManager.default
        let base = file.deletingPathExtension().lastPathComponent
        let ext = file.pathExtension
        for index in 1...999 {
            let name = index == 1 ? file.lastPathComponent : base + " \(index)" + (ext.isEmpty ? "" : "." + ext)
            let destination = folder.appendingPathComponent(name)
            guard !manager.fileExists(atPath: destination.path) else { continue }
            do {
                try manager.copyItem(at: file, to: destination)
                if !AttachmentSafety.isQuarantined(destination) { try AttachmentSafety.quarantine(destination) }
                return destination
            } catch {
                logFailure(error)
                return nil
            }
        }
        return nil
    }

    /// Fetches each of `infos` in turn and copies it into `folder`: Download all and Save Attachments…. `fetch` is the
    /// reader's (the session's file, downloaded once) and reports each file's own fraction; `progress` gets the batch's
    /// one fraction, each file weighted by its listed size. `unfetched` hears of each file that could not be fetched, so
    /// its chip can say so; the rest are saved all the same.
    static func save(
        _ infos: [AttachmentInfo],
        into folder: URL,
        fetch: (AttachmentInfo, _ progress: @escaping @Sendable (Double) -> Void) async -> URL?,
        progress: @escaping @Sendable (Double) -> Void = { _ in },
        unfetched: (AttachmentInfo) -> Void = { _ in }
    ) async -> AttachmentSaveOutcome {
        let shares = AttachmentDownloadBoard.batchShares(sizes: infos.map(\.sizeBytes))
        var saved: [URL] = []
        var missing = 0
        for (index, info) in infos.enumerated() {
            let file = await fetch(info) { fraction in
                progress(AttachmentDownloadBoard.batchFraction(shares: shares, index: index, fraction: fraction))
            }
            progress(AttachmentDownloadBoard.batchFraction(shares: shares, index: index, fraction: 1))
            guard let file else {
                missing += 1
                unfetched(info)
                continue
            }
            if let copy = copy(file, into: folder) { saved.append(copy) }
        }
        return AttachmentSaveOutcome(requested: infos.count, saved: saved, unfetched: missing)
    }

    /// A Cocoa file error names the attachment and its path, which are message content: only the domain and code are
    /// public.
    static func logFailure(_ error: Error) {
        let failure = error as NSError
        ConversationSignposts.log.error("saving an attachment failed: \(failure.domain, privacy: .public) \(failure.code, privacy: .public)")
        ConversationSignposts.log.debug("saving an attachment failed: \(String(describing: error), privacy: .private)")
    }
}
