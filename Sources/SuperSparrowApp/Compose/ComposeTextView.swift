import AppKit
import Carbon.HIToolbox
import SSCore
import SSDesign

/// The body editor. Rich text is limited to what mail reliably carries: bold, italic, underline, links,
/// bulleted and numbered lists, block quotes, and pictures pasted or dropped into the text (spec §5.20, Images in the
/// body), which are sent as `cid:` parts. Everything else the text system could do (fonts, sizes, colors, rulers,
/// editing a picture) is switched off or folded back into those few styles; text arrives plain however it is pasted.
///
/// Lists use `NSTextList` paragraph styles with the marker typed into the text, as TextEdit does, so the
/// editor shows real markers; `ComposeBodyNormalizer` strips them before export. Quotes are a paragraph
/// attribute (`ComposerBlock.attributeKey`) painted by `ComposeLayoutManager`.
///
/// The look is the reader's text styles (spec §5.20, `layout.textStyle`), so a reply reads the same before and
/// after it is sent: `writing` on the value axis (x = 84, 24 pt from the trailing edge), links in `accent`
/// underlined, quotes a 2 pt `rule` bar with a 12 pt indent in `ink2`, list markers in `ink2` 6 pt before
/// text indented 24 pt per level. Colours are dynamic tokens; they are re-derived from the structure whenever
/// the document is replaced, because archived drafts cannot carry them.
@MainActor
final class ComposeTextView: NSTextView {
    static let bodyRole = QuireFont.Role.writing
    /// The size every composer sets its body at (spec §4.15): the app's Text size. Text built for a composer outside
    /// one (a signature, a mail link's body, the quick reply's hand-off) is built at it.
    static var composerTextSize: QuireFont.TextSize { QuireEnvironment.textSize }
    static var bodyFont: NSFont { QuireFont.font(bodyRole, textSize: composerTextSize) }
    static let bulletFormat = NSTextList.MarkerFormat.disc
    static let numberFormat = NSTextList.MarkerFormat("{decimal}.")
    static let listIndent = Quire.Layout.TextStyle.listIndent
    static let markerGap = Quire.Layout.TextStyle.listMarkerGap
    static let quoteIndent = Quire.Layout.TextStyle.quoteIndent

    /// Asked to show the link popover for the selection (⌘K, the Link toggle).
    var onLinkRequest: ((ComposeTextView) -> Void)?

    /// Told when the editor takes or gives up keyboard focus (the Settings signature field draws its ring and saves
    /// from it).
    var onFocusChange: ((Bool) -> Void)?

    /// Lists and quotes. Off in the Settings signature field, which keeps to the inline styles (bold, italic,
    /// underline, links): their commands and shortcuts then do nothing, and validation reports them disabled.
    var allowsBlockFormatting = true

    /// Pictures pasted or dropped into the text (§5.20, Images in the body). Off in the Settings signature field, which
    /// is kept as the composer's HTML and has nowhere to keep a picture: there the body reads text alone, as before.
    var allowsImages = true {
        didSet {
            guard oldValue != allowsImages else { return }
            importsGraphics = allowsImages
            updateDragTypeRegistration()
        }
    }

    /// Files pasted or dropped on the text that are not all pictures, and pictures the Mac cannot read: the composer
    /// attaches them, as it does files dropped anywhere else in its window (§5.20).
    var onAttachFiles: (([URL]) -> Void)?

    /// Attachments copied from a message (the chip menu's Copy, §5.17), pasted on the text: the composer attaches them as it
    /// attaches them dropped, never from the reader's session copy, which goes when the reader does.
    var onAttachFromMail: (([AttachmentDropItem]) -> Void)?

    /// A picture prepared off the main thread is in (`ComposeImageAttachment`): the composer saves its draft again, since
    /// the save before left the picture out.
    var onPictureReady: (() -> Void)?

    /// Where the text starts and stops across the view: the composer's value axis (x = 84) and 24 pt before the
    /// trailing edge by default; the Settings signature field sets its own.
    var leadingInset: CGFloat = Quire.Layout.Composer.valueX {
        didSet { if oldValue != leadingInset { invalidateTextContainerOrigin(); updateContainerWidth() } }
    }
    var trailingInset: CGFloat = Quire.Layout.Composer.bodyPadRight {
        didSet { if oldValue != trailingInset { updateContainerWidth() } }
    }

    /// The size this editor sets its text at (spec §4.15). A composer's follows Text size live, re-setting what it holds
    /// (`followsTextSize`); the Settings signature field keeps Default, as Settings does.
    private(set) var textSize = ComposeTextView.composerTextSize

    /// Off for the Settings signature field: it stays at Default whatever Text size says.
    var followsTextSize = true {
        didSet {
            guard oldValue != followsTextSize else { return }
            setTextSize(followsTextSize ? Self.composerTextSize : .default)
        }
    }

    /// Space above the first line: `composer.bodyPadTop`, or more while the send-failed banner sits there.
    var topInset: CGFloat = Quire.Layout.Composer.bodyPadTop {
        didSet {
            guard oldValue != topInset else { return }
            invalidateTextContainerOrigin()
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }

    /// Kept alive here: in TextKit 1 the text view holds its container, the container points weakly at
    /// the layout manager, and the layout manager points weakly at the storage.
    private let ownedStorage: NSTextStorage

    override init(frame: NSRect) {
        let storage = NSTextStorage()
        let layoutManager = ComposeLayoutManager()
        // Fallback fonts (CJK, Thai, emoji) would otherwise add their leading and break the 21 pt lines.
        QuireFont.configure(layoutManager)
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: frame.width, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = false
        layoutManager.addTextContainer(container)
        ownedStorage = storage
        super.init(frame: frame, textContainer: container)
        configure()
        storage.delegate = self
        NotificationCenter.default.addObserver(self, selector: #selector(environmentDidChange(_:)),
                                               name: QuireEnvironment.didChangeNotification, object: nil)
    }

    /// Text size changed: a composer sets everything it holds again, mid-edit included (spec §4.15).
    @objc private func environmentDidChange(_ note: Notification) {
        guard followsTextSize else { return }
        setTextSize(Self.composerTextSize)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ComposeTextView is built in code")
    }

    private func configure() {
        isRichText = true
        allowsUndo = true
        usesFontPanel = false
        usesRuler = false
        usesInspectorBar = false
        importsGraphics = allowsImages
        allowsImageEditing = false
        isAutomaticLinkDetectionEnabled = true
        isAutomaticDataDetectionEnabled = false
        isContinuousSpellCheckingEnabled = true
        isGrammarCheckingEnabled = false
        font = bodyFont
        textColor = .qInk
        insertionPointColor = .qAccent
        typingAttributes = defaultTypingAttributes
        textContainerInset = .zero
        // The editor sits in a document view together with the quoted original, so Auto Layout, not the
        // text system, owns its height: it reports the laid-out text height as intrinsic size instead.
        isVerticallyResizable = false
        isHorizontallyResizable = false
        translatesAutoresizingMaskIntoConstraints = false
        minSize = .zero
        maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        // The document view paints the `sheet`; the editor stays transparent over it.
        drawsBackground = false
        // No pointing-hand cursor: a click on a link places the caret (§5.20), so the text cursor stays.
        linkTextAttributes = [
            .foregroundColor: NSColor.qAccent,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .underlineColor: NSColor.qAccent,
        ]
        updateDragTypeRegistration()
    }

    // MARK: Styles

    /// `writing`: 14 pt on exact 21 pt lines at Default, wrapping, no extra paragraph spacing (what you type is sent).
    static var bodyParagraphStyle: NSParagraphStyle { bodyParagraphStyle(at: composerTextSize) }

    static func bodyParagraphStyle(at textSize: QuireFont.TextSize) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = bodyRole.lineHeight(at: textSize)
        style.maximumLineHeight = bodyRole.lineHeight(at: textSize)
        style.lineBreakMode = .byWordWrapping
        style.baseWritingDirection = .natural
        return style
    }

    /// The instance's own styles, at its `textSize`.
    var bodyFont: NSFont { QuireFont.font(Self.bodyRole, textSize: textSize) }
    var lineHeight: CGFloat { Self.bodyRole.lineHeight(at: textSize) }
    var bodyParagraphStyle: NSParagraphStyle { Self.bodyParagraphStyle(at: textSize) }
    var defaultTypingAttributes: [NSAttributedString.Key: Any] { Self.defaultTypingAttributes(at: textSize) }
    var quoteParagraphStyle: NSParagraphStyle { Self.quoteParagraphStyle(at: textSize) }

    func listParagraphStyle(_ list: NSTextList) -> NSParagraphStyle { Self.listParagraphStyle(list, textSize: textSize) }

    func markerAttributes(_ style: NSParagraphStyle) -> [NSAttributedString.Key: Any] {
        var attributes = defaultTypingAttributes
        attributes[.paragraphStyle] = style
        attributes[.foregroundColor] = NSColor.qInk2
        return attributes
    }

    /// Text typed or pasted never carries the signature's mark, wherever the caret is (spec §5.20): the mark covers
    /// only what the composer inserted, so a From change replaces the signature and keeps what was written after it.
    /// Nor does it carry a picture's mark, which a caret just after a picture would otherwise hand on.
    override var typingAttributes: [NSAttributedString.Key: Any] {
        get {
            var attributes = super.typingAttributes
            attributes[ComposeSignature.attributeKey] = nil
            attributes[ComposerInlineImage.attributeKey] = nil
            attributes[.attachment] = nil
            return attributes
        }
        set {
            var attributes = newValue
            attributes[ComposeSignature.attributeKey] = nil
            attributes[ComposerInlineImage.attributeKey] = nil
            attributes[.attachment] = nil
            super.typingAttributes = attributes
        }
    }

    static var defaultTypingAttributes: [NSAttributedString.Key: Any] { defaultTypingAttributes(at: composerTextSize) }

    static func defaultTypingAttributes(at textSize: QuireFont.TextSize) -> [NSAttributedString.Key: Any] {
        [
            .font: QuireFont.font(bodyRole, textSize: textSize),
            .foregroundColor: NSColor.qInk,
            .paragraphStyle: bodyParagraphStyle(at: textSize),
            .baselineOffset: QuireFont.baselineOffset(bodyRole, textSize: textSize),
        ]
    }

    /// Plain text from outside the editor (the quick reply's, a mail link's body) in the writing style, as if typed:
    /// the text storage gives text without a font Helvetica 12, and nothing later restyles text already there.
    static func plainBody(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: defaultTypingAttributes)
    }

    // The typed “\t•\t” of a list item takes `markerAttributes(_:)`: `ink2`, so the marker reads as structure, not words.

    // MARK: Text size

    /// Sets everything the editor holds at `textSize` (spec §4.15). The body holds one size of text, `writing`, so
    /// every run takes the new size with its own traits (bold, italic), every paragraph the new line (indents, lists
    /// and quotes kept) and every baseline the new offset; links, underlines, inks, the signature's mark and the
    /// selection stay. Not an edit: nothing goes on the undo stack, and what an undo or a redo brings back later is
    /// set at the size then (`textStorage(_:didProcessEditing:range:changeInLength:)`).
    private func setTextSize(_ newSize: QuireFont.TextSize) {
        guard newSize != textSize else { return }
        textSize = newSize
        // Not `font =`, which would set the whole text in one face and drop its bold and italic runs.
        if let storage = textStorage { Self.setTextSize(newSize, of: storage) }
        var typing = typingAttributes
        if let typed = typing[.font] as? NSFont { typing[.font] = WritingTextSize.resized(typed, to: newSize) }
        if let style = typing[.paragraphStyle] as? NSParagraphStyle { typing[.paragraphStyle] = WritingTextSize.relined(style, to: newSize) }
        typing[.baselineOffset] = QuireFont.baselineOffset(Self.bodyRole, textSize: newSize)
        typingAttributes = typing
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    /// `storage`'s fonts, lines and baselines at `textSize`, whatever size they were set at.
    static func setTextSize(_ textSize: QuireFont.TextSize, of storage: NSTextStorage) {
        WritingTextSize.apply(textSize, to: storage)
    }

    // MARK: Geometry

    /// The text starts on the value axis and stops 24 pt before the trailing edge (padding 20 24 0 84).
    override var textContainerOrigin: NSPoint {
        let padding = textContainer?.lineFragmentPadding ?? 0
        return NSPoint(x: leadingInset - padding, y: topInset)
    }

    private func updateContainerWidth() {
        guard let textContainer else { return }
        let padding = textContainer.lineFragmentPadding
        let width = max(40, bounds.width - leadingInset - trailingInset + 2 * padding)
        if abs(textContainer.size.width - width) > 0.5 {
            textContainer.size = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        }
    }

    // MARK: Pointer

    /// The I-beam over the editor's own frame (§4.17). AppKit's lies over the visible rect, which, as views no longer
    /// clip to their bounds, is the whole page the editor sits on: it would lie over the quote's chip and attribution
    /// and the failed-send banner, and AppKit shows overlapping pointers in no order. What is laid on the editor (that
    /// banner, a popover, the cheat sheet) keeps its own, and links keep the I-beam, since a click there places the
    /// caret.
    override func resetCursorRects() {
        addTextPointerRects(cutting: overlyingSiblingAreas())
    }

    /// The frames of the views laid on the editor after it in its superview (the failed-send banner in its top inset),
    /// in its coordinates.
    private func overlyingSiblingAreas() -> [NSRect] {
        guard let superview, let index = superview.subviews.firstIndex(where: { $0 === self }) else { return [] }
        return superview.subviews[(index + 1)...].filter { !$0.isHidden }.map { convert($0.bounds, from: $0) }
    }

    // MARK: Sizing

    private var lastIntrinsicWidth: CGFloat = 0

    override var intrinsicContentSize: NSSize {
        guard let layoutManager, let textContainer else { return super.intrinsicContentSize }
        layoutManager.ensureLayout(for: textContainer)
        let used = layoutManager.usedRect(for: textContainer)
        // An empty document still has its first line, so the caret has somewhere to sit.
        let height = max(used.height, lineHeight)
        return NSSize(width: NSView.noIntrinsicMetric, height: ceil(height) + topInset)
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocusChange?(true) }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { onFocusChange?(false) }
        return resigned
    }

    override func didChangeText() {
        super.didChangeText()
        invalidateIntrinsicContentSize()
        // The text system scrolls to the caret right after this; the frame must already be tall enough.
        enclosingScrollView?.layoutSubtreeIfNeeded()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateContainerWidth()
        // Wrapping changes with the width, and so does the height the text needs.
        if abs(newSize.width - lastIntrinsicWidth) > 0.5 {
            lastIntrinsicWidth = newSize.width
            invalidateIntrinsicContentSize()
        }
    }

    /// Replaces the whole document (reopening a draft or an undone send) without leaving stale typing
    /// attributes behind, and gives it back its inks.
    func replaceContents(with content: NSAttributedString) {
        textStorage?.setAttributedString(content)
        if let storage = textStorage {
            // A draft keeps the size it was archived at, and a signature comes at the composer's: the editor's wins.
            Self.setTextSize(textSize, of: storage)
            Self.applyInks(to: storage)
        }
        typingAttributes = defaultTypingAttributes
        undoManager?.removeAllActions()
        invalidateIntrinsicContentSize()
    }

    /// Colours from structure: `ink` text, `ink2` quotes and list markers. Archived drafts lose their dynamic
    /// colours, and pasted plain text arrives without them.
    static func applyInks(to storage: NSTextStorage) {
        let whole = NSRange(location: 0, length: storage.length)
        guard whole.length > 0 else { return }
        storage.beginEditing()
        storage.addAttribute(.foregroundColor, value: NSColor.qInk, range: whole)
        storage.enumerateAttribute(ComposerBlock.attributeKey, in: whole, options: []) { value, range, _ in
            if let raw = value as? String, raw == ComposerBlock.quote.rawValue {
                storage.addAttribute(.foregroundColor, value: NSColor.qInk2, range: range)
            }
        }
        let text = storage.string as NSString
        text.enumerateSubstrings(in: whole, options: [.byParagraphs, .substringNotRequired]) { _, paragraph, _, _ in
            guard paragraph.length > 0,
                  (storage.attribute(.paragraphStyle, at: paragraph.location, effectiveRange: nil) as? NSParagraphStyle)?
                    .textLists.isEmpty == false,
                  let marker = markerRange(in: text, paragraph: paragraph) else { return }
            storage.addAttribute(.foregroundColor, value: NSColor.qInk2, range: marker)
        }
        storage.endEditing()
    }

    // MARK: Plain pasting

    /// Plain text's legacy pasteboard name: AppKit asks a Services requestor with it, as it asks every NSTextView.
    static let legacyStringType = NSPasteboard.PasteboardType("NSStringPboardType")

    /// Plain text under both of its names: `validRequestor(forSendType:returnType:)` wants the return type among these,
    /// so with `.string` alone no service that hands text back (Convert Text to Full Width, the Chinese converters) was
    /// offered in the body. Then, where pictures are allowed, the body's own copy, pictures and files; never styled
    /// text, which no paste brings.
    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        let text: [NSPasteboard.PasteboardType] = [.string, Self.legacyStringType]
        guard allowsImages else { return text }
        return [ComposeBodyPasteboard.fragmentType] + text + ComposeBodyPasteboard.imageTypes + [.fileURL]
    }

    override var acceptableDragTypes: [NSPasteboard.PasteboardType] {
        guard allowsImages else { return [.string] }
        return [ComposeBodyPasteboard.fragmentType, .string] + ComposeBodyPasteboard.imageTypes + [.fileURL]
    }

    /// Where ⌘V looks for pictures, the body's own copy and files; the app's tests hand it a private pasteboard, never
    /// the user's clipboard. Text is pasted plain from the clipboard by the text system.
    var pasteboard: NSPasteboard = .general

    override func paste(_ sender: Any?) {
        if allowsImages, let onAttachFromMail, AttachmentPasteboard.carriesReference(pasteboard) {
            onAttachFromMail(AttachmentPasteboard.dropItems(on: pasteboard))
            return
        }
        if allowsImages, readPicturesOrFiles(from: pasteboard, actionName: "Paste") { return }
        let start = selectedRange().location
        pasteAsPlainText(sender)
        // Pasted paragraphs inherit the list style of the insertion point but arrive without markers.
        repairListMarkers(in: NSRange(location: start, length: max(0, selectedRange().location - start)))
    }

    /// Services, and the drags NSTextView places itself (text, the body's own copy), read through here.
    override func readSelection(from pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        if allowsImages, readPicturesOrFiles(from: pboard, actionName: nil) { return true }
        // Only text is read the text system's way; a picture type that held no readable picture inserts nothing.
        guard type == .string || type == Self.legacyStringType else { return false }
        return super.readSelection(from: pboard, type: type)
    }

    /// Puts what `pboard` offers into the text when it is pictures or the body's own copy, or hands files to the
    /// composer to attach (§5.20, Images in the body); false when it is text, which the caller pastes plain.
    @discardableResult
    func readPicturesOrFiles(from pboard: NSPasteboard, actionName: String?) -> Bool {
        let offer = ComposeBodyPasteboard.offer(pboard)
        switch offer.content {
        case .text:
            return false
        case .files:
            onAttachFiles?(offer.fileURLs)
            return true
        case .fragment:
            guard let data = pboard.data(forType: ComposeBodyPasteboard.fragmentType),
                  let segments = ComposeBodyPasteboard.segments(from: data) else { return false }
            insertFragment(segments, actionName: actionName)
            return true
        case .image, .imageFiles:
            let read = ComposeBodyPasteboard.pictures(of: offer, from: pboard)
            if !read.pictures.isEmpty { insertPictures(read.pictures, actionName: actionName) }
            if !read.unattached.isEmpty { onAttachFiles?(read.unattached) }
            return !read.pictures.isEmpty || !read.unattached.isEmpty
        }
    }

    // MARK: Pictures

    /// Puts `pictures` in place of the selection as one undoable edit, the caret after them. A picture takes the text's
    /// attributes where it lands (a link, a list item's paragraph) but sits on the baseline, not raised with the text,
    /// and typing after it goes on in the style it interrupted.
    func insertPictures(_ pictures: [ComposeImageAttachment], actionName: String? = nil) {
        let typing = typingAttributes
        let inserted = NSMutableAttributedString()
        for picture in pictures {
            inserted.append(Self.character(for: picture, in: typing))
        }
        replaceSelection(with: inserted, actionName: actionName)
        typingAttributes = typing
        for picture in pictures where picture.isPreparing {
            picture.whenPrepared { [weak self] picture in self?.pictureDidFinish(picture) }
        }
    }

    /// Picture files chosen with Format › Insert Picture… (§5.20): at the caret, as one undoable edit, as pasting them
    /// would put them; any the Mac cannot read as a picture attach instead.
    func insertPictureFiles(_ urls: [URL]) {
        let read = ComposeBodyPasteboard.pictures(fromFiles: urls)
        if !read.pictures.isEmpty { insertPictures(read.pictures, actionName: "Insert Picture") }
        if !read.unattached.isEmpty { onAttachFiles?(read.unattached) }
    }

    /// Waits for every picture in the text still being prepared (closing saves the draft with them).
    func finishPreparingPictures() {
        if let storage = textStorage { ComposeInlineImages.finishPreparing(in: storage) }
    }

    /// A picture prepared off the main thread is ready, or could not be read after all. A ready one is drawn where its
    /// skeleton was (its size was known from the start, so nothing moves). One that could not be read comes out of the
    /// text as an edit of its own, and its file, if it had one, is attached instead, as one that never read is.
    private func pictureDidFinish(_ picture: ComposeImageAttachment) {
        guard let storage = textStorage else { return }
        var ranges: [NSRange] = []
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            if (value as? ComposeImageAttachment) === picture { ranges.append(range) }
        }
        if picture.isReady {
            for range in ranges { layoutManager?.invalidateDisplay(forCharacterRange: range) }
            onPictureReady?()
            return
        }
        guard !ranges.isEmpty else { return }
        for range in ranges.reversed() where shouldChangeText(in: range, replacementString: "") {
            storage.replaceCharacters(in: range, with: "")
            didChangeText()
        }
        if let url = picture.fileURL { onAttachFiles?([url]) }
    }

    /// The body's own copy: its text plain in the style at the caret, its pictures as parts of their own.
    private func insertFragment(_ segments: [ComposeBodyPasteboard.Segment], actionName: String?) {
        let typing = typingAttributes
        let inserted = NSMutableAttributedString()
        for segment in segments {
            switch segment {
            case .text(let text):
                inserted.append(NSAttributedString(string: text, attributes: typing))
            case .picture(let data, let filename, let mimeType):
                guard let picture = ComposeImageAttachment.restore(data: data, contentID: ComposerInlineImage.makeContentID(),
                                                                   filename: filename, mimeType: mimeType) else { continue }
                inserted.append(Self.character(for: picture, in: typing))
            }
        }
        let start = selectedRange().location
        replaceSelection(with: inserted, actionName: actionName)
        typingAttributes = typing
        repairListMarkers(in: NSRange(location: start, length: inserted.length))
    }

    /// A picture's attachment character, marked with its content id, in `attributes` less the text's raised baseline.
    static func character(for picture: ComposeImageAttachment, in attributes: [NSAttributedString.Key: Any]) -> NSAttributedString {
        var attributes = attributes
        attributes[.baselineOffset] = nil
        attributes[.attachment] = picture
        attributes[ComposerInlineImage.attributeKey] = picture.inlineImage.contentID
        return NSAttributedString(string: "\u{FFFC}", attributes: attributes)
    }

    private func replaceSelection(with inserted: NSAttributedString, actionName: String?) {
        let range = rangeForUserTextChange
        guard let storage = textStorage, range.location != NSNotFound, inserted.length > 0,
              shouldChangeText(in: range, replacementString: inserted.string) else { return }
        // Its own undo step: typing just before or after must not fold into it.
        breakUndoCoalescing()
        storage.replaceCharacters(in: range, with: inserted)
        didChangeText()
        if let actionName { undoManager?.setActionName(actionName) }
        breakUndoCoalescing()
        setSelectedRange(NSRange(location: range.location + inserted.length, length: 0))
    }

    /// The selection's ranges that lie inside the text.
    private var selectedTextRanges: [NSRange] {
        let length = textStorage?.length ?? 0
        return selectedRanges.map(\.rangeValue).filter { $0.length > 0 && NSMaxRange($0) <= length }
    }

    /// The pictures in the selection, each once.
    private var selectedPictures: [ComposeImageAttachment] {
        guard let storage = textStorage else { return [] }
        return selectedTextRanges.flatMap { ComposeInlineImages.pictures(in: storage.attributedSubstring(from: $0)) }
    }

    /// The picture when the selection is that one picture and nothing else.
    private var soleSelectedPicture: ComposeImageAttachment? {
        let ranges = selectedTextRanges
        guard ranges.count == 1, let range = ranges.first, range.length == 1 else { return nil }
        return textStorage?.attribute(.attachment, at: range.location, effectiveRange: nil) as? ComposeImageAttachment
    }

    // MARK: Copying

    private static let richTextWithAttachments: Set<NSPasteboard.PasteboardType> = [
        .rtfd, NSPasteboard.PasteboardType("NeXT RTFD pasteboard type"), NSPasteboard.PasteboardType("com.apple.flat-rtfd"),
    ]

    /// What a copy or a drag of the selection writes: the text system's own types without RTFD (a picture here is no
    /// file attachment it could carry, and text never needed it), and, when the selection holds pictures, the body's
    /// own copy first and, for one picture alone, the picture itself, for other apps.
    override var writablePasteboardTypes: [NSPasteboard.PasteboardType] {
        let types = super.writablePasteboardTypes.filter { !Self.richTextWithAttachments.contains($0) }
        guard allowsImages, !selectedPictures.isEmpty else { return types }
        var own = [ComposeBodyPasteboard.fragmentType]
        if let only = soleSelectedPicture, let format = ComposerImageFormat(mimeType: only.inlineImage.mimeType) {
            own.append(NSPasteboard.PasteboardType(format.typeIdentifier))
        }
        return own + types
    }

    override func writeSelection(to pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        guard allowsImages, let storage = textStorage else { return super.writeSelection(to: pboard, type: type) }
        if type == ComposeBodyPasteboard.fragmentType {
            let selection = NSMutableAttributedString()
            for range in selectedTextRanges { selection.append(storage.attributedSubstring(from: range)) }
            guard let data = ComposeBodyPasteboard.fragment(of: selection) else { return false }
            return pboard.setData(data, forType: type)
        }
        if let only = soleSelectedPicture, ComposerImageFormat(mimeType: only.inlineImage.mimeType)?.typeIdentifier == type.rawValue {
            // A picture still being prepared is waited for: its bytes are what is copied.
            only.finishNow()
            return only.isReady && pboard.setData(only.data, forType: type)
        }
        if type == .string || type == Self.legacyStringType, !selectedPictures.isEmpty {
            // A picture is no words: its attachment character stays out of what other apps receive as text.
            let text = selectedTextRanges.map { (storage.string as NSString).substring(with: $0) }.joined(separator: "\n")
            return pboard.setString(text.replacingOccurrences(of: "\u{FFFC}", with: ""), forType: .string)
        }
        return super.writeSelection(to: pboard, type: type)
    }

    // MARK: Dropping

    /// Files dropped on the text that are not all pictures attach, like files dropped anywhere else in the window: the
    /// composer's content view takes them and shows its outline, since this view, registered for files, keeps the drag
    /// from it.
    private var fileDropTarget: ComposeContentView? {
        sequence(first: superview, next: { $0?.superview }).lazy.compactMap { $0 as? ComposeContentView }.first
    }

    /// What the drag under way offers, read once per drag: AppKit asks again at every move of the pointer.
    private var dragOffer: (drag: String, offer: ComposeBodyPasteboard.Offer)?

    private func offer(of drag: NSDraggingInfo) -> ComposeBodyPasteboard.Offer {
        let board = drag.draggingPasteboard
        let key = "\(drag.draggingSequenceNumber) \(board.name.rawValue) \(board.changeCount)"
        if let cached = dragOffer, cached.drag == key { return cached.offer }
        let offer = ComposeBodyPasteboard.offer(board)
        dragOffer = (key, offer)
        return offer
    }

    private func attaches(_ drag: NSDraggingInfo) -> Bool {
        allowsImages && offer(of: drag).content == .files
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if attaches(sender) { return fileDropTarget?.draggingEntered(sender) ?? [] }
        return super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        if attaches(sender) { return fileDropTarget?.draggingUpdated(sender) ?? [] }
        return super.draggingUpdated(sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        if let sender, attaches(sender) { fileDropTarget?.draggingExited(sender) }
        super.draggingExited(sender)
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        if attaches(sender) { fileDropTarget?.draggingEnded(sender) }
        super.draggingEnded(sender)
        dragOffer = nil
    }

    /// Pictures go in where they are dropped; text and the body's own copy are NSTextView's to place (a drag inside the
    /// body moves); files attach.
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard allowsImages else { return super.performDragOperation(sender) }
        switch offer(of: sender).content {
        case .files:
            return fileDropTarget?.performDragOperation(sender) ?? false
        case .image, .imageFiles:
            window?.makeFirstResponder(self)
            let index = characterIndexForInsertion(at: convert(sender.draggingLocation, from: nil))
            setSelectedRange(NSRange(location: min(index, (string as NSString).length), length: 0))
            return readPicturesOrFiles(from: sender.draggingPasteboard, actionName: "Drop")
        case .fragment, .text:
            return super.performDragOperation(sender)
        }
    }

    // MARK: Key equivalents

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // The window offers the event to every view in turn, so without this the shortcuts would act on
        // the body while the user is typing in To, Cc, Bcc or Subject.
        guard window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == [.command], let key = event.charactersIgnoringModifiers?.lowercased() {
            switch key {
            case "b": toggleBold(nil); return true
            case "i": toggleItalic(nil); return true
            case "u": underline(nil); return true
            case "k": insertLink(nil); return true
            case "'" where allowsBlockFormatting: toggleBlockQuote(nil); return true
            default: break
            }
        }
        if flags == [.command, .shift], allowsBlockFormatting {
            switch Int(event.keyCode) {
            case kVK_ANSI_8: toggleBulletList(nil); return true
            case kVK_ANSI_7: toggleNumberedList(nil); return true
            case kVK_ANSI_9: toggleBlockQuote(nil); return true
            default: break
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    // MARK: Format state

    /// Which format toggles are on: a style counts when it applies at the caret or across the whole
    /// selection; a mixed selection shows it off (spec §5.20, Format row).
    struct FormatState: Equatable {
        var bold = false
        var italic = false
        var underline = false
        var bulletList = false
        var numberedList = false
        var quote = false
        var link = false
    }

    var formatState: FormatState {
        var state = FormatState()
        let manager = NSFontManager.shared
        let range = selectedRange()
        if range.length == 0 {
            let font = (typingAttributes[.font] as? NSFont) ?? bodyFont
            state.bold = manager.traits(of: font).contains(.boldFontMask)
            state.italic = manager.traits(of: font).contains(.italicFontMask)
            state.underline = ((typingAttributes[.underlineStyle] as? Int) ?? 0) != 0
        } else if let storage = textStorage {
            var bold = true, italic = true, underline = true
            storage.enumerateAttributes(in: range, options: []) { attributes, _, _ in
                let font = (attributes[.font] as? NSFont) ?? bodyFont
                let traits = manager.traits(of: font)
                if !traits.contains(.boldFontMask) { bold = false }
                if !traits.contains(.italicFontMask) { italic = false }
                if ((attributes[.underlineStyle] as? Int) ?? 0) == 0 { underline = false }
            }
            state.bold = bold
            state.italic = italic
            state.underline = underline
        }
        let paragraphs = selectedParagraphs()
        state.bulletList = !paragraphs.isEmpty && paragraphs.allSatisfy { $0.list?.markerFormat == Self.bulletFormat }
        state.numberedList = !paragraphs.isEmpty && paragraphs.allSatisfy { $0.list?.markerFormat == Self.numberFormat }
        state.quote = !paragraphs.isEmpty && paragraphs.allSatisfy { $0.block == .quote }
        state.link = existingLink(at: range) != nil
        return state
    }

    // MARK: Character styles

    @objc func toggleBold(_ sender: Any?) {
        toggleTrait(.boldFontMask)
    }

    @objc func toggleItalic(_ sender: Any?) {
        toggleTrait(.italicFontMask)
    }

    /// Format › Underline. A selector of its own rather than NSText's `underline:`, which a field editor would
    /// answer and underline the Subject with.
    @objc func toggleUnderline(_ sender: Any?) {
        underline(sender)
    }

    /// The Font menu and panel may only change bold and italic; family and size stay the composer's.
    override func changeFont(_ sender: Any?) {
        let manager = NSFontManager.shared
        transformFonts { font in
            let traits = manager.traits(of: manager.convert(font)).intersection([.boldFontMask, .italicFontMask])
            return self.font(withTraits: traits)
        }
    }

    override func changeColor(_ sender: Any?) {}

    override func changeAttributes(_ sender: Any?) {}

    private func toggleTrait(_ trait: NSFontTraitMask) {
        let manager = NSFontManager.shared
        let range = selectedRange()
        var everyRunHasTrait = true
        if range.length == 0 {
            let font = (typingAttributes[.font] as? NSFont) ?? bodyFont
            everyRunHasTrait = manager.traits(of: font).contains(trait)
        } else if let storage = textStorage {
            storage.enumerateAttribute(.font, in: range, options: []) { value, _, stop in
                let font = (value as? NSFont) ?? bodyFont
                if !manager.traits(of: font).contains(trait) {
                    everyRunHasTrait = false
                    stop.pointee = true
                }
            }
        }
        // Mixed selections become styled, uniform ones lose the style, the way Mail behaves.
        transformFonts { font in
            everyRunHasTrait ? manager.convert(font, toNotHaveTrait: trait) : manager.convert(font, toHaveTrait: trait)
        }
    }

    private func transformFonts(_ transform: (NSFont) -> NSFont) {
        let range = selectedRange()
        var typing = typingAttributes
        typing[.font] = transform((typing[.font] as? NSFont) ?? bodyFont)
        guard range.length > 0, let storage = textStorage else {
            typingAttributes = typing
            return
        }
        guard shouldChangeText(in: range, replacementString: nil) else { return }
        storage.beginEditing()
        storage.enumerateAttribute(.font, in: range, options: []) { value, subrange, _ in
            let font = (value as? NSFont) ?? bodyFont
            storage.addAttribute(.font, value: transform(font), range: subrange)
        }
        storage.endEditing()
        didChangeText()
        typingAttributes = typing
    }

    private func font(withTraits traits: NSFontTraitMask) -> NSFont {
        let manager = NSFontManager.shared
        var font = bodyFont
        if traits.contains(.boldFontMask) { font = manager.convert(font, toHaveTrait: .boldFontMask) }
        if traits.contains(.italicFontMask) { font = manager.convert(font, toHaveTrait: .italicFontMask) }
        return font
    }

    // MARK: Links

    /// ⌘K and the Link toggle open the composer's link popover (§5.20), anchored to the selection.
    @objc func insertLink(_ sender: Any?) {
        onLinkRequest?(self)
    }

    /// The link under the selection (or the caret), with its whole range, for editing it.
    func existingLink(at range: NSRange) -> (target: String, range: NSRange)? {
        guard let storage = textStorage, storage.length > 0 else { return nil }
        let probe = range.length > 0 ? range.location : max(0, min(range.location, storage.length - 1))
        var effective = NSRange(location: 0, length: 0)
        guard let value = storage.attribute(.link, at: probe, longestEffectiveRange: &effective, in: NSRange(location: 0, length: storage.length)) else {
            return nil
        }
        // A caret just past a link's end is not on it.
        if range.length == 0, range.location != probe, range.location >= NSMaxRange(effective) { return nil }
        if let url = value as? URL { return (url.absoluteString, effective) }
        if let string = value as? String { return (string, effective) }
        return nil
    }

    /// Links `range` to `target` (an already normalized address), or inserts `text` (the target when empty)
    /// as a new link at a caret. Undoable as one change.
    func applyLink(_ target: String, text: String?, to range: NSRange) {
        // The range was taken when the popover opened; text that has since grown shorter than it has nothing there to link.
        guard let storage = textStorage, NSMaxRange(range) <= storage.length else { return }
        if range.length == 0 {
            let label = (text?.isEmpty == false ? text! : target)
            var attributes = typingAttributes
            attributes[.link] = target
            let inserted = NSAttributedString(string: label, attributes: attributes)
            guard shouldChangeText(in: range, replacementString: label) else { return }
            storage.replaceCharacters(in: range, with: inserted)
            didChangeText()
            setSelectedRange(NSRange(location: range.location + inserted.length, length: 0))
        } else {
            guard shouldChangeText(in: range, replacementString: nil) else { return }
            storage.addAttribute(.link, value: target, range: range)
            didChangeText()
        }
        // Typing after a link should not extend it.
        var typing = typingAttributes
        typing[.link] = nil
        typingAttributes = typing
    }

    func removeLink(in range: NSRange) {
        guard let storage = textStorage, range.length > 0, NSMaxRange(range) <= storage.length,
              shouldChangeText(in: range, replacementString: nil) else { return }
        storage.removeAttribute(.link, range: range)
        didChangeText()
    }

    /// Opens the link popover (§5.20) for the selection in `host`, a flipped view over the editor: on the link under
    /// the caret to edit it, else to add one. Confirming links the text, Remove Link unlinks it, and focus comes back
    /// to the editor when the popover closes from inside. `onClose` follows that, whichever way it closes.
    @discardableResult
    func presentLinkPopover(in host: NSView, onClose: @escaping () -> Void) -> ComposeLinkPopover? {
        let selection = selectedRange()
        let existing = existingLink(at: selection)
        let range = existing?.range ?? selection
        let request = ComposeLinkPopover.Request(range: range, existingTarget: existing?.target, needsText: range.length == 0)
        let popover = ComposeLinkPopover(request: request)
        guard let anchor = anchorRects(for: range) else { return nil }
        let first = host.convert(anchor.first, from: self)
        let last = host.convert(anchor.last, from: self)
        let startX = host.convert(NSPoint(x: anchor.startX, y: anchor.first.minY), from: self).x
        let c = Quire.Layout.Composer.self
        let frame = ComposePopoverPlacement.linkPopover(firstLine: first, lastLine: last, selectionStartX: startX,
                                                        size: popover.preferredSize, bounds: host.bounds, pad: c.linkPopoverPad,
                                                        offsetY: c.linkPopoverOffsetY, edgeMin: c.popoverEdgeMin)
        popover.onConfirm = { [weak self] target, text in
            self?.applyLink(target, text: text, to: range)
        }
        popover.onRemove = { [weak self] in self?.removeLink(in: range) }
        popover.onClose = { [weak self, weak popover] in
            // Confirmed or cancelled from inside: the caret goes back to the text. Focus that already moved
            // elsewhere (a click in a field) stays where it went.
            if let self, let popover, let responder = self.window?.firstResponder as? NSView, responder.isDescendant(of: popover) {
                self.window?.makeFirstResponder(self)
            }
            onClose()
        }
        popover.present(in: host, frame: frame)
        return popover
    }

    /// The rects of the first and last lines of `range` and the x where it starts, in this view's coordinates,
    /// for anchoring the link popover.
    func anchorRects(for range: NSRange) -> (first: NSRect, last: NSRect, startX: CGFloat)? {
        guard let layoutManager, let textContainer else { return nil }
        layoutManager.ensureLayout(for: textContainer)
        let origin = textContainerOrigin
        let length = (string as NSString).length
        let safe = NSRange(location: min(range.location, length), length: min(range.length, max(0, length - range.location)))
        var rects: [NSRect] = []
        if safe.length == 0 {
            let caret = firstRect(forCharacterRange: safe, actualRange: nil)
            if let window, caret != .zero {
                let local = convert(window.convertFromScreen(caret), from: nil)
                rects = [NSRect(x: local.minX, y: local.minY, width: 1, height: local.height)]
            }
        } else {
            let glyphs = layoutManager.glyphRange(forCharacterRange: safe, actualCharacterRange: nil)
            layoutManager.enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: glyphs, in: textContainer) { rect, _ in
                rects.append(rect.offsetBy(dx: origin.x, dy: origin.y))
            }
        }
        guard let first = rects.first, let last = rects.last else {
            let line = NSRect(x: Quire.Layout.Composer.valueX, y: topInset, width: 1, height: lineHeight)
            return (line, line, line.minX)
        }
        return (first, last, first.minX)
    }

    // MARK: Paragraph structure

    struct ParagraphInfo {
        /// Including the trailing newline.
        var range: NSRange
        /// Excluding the trailing newline.
        var contentRange: NSRange
        var list: NSTextList?
        var block: ComposerBlock
        /// The typed "\t•\t" prefix of a list item.
        var markerRange: NSRange?

        var isEmptyItem: Bool {
            let start = markerRange.map(NSMaxRange) ?? contentRange.location
            return NSMaxRange(contentRange) - start <= 0
        }
    }

    func paragraphInfo(at location: Int) -> ParagraphInfo {
        let text = string as NSString
        let safe = max(0, min(location, text.length))
        let range = text.paragraphRange(for: NSRange(location: safe, length: 0))
        var content = range
        if range.length > 0, Self.isNewline(text.character(at: NSMaxRange(range) - 1)) {
            content.length -= 1
        }
        let attributes: [NSAttributedString.Key: Any]
        if range.length > 0, let storage = textStorage {
            attributes = storage.attributes(at: range.location, effectiveRange: nil)
        } else {
            attributes = typingAttributes
        }
        let style = attributes[.paragraphStyle] as? NSParagraphStyle
        let list = style?.textLists.last
        return ParagraphInfo(
            range: range,
            contentRange: content,
            list: list,
            block: ComposerBlock.from(attributes: attributes),
            markerRange: list == nil ? nil : Self.markerRange(in: text, paragraph: content)
        )
    }

    /// The "\t<marker>\t" prefix of a list paragraph, when present.
    static func markerRange(in text: NSString, paragraph: NSRange) -> NSRange? {
        guard paragraph.length >= 2, text.character(at: paragraph.location) == 0x09 else { return nil }
        var index = paragraph.location + 1
        while index < NSMaxRange(paragraph) {
            let character = text.character(at: index)
            if character == 0x09 { return NSRange(location: paragraph.location, length: index - paragraph.location + 1) }
            if isNewline(character) { return nil }
            index += 1
        }
        return nil
    }

    static func isNewline(_ character: unichar) -> Bool {
        character == 0x0A || character == 0x0D || character == 0x2029
    }

    private func selectedParagraphs() -> [ParagraphInfo] {
        let text = string as NSString
        let whole = text.paragraphRange(for: selectedRange())
        var result: [ParagraphInfo] = []
        var location = whole.location
        while true {
            let info = paragraphInfo(at: location)
            result.append(info)
            let next = NSMaxRange(info.range)
            if next >= NSMaxRange(whole) || next <= location { break }
            location = next
        }
        return result
    }

    /// A list item: text 24 pt in, the marker right-aligned 6 pt before it (`textStyle.listIndent`, `listMarkerGap`).
    static func listParagraphStyle(_ list: NSTextList, textSize: QuireFont.TextSize) -> NSParagraphStyle {
        let style = bodyParagraphStyle(at: textSize).mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
        style.textLists = [list]
        style.headIndent = listIndent
        style.firstLineHeadIndent = 0
        style.tabStops = [
            NSTextTab(textAlignment: .right, location: listIndent - markerGap, options: [:]),
            NSTextTab(textAlignment: .left, location: listIndent, options: [:]),
        ]
        style.defaultTabInterval = listIndent
        return style
    }

    /// A quote: 12 pt in, behind the 2 pt bar `ComposeLayoutManager` paints (`textStyle.quoteIndent`, `quoteBar`).
    static func quoteParagraphStyle(at textSize: QuireFont.TextSize) -> NSParagraphStyle {
        let style = bodyParagraphStyle(at: textSize).mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
        style.headIndent = quoteIndent
        style.firstLineHeadIndent = quoteIndent
        return style
    }

    // MARK: Lists

    @objc func toggleBulletList(_ sender: Any?) {
        guard allowsBlockFormatting else { return }
        toggleList(format: Self.bulletFormat)
    }

    @objc func toggleNumberedList(_ sender: Any?) {
        guard allowsBlockFormatting else { return }
        toggleList(format: Self.numberFormat)
    }

    private static let blockCommands: Set<Selector> = [
        #selector(toggleBulletList(_:)), #selector(toggleNumberedList(_:)), #selector(toggleBlockQuote(_:)),
    ]

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if let action = item.action, Self.blockCommands.contains(action) { return allowsBlockFormatting && isEditable }
        return super.validateUserInterfaceItem(item)
    }

    private func toggleList(format: NSTextList.MarkerFormat) {
        guard let storage = textStorage else { return }
        let paragraphs = selectedParagraphs()
        guard let first = paragraphs.first, let last = paragraphs.last else { return }
        let removing = paragraphs.allSatisfy { $0.list?.markerFormat == format }
        let whole = NSRange(location: first.range.location, length: NSMaxRange(last.range) - first.range.location)
        guard shouldChangeText(in: whole, replacementString: nil) else { return }
        storage.beginEditing()
        for info in paragraphs.reversed() {
            if removing {
                stripList(info, storage: storage)
            } else {
                applyList(NSTextList(markerFormat: format, options: 0), to: info, storage: storage)
            }
        }
        storage.endEditing()
        didChangeText()
        if removing {
            typingAttributes = defaultTypingAttributes.merging(fontOnly(typingAttributes)) { _, new in new }
        } else {
            renumberList(containing: first.range.location)
        }
        snapCaretPastMarker()
    }

    private func applyList(_ list: NSTextList, to info: ParagraphInfo, storage: NSTextStorage) {
        var range = info.range
        if let marker = info.markerRange {
            storage.deleteCharacters(in: marker)
            range.length -= marker.length
        }
        let style = listParagraphStyle(list)
        if range.length > 0 {
            storage.removeAttribute(ComposerBlock.attributeKey, range: range)
            storage.addAttribute(.paragraphStyle, value: style, range: range)
            storage.addAttribute(.foregroundColor, value: NSColor.qInk, range: range)
        }
        storage.insert(NSAttributedString(string: "\t" + list.marker(forItemNumber: 1) + "\t", attributes: markerAttributes(style)),
                       at: range.location)
        if range.length == 0 {
            var typing = defaultTypingAttributes
            typing[.paragraphStyle] = style
            typingAttributes = typing
        }
    }

    private func stripList(_ info: ParagraphInfo, storage: NSTextStorage) {
        var range = info.range
        if let marker = info.markerRange {
            storage.deleteCharacters(in: marker)
            range.length -= marker.length
        }
        if range.length > 0 {
            storage.addAttribute(.paragraphStyle, value: bodyParagraphStyle, range: range)
            storage.addAttribute(.foregroundColor, value: NSColor.qInk, range: range)
            storage.removeAttribute(ComposerBlock.attributeKey, range: range)
        }
    }

    private func fontOnly(_ attributes: [NSAttributedString.Key: Any]) -> [NSAttributedString.Key: Any] {
        var result: [NSAttributedString.Key: Any] = [:]
        if let font = attributes[.font] { result[.font] = font }
        return result
    }

    /// Item number of a paragraph within its run of consecutive same-format list paragraphs.
    private func itemNumber(of info: ParagraphInfo) -> Int {
        guard let list = info.list else { return 0 }
        var number = 1
        var cursor = info.range.location
        while cursor > 0 {
            let previous = paragraphInfo(at: cursor - 1)
            guard previous.list?.markerFormat == list.markerFormat, previous.range.location < cursor else { break }
            number += 1
            cursor = previous.range.location
        }
        return number
    }

    /// Rewrites the markers of the list run containing `location` so numbering stays sequential.
    private func renumberList(containing location: Int) {
        guard let storage = textStorage else { return }
        let text = string as NSString
        let origin = paragraphInfo(at: location)
        guard let list = origin.list else { return }
        var start = origin.range.location
        while start > 0 {
            let previous = paragraphInfo(at: start - 1)
            guard previous.list?.markerFormat == list.markerFormat, previous.range.location < start else { break }
            start = previous.range.location
        }
        var edits: [(range: NSRange, marker: String, attributes: [NSAttributedString.Key: Any])] = []
        var number = 1
        var cursor = start
        while true {
            let info = paragraphInfo(at: cursor)
            guard let itemList = info.list, itemList.markerFormat == list.markerFormat else { break }
            let expected = "\t" + itemList.marker(forItemNumber: number) + "\t"
            let attributes = markerAttributes(listParagraphStyle(itemList))
            if let marker = info.markerRange {
                if text.substring(with: marker) != expected { edits.append((marker, expected, attributes)) }
            } else {
                edits.append((NSRange(location: info.range.location, length: 0), expected, attributes))
            }
            number += 1
            let next = NSMaxRange(info.range)
            if next >= text.length || next <= cursor { break }
            cursor = next
        }
        guard !edits.isEmpty else { return }
        let whole = NSRange(location: start, length: max(0, (edits.last.map { NSMaxRange($0.range) } ?? start) - start))
        guard shouldChangeText(in: whole, replacementString: nil) else { return }
        storage.beginEditing()
        for edit in edits.reversed() {
            storage.replaceCharacters(in: edit.range, with: NSAttributedString(string: edit.marker, attributes: edit.attributes))
        }
        storage.endEditing()
        didChangeText()
    }

    /// Gives marker-less list paragraphs (from a plain paste) their markers.
    private func repairListMarkers(in range: NSRange) {
        let text = string as NSString
        guard text.length > 0 else { return }
        var cursor = min(range.location, text.length)
        var touched = false
        while cursor <= NSMaxRange(range), cursor < text.length {
            let info = paragraphInfo(at: cursor)
            if info.list != nil, info.markerRange == nil, !touched {
                renumberList(containing: info.range.location)
                touched = true
            }
            let next = NSMaxRange(info.range)
            if next <= cursor { break }
            cursor = next
        }
    }

    private func removeList(from info: ParagraphInfo) {
        guard let storage = textStorage, shouldChangeText(in: info.range, replacementString: nil) else { return }
        storage.beginEditing()
        stripList(info, storage: storage)
        storage.endEditing()
        didChangeText()
        typingAttributes = defaultTypingAttributes.merging(fontOnly(typingAttributes)) { _, new in new }
        setSelectedRange(NSRange(location: info.range.location, length: 0))
        renumberList(containing: min(NSMaxRange(info.range) - (info.markerRange?.length ?? 0), max(0, (string as NSString).length - 1)))
    }

    // MARK: Block quotes

    @objc func toggleBlockQuote(_ sender: Any?) {
        guard allowsBlockFormatting, let storage = textStorage else { return }
        let paragraphs = selectedParagraphs()
        guard let first = paragraphs.first, let last = paragraphs.last else { return }
        let removing = paragraphs.allSatisfy { $0.block == .quote }
        let whole = NSRange(location: first.range.location, length: NSMaxRange(last.range) - first.range.location)
        guard shouldChangeText(in: whole, replacementString: nil) else { return }
        storage.beginEditing()
        for info in paragraphs.reversed() {
            if removing {
                stripQuote(info, storage: storage)
            } else {
                applyQuote(to: info, storage: storage)
            }
        }
        storage.endEditing()
        didChangeText()
        var typing = defaultTypingAttributes.merging(fontOnly(typingAttributes)) { _, new in new }
        if !removing {
            typing[.paragraphStyle] = quoteParagraphStyle
            typing[.foregroundColor] = NSColor.qInk2
            typing[ComposerBlock.attributeKey] = ComposerBlock.quote.rawValue
        }
        typingAttributes = typing
        snapCaretPastMarker()
    }

    private func applyQuote(to info: ParagraphInfo, storage: NSTextStorage) {
        var range = info.range
        if let marker = info.markerRange {
            storage.deleteCharacters(in: marker)
            range.length -= marker.length
        }
        guard range.length > 0 else { return }
        storage.addAttribute(.paragraphStyle, value: quoteParagraphStyle, range: range)
        storage.addAttribute(.foregroundColor, value: NSColor.qInk2, range: range)
        storage.addAttribute(ComposerBlock.attributeKey, value: ComposerBlock.quote.rawValue, range: range)
    }

    private func stripQuote(_ info: ParagraphInfo, storage: NSTextStorage) {
        guard info.range.length > 0 else { return }
        storage.addAttribute(.paragraphStyle, value: bodyParagraphStyle, range: info.range)
        storage.addAttribute(.foregroundColor, value: NSColor.qInk, range: info.range)
        storage.removeAttribute(ComposerBlock.attributeKey, range: info.range)
    }

    private func removeQuote(from info: ParagraphInfo) {
        guard let storage = textStorage, shouldChangeText(in: info.range, replacementString: nil) else { return }
        storage.beginEditing()
        stripQuote(info, storage: storage)
        storage.endEditing()
        didChangeText()
        typingAttributes = defaultTypingAttributes.merging(fontOnly(typingAttributes)) { _, new in new }
    }

    // MARK: Return and Delete inside structure

    override func insertNewline(_ sender: Any?) {
        let selection = selectedRange()
        let info = paragraphInfo(at: selection.location)
        if let list = info.list, selection.length == 0 {
            if info.isEmptyItem {
                // Return on an empty item ends the list.
                removeList(from: info)
                return
            }
            let marker = "\t" + list.marker(forItemNumber: itemNumber(of: info) + 1) + "\t"
            insertText("\n" + marker, replacementRange: selection)
            renumberList(containing: selectedRange().location)
            return
        }
        if info.block == .quote, selection.length == 0, info.contentRange.length == 0 {
            removeQuote(from: info)
            return
        }
        super.insertNewline(sender)
    }

    override func deleteBackward(_ sender: Any?) {
        let selection = selectedRange()
        if selection.length == 0 {
            let info = paragraphInfo(at: selection.location)
            if info.list != nil, let marker = info.markerRange, selection.location == NSMaxRange(marker) {
                removeList(from: info)
                return
            }
            if info.block == .quote, selection.location == info.range.location, info.range.length > 0 {
                removeQuote(from: info)
                return
            }
        }
        super.deleteBackward(sender)
    }

    /// The caret never lands inside a list marker; clicking the bullet puts it after the marker.
    override func selectionRange(forProposedRange proposedCharRange: NSRange, granularity: NSSelectionGranularity) -> NSRange {
        let range = super.selectionRange(forProposedRange: proposedCharRange, granularity: granularity)
        guard range.length == 0 else { return range }
        let info = paragraphInfo(at: range.location)
        if let marker = info.markerRange, range.location > marker.location, range.location < NSMaxRange(marker) {
            return NSRange(location: NSMaxRange(marker), length: 0)
        }
        return range
    }

    private func snapCaretPastMarker() {
        let selection = selectedRange()
        guard selection.length == 0 else { return }
        let info = paragraphInfo(at: selection.location)
        if let marker = info.markerRange, selection.location < NSMaxRange(marker) {
            setSelectedRange(NSRange(location: NSMaxRange(marker), length: 0))
        }
    }
}

extension ComposeTextView: NSTextStorageDelegate {
    /// Every edit, an undo or a redo included, leaves what it touched at the editor's Text size (spec §4.15). A switch
    /// is not an edit, so the undo stack still holds text at the size it was written at: without this, undoing a
    /// deletion or a ⌘B made before a switch would bring that text back at the old size and on the old line. Changing
    /// attributes here is allowed; the layout managers hear of the edit after it.
    nonisolated func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
                                 range editedRange: NSRange, changeInLength delta: Int) {
        guard Thread.isMainThread else { return }
        MainActor.assumeIsolated {
            _ = WritingTextSize.apply(textSize, to: textStorage, in: editedRange)
        }
    }
}
