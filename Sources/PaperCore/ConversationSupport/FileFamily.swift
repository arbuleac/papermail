import Foundation

/// The family of file types a file mark wears (spec §5.57): it picks the band's ink, one per family, so files of one
/// kind are scanned by colour before the label confirms the type. The raw value is the family's file ink in the design
/// tokens (`filePalette`, `Quire.FileInk`) and the reader's `--q-file-<family>`, so the three never drift apart.
public enum FileFamily: String, CaseIterable, Codable, Sendable {
    case pdf
    /// Word, Pages, rich text, OpenDocument text.
    case document
    /// Excel, Numbers, CSV and TSV, OpenDocument spreadsheets.
    case spreadsheet
    /// PowerPoint, Keynote, OpenDocument presentations.
    case presentation
    /// zip, rar, 7z, gzip, bzip2, xz, tar; disk images, installers and app packages.
    case archive
    case image
    case video
    case audio
    /// Plain text, Markdown, logs and code: JSON, HTML, XML, scripts.
    case text
    /// Mail, calendar and contact files: eml, ics, vcf.
    case mail
    /// Photoshop, Illustrator, Figma, Sketch, SVG.
    case design
    /// Any other type, and a file whose type is unknown.
    case other
}
