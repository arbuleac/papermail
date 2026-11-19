import AppKit
import os

/// The calendar file Open in Calendar hands over (spec §5.14): written to a folder of this run's own under the
/// temporary directory, then opened with Calendar, which shows the event and offers to add it. SuperSparrow never
/// reads or writes the Mac's calendars (the day column reads each account's own from its provider, spec §5.54), so it
/// needs no EventKit permission.
@MainActor
enum InvitationFiles {
    static let calendarBundleID = "com.apple.iCal"
    nonisolated private static let log = Logger(subsystem: "io.supersparrow.mac", category: "reader")

    /// How a file is handed to Calendar; tests replace it so nothing opens.
    static var opener: (URL) -> Void = { file in
        let workspace = NSWorkspace.shared
        guard let calendar = workspace.urlForApplication(withBundleIdentifier: calendarBundleID) else {
            workspace.open(file)
            return
        }
        workspace.open([file], withApplicationAt: calendar, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            // Logged by domain and code only: an error about the file names it, and its name is the subject.
            if let error = error as NSError? {
                log.error("Calendar did not open the invitation: \(error.domain, privacy: .public) \(error.code, privacy: .public)")
            }
        }
    }

    nonisolated static let folder: URL = FileManager.default.temporaryDirectory
        .appendingPathComponent("SuperSparrow-Invitations-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)

    /// Writes `text` as `<subject>.ics` (“Invitation.ics” without one); nil when the file cannot be written. Off the main
    /// thread: it waits on the disk.
    nonisolated static func write(_ text: String, named subject: String?) -> URL? {
        let base = fileName(subject)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appendingPathComponent(base).appendingPathExtension("ics")
            try Data(text.utf8).write(to: file, options: .atomic)
            return file
        } catch let error as NSError {
            log.error("Could not write the invitation file: \(error.domain, privacy: .public) \(error.code, privacy: .public)")
            return nil
        }
    }

    static func openInCalendar(_ file: URL) {
        opener(file)
    }

    /// A subject as a file name: no path separators, colons or dots at either end, single spaces, at most 80 characters.
    nonisolated static func fileName(_ subject: String?) -> String {
        let separators = CharacterSet(charactersIn: "/:\\\0").union(.whitespacesAndNewlines).union(.controlCharacters)
        let words = (subject ?? "").components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
            .filter { !$0.isEmpty }
        let short = String(words.joined(separator: " ").prefix(80)).trimmingCharacters(in: .whitespaces)
        return short.isEmpty ? "Invitation" : short
    }
}
