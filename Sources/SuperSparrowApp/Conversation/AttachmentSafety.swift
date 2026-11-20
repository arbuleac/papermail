import AppKit
import UniformTypeIdentifiers

/// Attachments are files from strangers. The app is not sandboxed, so nothing marks what it writes as downloaded
/// unless it says so itself: every attachment file carries the `com.apple.quarantine` attribute an email client
/// sets (Gatekeeper then asks before a program inside it runs, and the Finder copies the mark onto anything
/// unpacked from an archive), and a program or script is never opened without asking first.
enum AttachmentSafety {
    /// Who the quarantine record names; the Finder shows it in “downloaded by …”.
    static let agentName = "SuperSparrow"

    /// Writes `data` to `url` and quarantines it in the same step, so the file never exists unmarked for
    /// longer than the write takes. Copies made with `FileManager.copyItem` keep the attribute.
    static func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        try quarantine(url)
    }

    static func quarantine(_ url: URL) throws {
        var values = URLResourceValues()
        values.quarantineProperties = [
            kLSQuarantineTypeKey as String: kLSQuarantineTypeEmailAttachment as String,
            kLSQuarantineAgentNameKey as String: agentName,
        ]
        var marked = url
        try marked.setResourceValues(values)
    }

    /// True when the file carries a quarantine record (used by tests and before opening).
    static func isQuarantined(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.quarantinePropertiesKey])
        return values?.quarantineProperties != nil
    }

    /// The name an attachment's file is written under: the sender's name, which Quick Look and the Finder read the type
    /// from, but never a path. A slash or a colon becomes "_", control characters go, the ends are trimmed, an empty or
    /// dot name is "Attachment", and a name longer than a file system takes (255 bytes) is cut before its extension.
    static func safeFilename(_ filename: String) -> String {
        var cleaned = String(String.UnicodeScalarView(filename.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }))
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty || cleaned == "." || cleaned == ".." { return "Attachment" }
        let limit = 255
        guard cleaned.utf8.count > limit else { return cleaned }
        let ext = (cleaned as NSString).pathExtension
        let suffix = ext.isEmpty || ext.utf8.count > 32 ? "" : "." + ext
        var base = String(cleaned.dropLast(suffix.count))
        while base.utf8.count + suffix.utf8.count > limit { base.removeLast() }
        cleaned = base + suffix
        return cleaned
    }

    /// "plan.pdf", then "plan 2.pdf", "plan 3.pdf": the Finder's numbering of a copy whose name is taken.
    static func numberedName(_ filename: String, _ index: Int) -> String {
        guard index > 1 else { return filename }
        let ext = (filename as NSString).pathExtension
        let base = (filename as NSString).deletingPathExtension
        return base + " \(index)" + (ext.isEmpty ? "" : "." + ext)
    }

    /// Writes `data` as the file at `destination`, quarantined before it carries its name: the bytes go to a hidden
    /// partial file beside it, which is marked and read back, then renamed into place (the mark goes with it), so the
    /// file never exists unmarked under a name anyone would open. A name already taken gets the Finder's numbering instead
    /// of replacing what is there. Returns where the file is. A volume that keeps no extended attributes fails the write
    /// and leaves nothing behind, as a save does (`AttachmentSaver`). Safe on any thread; `mark` is for tests.
    static func deliver(_ data: Data, to destination: URL, mark: (URL) throws -> Void = AttachmentSafety.quarantine) throws -> URL {
        let manager = FileManager.default
        let folder = destination.deletingLastPathComponent()
        let partial = folder.appendingPathComponent(".\(UUID().uuidString).ss-partial")
        defer { try? manager.removeItem(at: partial) }
        try data.write(to: partial, options: [.withoutOverwriting])
        try mark(partial)
        // Read back through a URL with no cached values: a volume may take the mark and keep nothing.
        guard isQuarantined(URL(fileURLWithPath: partial.path)) else { throw CocoaError(.fileWriteUnknown) }
        for index in 1...999 {
            let target = folder.appendingPathComponent(numberedName(destination.lastPathComponent, index))
            guard !manager.fileExists(atPath: target.path) else { continue }
            do {
                try manager.moveItem(at: partial, to: target)
                return target
            } catch CocoaError.fileWriteFileExists {
                continue
            }
        }
        throw CocoaError(.fileWriteFileExists)
    }

    /// Kinds that run code when opened: applications and their bundles, executables, scripts (including
    /// `.command` and `.terminal` documents, which Terminal runs) and Java archives. Archives of documents are
    /// left out on purpose: opening one unpacks it, and the quarantine mark travels to what comes out.
    static func runsCode(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if extraProgramExtensions.contains(ext) { return true }
        guard let type = UTType(filenameExtension: ext) else { return false }
        let programs: [UTType] = [.executable, .application, .applicationBundle, .shellScript, .script, .unixExecutable]
        return programs.contains { type.conforms(to: $0) }
    }

    /// Extensions that run code, or point the Finder at something that does, but whose types do not conform to
    /// `executable` or `script` on every system.
    private static let extraProgramExtensions: Set<String> = [
        "app", "command", "tool", "terminal", "jar", "pkg", "mpkg", "workflow", "action", "scpt", "scptd", "applescript",
        "osascript", "prefpane", "saver", "kext", "dylib", "webloc", "inetloc", "fileloc", "url",
    ]
}
