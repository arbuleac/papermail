import Foundation

/// What a file mark says about one file (spec §5.57): its family (the band's ink), the label on the band (the type in
/// capitals, at most four characters, or nothing) and the kind the chip's meta line names (“PDF · 240 KB”). One mapping
/// for the reader's chip, the composer's chip, the file card a drag lifts and the printout's list, so a file looks the
/// same everywhere and two places can never disagree about it.
///
/// The rule: the file name's extension, else the MIME type, else nothing.
/// - The last extension decides (`report.pdf.zip` is a zip, `photo.jpg.exe` an EXE), except that a compressed tarball
///   keeps its tar (`.tar.gz` → TGZ) and a numbered part takes the extension before its number (`backup.zip.001` → ZIP).
/// - Letter case never matters; aliases share a label (`.docx` → DOC, `.jpeg` → JPG, `.htm` → HTML).
/// - An extension is 1 to 8 ASCII letters and digits with at least one letter; anything else (`Notes. Final draft`,
///   `v1.2`) is no extension at all.
/// - An extension this table does not know is labelled with itself when it fits (`.dat` → DAT) and with its first four
///   characters when it does not (`.torrent` → TORR), in the Other family, unless the MIME type knows the file.
/// - No extension and no MIME type this table knows: the Other family, no label (a plain sheet), kind “File”.
public struct FileMark: Hashable, Codable, Sendable {
    public let family: FileFamily
    /// The band's text: uppercase ASCII letters and digits, at most `maxLabel` characters; empty for a plain sheet.
    public let label: String
    /// The kind the meta line names, in today's words: “PDF”, “Word”, “Excel”, “Archive”, “JPEG”…
    public let kind: String

    /// The longest label (`layout.fileMark.labelMax`).
    public static let maxLabel = 4

    public init(family: FileFamily, label: String, kind: String) {
        self.family = family
        self.label = label
        self.kind = kind
    }

    public init(filename: String, mimeType: String) {
        let extensions = Self.extensions(of: filename)
        if let known = Self.known(extensions) {
            self = known
        } else if let byMIME = Self.byMIME[Self.essence(of: mimeType)] ?? Self.byTopLevel(Self.essence(of: mimeType)) {
            self = byMIME
        } else if let last = extensions.last {
            self.init(family: .other, label: Self.shortened(last), kind: last.uppercased())
        } else {
            self.init(family: .other, label: "", kind: "File")
        }
    }

    // MARK: Extensions

    /// The name's extensions, outermost last, each lowercased: `Q4.tar.GZ` → ["tar", "gz"]. A leading dot (a hidden
    /// file's name) is no extension, and the first piece that is not an extension ends the run.
    static func extensions(of filename: String) -> [String] {
        var pieces = filename.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        // A hidden file's leading dot starts its name, not an extension (`.bashrc`).
        if pieces.first == "" { pieces.removeFirst() }
        guard pieces.count > 1 else { return [] }
        pieces.removeFirst()
        var out: [String] = []
        for piece in pieces.reversed() {
            guard isExtension(piece) || (isPartNumber(piece) && out.isEmpty) else { break }
            out.insert(piece.lowercased(), at: 0)
        }
        // A part number alone says nothing; it only defers to the extension before it.
        if out.count == 1, isPartNumber(out[0]) { return [] }
        return out
    }

    private static func isExtension(_ piece: String) -> Bool {
        (1...8).contains(piece.count) && piece.unicodeScalars.allSatisfy { $0.isASCII && CharacterSet.alphanumerics.contains($0) }
            && piece.unicodeScalars.contains { CharacterSet.letters.contains($0) }
    }

    private static func isPartNumber(_ piece: String) -> Bool {
        (1...4).contains(piece.count) && piece.allSatisfy(\.isASCII) && piece.allSatisfy(\.isNumber)
    }

    private static func known(_ extensions: [String]) -> FileMark? {
        var run = extensions
        if let last = run.last, isPartNumber(last) { run.removeLast() }
        guard let last = run.last else { return nil }
        if run.count >= 2, run[run.count - 2] == "tar", let tarball = tarballs[last] { return tarball }
        return byExtension[last]
    }

    /// An unknown extension as a label: itself when it fits, else its first four characters.
    static func shortened(_ ext: String) -> String {
        String(ext.uppercased().prefix(maxLabel))
    }

    // MARK: MIME types

    /// `Text/Plain; charset=utf-8` → `text/plain`.
    private static func essence(of mimeType: String) -> String {
        (mimeType.split(separator: ";").first.map(String.init) ?? "").trimmingCharacters(in: .whitespaces).lowercased()
    }

    /// A MIME type the table does not list, by its top-level type: an image, a film, a sound or text, labelled with its
    /// subtype when that is a short plain word (`image/avif` → AVIF).
    private static func byTopLevel(_ essence: String) -> FileMark? {
        let parts = essence.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        let subtype = parts[1]
        let label = (1...maxLabel).contains(subtype.count) && isExtension(subtype) ? subtype.uppercased() : ""
        switch parts[0] {
        case "image": return FileMark(family: .image, label: label, kind: "Image")
        case "video": return FileMark(family: .video, label: label, kind: "Video")
        case "audio": return FileMark(family: .audio, label: label, kind: "Audio")
        case "text": return FileMark(family: .text, label: label, kind: "Text")
        default: return nil
        }
    }

    // MARK: The table

    private static func entries(_ family: FileFamily, _ label: String, _ kind: String, _ names: [String]) -> [(String, FileMark)] {
        names.map { ($0, FileMark(family: family, label: label, kind: kind)) }
    }

    /// One label per extension (the extension itself in capitals unless an alias names it).
    private static func each(_ family: FileFamily, _ kind: String?, _ names: [String]) -> [(String, FileMark)] {
        names.map { ($0, FileMark(family: family, label: shortened($0), kind: kind ?? $0.uppercased())) }
    }

    static let byExtension: [String: FileMark] = Dictionary(uniqueKeysWithValues: [
        entries(.pdf, "PDF", "PDF", ["pdf"]),
        entries(.document, "DOC", "Word", ["doc", "docx", "docm", "dot", "dotx", "dotm"]),
        entries(.document, "PAGE", "Pages", ["pages"]),
        entries(.document, "RTF", "Rich Text", ["rtf", "rtfd"]),
        entries(.document, "ODT", "OpenDocument", ["odt", "ott"]),
        entries(.spreadsheet, "XLS", "Excel", ["xls", "xlsx", "xlsm", "xlsb", "xlt", "xltx", "xltm"]),
        entries(.spreadsheet, "NUM", "Numbers", ["numbers"]),
        each(.spreadsheet, nil, ["csv", "tsv"]),
        entries(.spreadsheet, "ODS", "OpenDocument", ["ods", "ots"]),
        entries(.presentation, "PPT", "PowerPoint", ["ppt", "pptx", "pptm", "pps", "ppsx", "pot", "potx"]),
        entries(.presentation, "KEY", "Keynote", ["key", "keynote"]),
        entries(.presentation, "ODP", "OpenDocument", ["odp", "otp"]),
        each(.archive, "Archive", ["zip", "rar", "7z", "gz", "tgz", "bz2", "xz", "txz", "tar", "zst", "lz", "lzma", "cab", "sit", "sitx"]),
        entries(.archive, "GZ", "Archive", ["gzip"]),
        entries(.archive, "TBZ", "Archive", ["tbz", "tbz2"]),
        each(.archive, "Disk Image", ["dmg", "iso", "img"]),
        each(.archive, "Installer", ["pkg", "mpkg", "msi", "deb", "rpm"]),
        each(.archive, "App", ["exe", "apk", "ipa", "appx"]),
        entries(.archive, "JAR", "Java Archive", ["jar"]),
        entries(.image, "JPG", "JPEG", ["jpg", "jpeg", "jpe", "jfif"]),
        each(.image, nil, ["png", "gif", "heic", "heif", "tif", "tiff", "webp", "bmp", "avif", "ico", "jxl"]),
        each(.image, "Raw Image", ["dng", "cr2", "cr3", "nef", "arw", "raf", "orf", "rw2"]),
        entries(.video, "MOV", "QuickTime", ["mov", "qt"]),
        each(.video, "Video", ["mp4", "m4v", "avi", "mkv", "webm", "wmv", "flv", "3gp"]),
        entries(.video, "MPG", "Video", ["mpg", "mpeg"]),
        each(.audio, "Audio", ["mp3", "m4a", "aac", "wav", "flac", "ogg", "oga", "opus", "caf", "amr", "wma", "aif"]),
        entries(.audio, "AIFF", "Audio", ["aiff"]),
        entries(.audio, "MIDI", "MIDI", ["mid", "midi"]),
        each(.text, "Text", ["txt", "log", "rst"]),
        entries(.text, "MD", "Text", ["md", "markdown"]),
        entries(.text, "HTML", "HTML", ["html", "htm", "xhtml"]),
        each(.text, nil, ["json", "xml"]),
        entries(.text, "YAML", "YAML", ["yaml", "yml"]),
        each(.text, "Subtitles", ["srt", "vtt"]),
        each(.text, "Code", ["css", "js", "mjs", "ts", "tsx", "jsx", "py", "rb", "go", "rs", "java", "kt", "c", "h", "m", "mm",
                             "cpp", "hpp", "cs", "php", "sh", "zsh", "sql", "ini", "cfg", "conf", "toml", "tex"]),
        entries(.text, "PLST", "Code", ["plist"]),
        entries(.text, "IPNB", "Notebook", ["ipynb"]),
        entries(.text, "SWFT", "Code", ["swift"]),
        entries(.mail, "EML", "Message", ["eml"]),
        entries(.mail, "EMLX", "Message", ["emlx"]),
        entries(.mail, "MSG", "Outlook Message", ["msg"]),
        entries(.mail, "MBOX", "Mailbox", ["mbox"]),
        entries(.mail, "ICS", "Calendar", ["ics", "ical", "ifb"]),
        entries(.mail, "VCF", "Contact", ["vcf", "vcard"]),
        entries(.design, "PSD", "Photoshop", ["psd", "psb"]),
        entries(.design, "AI", "Illustrator", ["ai"]),
        entries(.design, "FIG", "Figma", ["fig"]),
        entries(.design, "SKT", "Sketch", ["sketch"]),
        entries(.design, "XD", "Adobe XD", ["xd"]),
        entries(.design, "INDD", "InDesign", ["indd"]),
        each(.design, nil, ["svg", "eps"]),
    ].flatMap { $0 })

    /// A compressed tarball, by the extension after `.tar`.
    static let tarballs: [String: FileMark] = [
        "gz": FileMark(family: .archive, label: "TGZ", kind: "Archive"),
        "bz2": FileMark(family: .archive, label: "TBZ", kind: "Archive"),
        "xz": FileMark(family: .archive, label: "TXZ", kind: "Archive"),
        "zst": FileMark(family: .archive, label: "TZST", kind: "Archive"),
    ]

    static let byMIME: [String: FileMark] = {
        func mark(_ ext: String) -> FileMark { byExtension[ext]! }
        return [
            "application/pdf": mark("pdf"),
            "application/msword": mark("doc"),
            "application/vnd.openxmlformats-officedocument.wordprocessingml.document": mark("docx"),
            "application/vnd.openxmlformats-officedocument.wordprocessingml.template": mark("dotx"),
            "application/rtf": mark("rtf"), "text/rtf": mark("rtf"),
            "application/vnd.apple.pages": mark("pages"),
            "application/vnd.oasis.opendocument.text": mark("odt"),
            "application/vnd.ms-excel": mark("xls"),
            "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet": mark("xlsx"),
            "application/vnd.apple.numbers": mark("numbers"),
            "text/csv": mark("csv"), "text/tab-separated-values": mark("tsv"),
            "application/vnd.oasis.opendocument.spreadsheet": mark("ods"),
            "application/vnd.ms-powerpoint": mark("ppt"),
            "application/vnd.openxmlformats-officedocument.presentationml.presentation": mark("pptx"),
            "application/vnd.apple.keynote": mark("key"),
            "application/vnd.oasis.opendocument.presentation": mark("odp"),
            "application/zip": mark("zip"), "application/x-zip-compressed": mark("zip"),
            "application/vnd.rar": mark("rar"), "application/x-rar-compressed": mark("rar"), "application/x-rar": mark("rar"),
            "application/x-7z-compressed": mark("7z"),
            "application/gzip": mark("gz"), "application/x-gzip": mark("gz"),
            "application/x-tar": mark("tar"), "application/x-bzip2": mark("bz2"), "application/x-xz": mark("xz"),
            "application/x-apple-diskimage": mark("dmg"),
            "application/vnd.android.package-archive": mark("apk"),
            "image/jpeg": mark("jpg"), "image/png": mark("png"), "image/gif": mark("gif"), "image/heic": mark("heic"),
            "image/heif": mark("heif"), "image/tiff": mark("tiff"), "image/webp": mark("webp"), "image/bmp": mark("bmp"),
            "image/svg+xml": mark("svg"), "image/vnd.adobe.photoshop": mark("psd"),
            "video/mp4": mark("mp4"), "video/quicktime": mark("mov"), "video/webm": mark("webm"), "video/mpeg": mark("mpg"),
            "video/x-msvideo": mark("avi"), "video/x-matroska": mark("mkv"),
            "audio/mpeg": mark("mp3"), "audio/mp4": mark("m4a"), "audio/x-m4a": mark("m4a"), "audio/aac": mark("aac"),
            "audio/wav": mark("wav"), "audio/x-wav": mark("wav"), "audio/vnd.wave": mark("wav"), "audio/flac": mark("flac"),
            "audio/ogg": mark("ogg"), "audio/aiff": mark("aiff"), "audio/x-aiff": mark("aiff"), "audio/midi": mark("mid"),
            "text/plain": mark("txt"), "text/markdown": mark("md"), "text/html": mark("html"),
            "application/json": mark("json"), "application/xml": mark("xml"), "text/xml": mark("xml"),
            "application/x-yaml": mark("yaml"), "text/yaml": mark("yaml"),
            "text/calendar": mark("ics"), "application/ics": mark("ics"),
            "text/vcard": mark("vcf"), "text/x-vcard": mark("vcf"), "text/directory": mark("vcf"),
            "message/rfc822": mark("eml"), "application/vnd.ms-outlook": mark("msg"),
            "application/postscript": mark("eps"), "application/illustrator": mark("ai"),
        ]
    }()
}
