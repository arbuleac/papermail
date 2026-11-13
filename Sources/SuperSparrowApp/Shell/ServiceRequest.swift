import AppKit

/// What one of the app's Services menu items hands over (spec §5.20 Services, `NSServices` in Info.plist), read from
/// the pasteboard while the request lasts: the pasteboard is the requesting app's, and good only during the call.
enum ServiceRequest: Equatable {
    /// “New Message with Selection”: the selected text, as a new message's body.
    case selection(String)
    /// “Send with SuperSparrow”: files for a new message, attached as if dropped on it.
    case files([URL])

    /// The selected text as plain text; nil when the pasteboard holds none. Styles are left behind, as a paste into the
    /// body leaves them (`ComposeTextView` pastes plain text only).
    static func selection(from pasteboard: NSPasteboard) -> ServiceRequest? {
        guard let text = pasteboard.string(forType: .string) else { return nil }
        return .selection(body(from: text))
    }

    /// The file URLs on the pasteboard, in their order; nil when there are none. A file reference URL (Finder can
    /// write one) becomes its path, which is what the attachment reads at send.
    static func files(from pasteboard: NSPasteboard) -> ServiceRequest? {
        let objects = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) ?? []
        var urls = objects.compactMap { ($0 as? NSURL)?.filePathURL }
        if urls.isEmpty {
            // Older apps hand files over only under the legacy name, as a list of paths.
            let paths = pasteboard.propertyList(forType: legacyFilenamesType) as? [String] ?? []
            urls = paths.map { URL(fileURLWithPath: $0) }
        }
        return urls.isEmpty ? nil : .files(urls)
    }

    /// Selected text as a body: line breaks as `\n` (a CR LF or CR selection would otherwise show doubled or no breaks),
    /// without the empty lines it starts with or the white space it ends with, so the signature stays one empty line
    /// below the last line of text, as on any new message. The first line keeps its indent.
    static func body(from text: String) -> String {
        let unified = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        guard let firstVisible = unified.firstIndex(where: { !$0.isWhitespace }) else { return "" }
        let lineStart = unified[..<firstVisible].lastIndex(of: "\n").map { unified.index(after: $0) } ?? unified.startIndex
        var body = unified[lineStart...]
        while let last = body.last, last.isWhitespace { body = body.dropLast() }
        return String(body)
    }

    private static let legacyFilenamesType = NSPasteboard.PasteboardType("NSFilenamesPboardType")
}
