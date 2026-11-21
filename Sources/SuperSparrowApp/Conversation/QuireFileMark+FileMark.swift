import SSCore
import SSDesign

extension QuireFileMark {
    /// The mark for a file as SSCore's one mapping names it (spec §5.57): its family's ink and its label, so the composer's
    /// chip and the file card draw exactly what the reader's chip draws for the same file.
    init(_ mark: FileMark) {
        self.init(ink: Quire.FileInk(rawValue: mark.family.rawValue) ?? .other, label: mark.label)
    }

    init(filename: String, mimeType: String) {
        self.init(FileMark(filename: filename, mimeType: mimeType))
    }
}
