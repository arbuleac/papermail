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
