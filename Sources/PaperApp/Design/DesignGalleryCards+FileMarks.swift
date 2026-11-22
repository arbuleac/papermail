#if DEBUG
import AppKit
import PaperCore
import PaperDesign

/// The file marks (spec §5.57): every family with two of its labels, the mark's sizes and states, and the three surfaces
/// that wear it in AppKit (the reader's chip is HTML, drawn from the same tokens; its render is the reader's own).
extension DesignGalleryCards {
    /// Two files per family, the family's most common type first: the sheet of every file ink.
    static let fileMarkSamples: [(FileFamily, [String])] = [
        (.pdf, ["plan.pdf", "scan.PDF"]), (.document, ["contract.docx", "letter.pages"]), (.spreadsheet, ["Q4.xlsx", "attendees.csv"]),
        (.presentation, ["kickoff.pptx", "launch.key"]), (.archive, ["press-kit.zip", "exports.rar"]), (.image, ["hero.jpg", "IMG_2041.heic"]),
        (.video, ["walkthrough.mp4", "screen.mov"]), (.audio, ["memo.mp3", "take.wav"]), (.text, ["notes.txt", "config.json"]),
        (.mail, ["review.ics", "forwarded.eml"]), (.design, ["logo.svg", "hero.psd"]), (.other, ["readings.dat", "Makefile"]),
    ]

    static func fileMarks() -> DesignGalleryCard {
        DesignGalleryCard("File marks", code: "layout.fileMark · filePalette",
                          caption: "A sheet of paper, its corner folded down, and a band in the family's file ink carrying the "
                              + "type: scan by colour, confirm by the word. Twelve families at one luminance per mode, fixed in "
                              + "every theme; the label is white on every band.",
                          span: 12) { block in
            block.labelWidth = 110
            for row in 0..<2 {
                let samples = fileMarkSamples.map { family, names -> (NSView, String) in
                    let mark = FileMark(filename: names[row], mimeType: "")
                    return (QuireFileMarkView(QuireFileMark(mark)), row == 0 ? Quire.FileInk(rawValue: family.rawValue)?.name ?? "" : names[row])
                }
                block.captioned(row == 0 ? "Families" : "", samples, columnWidth: 92)
            }
            let sizes: [CGFloat] = [28, 40, 56]
            block.row("Sizes", sizes.map { QuireFileMarkView(QuireFileMark(ink: .spreadsheet, label: "XLS"), side: $0) }, gap: 18,
                      ann: "28 in every chip and on the file card (the grid, 1:1) · 40 · 56: the design scaled, crisp at any size")
            let failed = S.surface(.qFill, size: NSSize(width: 28, height: 28), radius: Quire.Layout.AttachmentChip.tileRadius,
                                   centring: symbol(Quire.Icon.warning, color: .qDanger))
            let dimmed = QuireFileMarkView(QuireFileMark(ink: .pdf, label: "PDF"))
            dimmed.alphaValue = Quire.Layout.AttachmentChip.draggingOpacity
            block.row("States", [QuireFileMarkView(QuireFileMark(ink: .pdf, label: "PDF")),
                                 QuireFileMarkView(QuireFileMark(ink: .other, label: "")),
                                 QuireFileMarkView(QuireFileMark(ink: .other, label: "WMWM")), failed, dimmed], gap: 18,
                      ann: "rest · no type known: the plain sheet · a wide unknown type, squeezed to the band · download failed: "
                          + "the warning tile · dragging: the chip at 0.45")
            let chips: [NSView] = [
                ComposeAttachment(filename: "brand-guidelines.pdf", mimeType: "application/pdf", sizeBytes: 906, source: .data(Data())),
                ComposeAttachment(filename: "Q4-budget.xlsx", mimeType: "", sizeBytes: 2_500, source: .data(Data()), state: .loading),
                ComposeAttachment(filename: "walkthrough.mov", mimeType: "video/quicktime", sizeBytes: 1, source: .data(Data()),
                                  state: .failed(short: "Too large", detail: "Too large for Gmail: 25 MB limit")),
            ].map { attachment in
                let chip = AttachmentChipView(attachment: attachment)
                chip.frame = NSRect(origin: .zero, size: chip.intrinsicContentSize)
                return chip
            }
            block.row("Composer chip", chips, gap: 8, caption: "the reader's chip with remove for Download (§5.22): rest · loading · failed")
            block.row("File card", [fileCard()], caption: "lifted over its chip as a drag starts (§5.17): the chip's own mark at the "
                          + "chip's size and place, so the card lands on it; the chip left behind at 0.45")
        }
    }

    private static func symbol(_ name: String, color: NSColor) -> NSView {
        FileMarkGallerySymbol(name: name, color: color)
    }

    /// The card as a drag lifts it: drawn in the page's mode over the composer's chip for the same file, dimmed.
    private static func fileCard() -> NSView {
        let info = AttachmentInfo(id: "g", filename: "launch-deck.pptx", mimeType: "", sizeBytes: 2_400_000, isInline: false)
        let content = AttachmentDragCard.content(for: info)
        let mode = QuireMode(NSApp.effectiveAppearance)
        let size = AttachmentDragCard.imageSize(for: content)
        // At 2x whatever the screen: the gallery's own snapshot is drawn at 2x.
        let image = AttachmentDragCard.image(for: content, mode: mode, scale: max(2, NSScreen.main?.backingScaleFactor ?? 2))
        let chip = AttachmentChipView(attachment: ComposeAttachment(filename: info.filename, mimeType: "", sizeBytes: info.sizeBytes,
                                                                    source: .data(Data())))
        // The card up and to the right of its chip, as the pointer has carried it a little way.
        let lift = NSSize(width: 18, height: 10)
        chip.frame = NSRect(origin: NSPoint(x: AttachmentDragCard.margin.left, y: AttachmentDragCard.margin.top + lift.height),
                            size: chip.intrinsicContentSize)
        chip.alphaValue = Quire.Layout.AttachmentChip.draggingOpacity
        let host = S.surface(.qCanvas, size: NSSize(width: size.width + lift.width, height: size.height + lift.height), radius: 8,
                             [(chip, chip.frame.origin)])
        let card = NSImageView(image: image)
        card.imageScaling = .scaleNone
        card.frame = NSRect(origin: NSPoint(x: lift.width, y: 0), size: size)
        host.addSubview(card)
        return host
    }
}
/// A symbol drawn at the chip's error-tile size, for the States row.
@MainActor
private final class FileMarkGallerySymbol: NSView {
    private let name: String
    private let color: NSColor

    init(name: String, color: NSColor) {
        self.name = name
        self.color = color
        super.init(frame: NSRect(x: 0, y: 0, width: 16, height: 16))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("built in code") }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        QuireSymbol.draw(name, size: .custom(Quire.Layout.AttachmentChip.tileGlyph), color: color, centredIn: bounds)
    }
}
#endif
