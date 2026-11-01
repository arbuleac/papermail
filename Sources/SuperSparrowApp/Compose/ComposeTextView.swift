import AppKit
import Carbon.HIToolbox
import SSCore

/// The body editor. Rich text is limited to what mail reliably carries: bold, italic, underline, links,
/// bulleted and numbered lists, and block quotes. Everything else the text system could do (fonts, sizes,
/// colors, images, rulers) is switched off or folded back into those few styles.
///
/// Lists use `NSTextList` paragraph styles with the marker typed into the text, as TextEdit does, so the
/// editor shows real markers; `ComposeBodyNormalizer` strips them before export. Quotes are a paragraph
/// attribute (`ComposerBlock.attributeKey`) painted by `ComposeLayoutManager`.
@MainActor
final class ComposeTextView: NSTextView {
    static let bodyFont = NSFont.systemFont(ofSize: 13)
    static let bulletFormat = NSTextList.MarkerFormat.disc
    static let numberFormat = NSTextList.MarkerFormat("{decimal}.")
    static let listIndent: CGFloat = 28
    static let quoteIndent: CGFloat = 16

    /// Kept alive here: in TextKit 1 the text view holds its container, the container points weakly at
    /// the layout manager, and the layout manager points weakly at the storage.
    private let ownedStorage: NSTextStorage

    override init(frame: NSRect) {
        let storage = NSTextStorage()
        let layoutManager = ComposeLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: frame.width, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layoutManager.addTextContainer(container)
        ownedStorage = storage
        super.init(frame: frame, textContainer: container)
        configure()
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
        importsGraphics = false
        allowsImageEditing = false
        isAutomaticLinkDetectionEnabled = true
        isAutomaticDataDetectionEnabled = false
        isContinuousSpellCheckingEnabled = true
        isGrammarCheckingEnabled = false
        font = Self.bodyFont
        textColor = .textColor
        typingAttributes = Self.defaultTypingAttributes
        textContainerInset = NSSize(width: 10, height: 10)
        // The editor sits in a document view together with the quoted original, so Auto Layout, not the
        // text system, owns its height: it reports the laid-out text height as intrinsic size instead.
        isVerticallyResizable = false
        isHorizontallyResizable = false
        translatesAutoresizingMaskIntoConstraints = false
        minSize = .zero
        maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        backgroundColor = .textBackgroundColor
        linkTextAttributes = [
            .foregroundColor: NSColor.linkColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .cursor: NSCursor.pointingHand,
        ]
        updateDragTypeRegistration()
    }

    static var defaultTypingAttributes: [NSAttributedString.Key: Any] {
        [.font: bodyFont, .foregroundColor: NSColor.textColor, .paragraphStyle: NSParagraphStyle.default]
    }

    // MARK: Sizing

    private var lastIntrinsicWidth: CGFloat = 0

    override var intrinsicContentSize: NSSize {
        guard let layoutManager, let textContainer else { return super.intrinsicContentSize }
        layoutManager.ensureLayout(for: textContainer)
        let used = layoutManager.usedRect(for: textContainer)
        return NSSize(width: NSView.noIntrinsicMetric, height: ceil(used.height) + textContainerInset.height * 2)
    }

    override func didChangeText() {
        super.didChangeText()
        invalidateIntrinsicContentSize()
        // The text system scrolls to the caret right after this; the frame must already be tall enough.
        enclosingScrollView?.layoutSubtreeIfNeeded()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        // Wrapping changes with the width, and so does the height the text needs.
        if abs(newSize.width - lastIntrinsicWidth) > 0.5 {
            lastIntrinsicWidth = newSize.width
            invalidateIntrinsicContentSize()
        }
    }

    /// Replaces the whole document (reopening an undone send) without leaving stale typing attributes behind.
    func replaceContents(with content: NSAttributedString) {
        textStorage?.setAttributedString(content)
        typingAttributes = Self.defaultTypingAttributes
        invalidateIntrinsicContentSize()
    }

    // MARK: Plain pasting

    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] { [.string] }
    override var acceptableDragTypes: [NSPasteboard.PasteboardType] { [.string] }

    override func paste(_ sender: Any?) {
        let start = selectedRange().location
        pasteAsPlainText(sender)
        // Pasted paragraphs inherit the list style of the insertion point but arrive without markers.
        repairListMarkers(in: NSRange(location: start, length: max(0, selectedRange().location - start)))
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
            default: break
            }
        }
        if flags == [.command, .shift] {
            switch Int(event.keyCode) {
            case kVK_ANSI_8: toggleBulletList(nil); return true
            case kVK_ANSI_7: toggleNumberedList(nil); return true
            case kVK_ANSI_9: toggleBlockQuote(nil); return true
            default: break
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    // MARK: Character styles

    @objc func toggleBold(_ sender: Any?) {
        toggleTrait(.boldFontMask)
    }

    @objc func toggleItalic(_ sender: Any?) {
        toggleTrait(.italicFontMask)
    }

    /// The Font menu and panel may only change bold and italic; family and size stay the composer's.
    override func changeFont(_ sender: Any?) {
        let manager = NSFontManager.shared
        transformFonts { font in
            let traits = manager.traits(of: manager.convert(font)).intersection([.boldFontMask, .italicFontMask])
            return Self.font(withTraits: traits)
        }
    }

    override func changeColor(_ sender: Any?) {}

    override func changeAttributes(_ sender: Any?) {}

    private func toggleTrait(_ trait: NSFontTraitMask) {
        let manager = NSFontManager.shared
        let range = selectedRange()
        var everyRunHasTrait = true
        if range.length == 0 {
            let font = (typingAttributes[.font] as? NSFont) ?? Self.bodyFont
            everyRunHasTrait = manager.traits(of: font).contains(trait)
        } else if let storage = textStorage {
            storage.enumerateAttribute(.font, in: range, options: []) { value, _, stop in
                let font = (value as? NSFont) ?? Self.bodyFont
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
        typing[.font] = transform((typing[.font] as? NSFont) ?? Self.bodyFont)
        guard range.length > 0, let storage = textStorage else {
            typingAttributes = typing
            return
        }
        guard shouldChangeText(in: range, replacementString: nil) else { return }
        storage.beginEditing()
        storage.enumerateAttribute(.font, in: range, options: []) { value, subrange, _ in
            let font = (value as? NSFont) ?? Self.bodyFont
            storage.addAttribute(.font, value: transform(font), range: subrange)
        }
        storage.endEditing()
        didChangeText()
        typingAttributes = typing
    }

    private static func font(withTraits traits: NSFontTraitMask) -> NSFont {
        let manager = NSFontManager.shared
        var font = bodyFont
        if traits.contains(.boldFontMask) { font = manager.convert(font, toHaveTrait: .boldFontMask) }
        if traits.contains(.italicFontMask) { font = manager.convert(font, toHaveTrait: .italicFontMask) }
        return font
    }

    // MARK: Links

    @objc func insertLink(_ sender: Any?) {
        guard let window else { return }
        let range = selectedRange()
        let existing = existingLink(at: range)
        let alert = NSAlert()
        alert.messageText = existing == nil ? "Add Link" : "Edit Link"
        alert.informativeText = existing == nil && range.length == 0
            ? "The address is inserted as the link text."
            : "Leave the address empty to remove the link."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = "https://"
        field.stringValue = existing?.target ?? ""
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                guard response == .alertFirstButtonReturn, let self else { return }
                self.applyLink(field.stringValue, to: existing?.range ?? range)
            }
        }
    }

    private func existingLink(at range: NSRange) -> (target: String, range: NSRange)? {
        guard let storage = textStorage, storage.length > 0 else { return nil }
        let probe = range.length > 0 ? range.location : max(0, min(range.location, storage.length - 1))
        var effective = NSRange(location: 0, length: 0)
        guard let value = storage.attribute(.link, at: probe, longestEffectiveRange: &effective, in: NSRange(location: 0, length: storage.length)) else {
            return nil
        }
        if let url = value as? URL { return (url.absoluteString, effective) }
        if let string = value as? String { return (string, effective) }
        return nil
    }

    private func applyLink(_ raw: String, to range: NSRange) {
        guard let storage = textStorage else { return }
        let target = Self.normalizedLink(raw)
        if range.length == 0 {
            guard let target else { return }
            var attributes = typingAttributes
            attributes[.link] = target
            let text = NSAttributedString(string: target, attributes: attributes)
            guard shouldChangeText(in: range, replacementString: target) else { return }
            storage.replaceCharacters(in: range, with: text)
            didChangeText()
            setSelectedRange(NSRange(location: range.location + text.length, length: 0))
        } else {
            guard shouldChangeText(in: range, replacementString: nil) else { return }
            if let target {
                storage.addAttribute(.link, value: target, range: range)
            } else {
                storage.removeAttribute(.link, range: range)
            }
            didChangeText()
        }
        // Typing after a link should not extend it.
        var typing = typingAttributes
        typing[.link] = nil
        typingAttributes = typing
    }

    static func normalizedLink(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.contains("://") || trimmed.lowercased().hasPrefix("mailto:") { return trimmed }
        if trimmed.contains("@"), !trimmed.contains("/") { return "mailto:" + trimmed }
        return "https://" + trimmed
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

    static func listParagraphStyle(_ list: NSTextList) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.textLists = [list]
        style.headIndent = listIndent
        style.firstLineHeadIndent = 0
        style.tabStops = [
            NSTextTab(textAlignment: .right, location: listIndent - 8, options: [:]),
            NSTextTab(textAlignment: .left, location: listIndent, options: [:]),
        ]
        style.defaultTabInterval = listIndent
        return style
    }

    static var quoteParagraphStyle: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.headIndent = quoteIndent
        style.firstLineHeadIndent = quoteIndent
        return style
    }

    // MARK: Lists

    @objc func toggleBulletList(_ sender: Any?) {
        toggleList(format: Self.bulletFormat)
    }

    @objc func toggleNumberedList(_ sender: Any?) {
        toggleList(format: Self.numberFormat)
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
            typingAttributes = Self.defaultTypingAttributes.merging(fontOnly(typingAttributes)) { _, new in new }
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
        let style = Self.listParagraphStyle(list)
        if range.length > 0 {
            storage.removeAttribute(ComposerBlock.attributeKey, range: range)
            storage.addAttribute(.paragraphStyle, value: style, range: range)
        }
        var attributes = Self.defaultTypingAttributes
        attributes[.paragraphStyle] = style
        storage.insert(NSAttributedString(string: "\t" + list.marker(forItemNumber: 1) + "\t", attributes: attributes), at: range.location)
        if range.length == 0 {
            typingAttributes = attributes
        }
    }

    private func stripList(_ info: ParagraphInfo, storage: NSTextStorage) {
        var range = info.range
        if let marker = info.markerRange {
            storage.deleteCharacters(in: marker)
            range.length -= marker.length
        }
        if range.length > 0 {
            storage.addAttribute(.paragraphStyle, value: NSParagraphStyle.default, range: range)
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
            var attributes = Self.defaultTypingAttributes
            attributes[.paragraphStyle] = Self.listParagraphStyle(itemList)
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
        typingAttributes = Self.defaultTypingAttributes.merging(fontOnly(typingAttributes)) { _, new in new }
        setSelectedRange(NSRange(location: info.range.location, length: 0))
        renumberList(containing: min(NSMaxRange(info.range) - (info.markerRange?.length ?? 0), max(0, (string as NSString).length - 1)))
    }

    // MARK: Block quotes

    @objc func toggleBlockQuote(_ sender: Any?) {
        guard let storage = textStorage else { return }
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
        var typing = Self.defaultTypingAttributes.merging(fontOnly(typingAttributes)) { _, new in new }
        if !removing {
            typing[.paragraphStyle] = Self.quoteParagraphStyle
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
        storage.addAttribute(.paragraphStyle, value: Self.quoteParagraphStyle, range: range)
        storage.addAttribute(ComposerBlock.attributeKey, value: ComposerBlock.quote.rawValue, range: range)
    }

    private func stripQuote(_ info: ParagraphInfo, storage: NSTextStorage) {
        guard info.range.length > 0 else { return }
        storage.addAttribute(.paragraphStyle, value: NSParagraphStyle.default, range: info.range)
        storage.removeAttribute(ComposerBlock.attributeKey, range: info.range)
    }

    private func removeQuote(from info: ParagraphInfo) {
        guard let storage = textStorage, shouldChangeText(in: info.range, replacementString: nil) else { return }
        storage.beginEditing()
        stripQuote(info, storage: storage)
        storage.endEditing()
        didChangeText()
        typingAttributes = Self.defaultTypingAttributes.merging(fontOnly(typingAttributes)) { _, new in new }
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
