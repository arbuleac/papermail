import AppKit
import SSCore
import SSDesign

/// A recipient field (spec §5.21): tokens are `EmailAddress` values drawn as 22 pt Quire pills, followed by
/// the text being typed. Completions come from the store's contact table, looked up off the main thread
/// after an 80 ms pause in typing so a fast typist never waits on SQLite, and show in the app-drawn
/// autocomplete popover.
///
/// Focused, the tokens wrap into lines 26 pt apart and the row grows up to three lines, then scrolls inside
/// itself. Unfocused, the row collapses to one line with “+N more”, never hiding an invalid token.
///
/// A token is selected by clicking it or with ← from the start of the text; the field itself is then the first
/// responder, ← → move the selection, ⌫ removes it, ↩ or a double-click edits it, and typing goes back to
/// the text. The row's inset focus ring moves onto the selected token.
@MainActor
final class AddressTokenField: NSView, NSTextFieldDelegate {
    typealias SuggestionProvider = @Sendable (_ prefix: String, _ limit: Int) throws -> [EmailAddress]

    /// Usually `store.suggestAddresses(prefix:limit:)`.
    var suggestionProvider: SuggestionProvider?
    /// Tokens or typed text changed.
    var onChange: (() -> Void)?
    /// The height the row needs changed (tokens wrapped, focus collapsed the row).
    var onLayoutChange: (() -> Void)?
    /// Keyboard focus moved into, out of or within the field (the row redraws its ring).
    var onFocusChange: (() -> Void)?
    /// The token context menu's New Message.
    var onNewMessage: ((EmailAddress) -> Void)?
    /// Where the autocomplete popover is drawn: the composer's content view, above everything else.
    weak var overlayHost: NSView?

    var addresses: [EmailAddress] {
        get { tokens }
        set {
            tokens = newValue
            selectedIndex = nil
            relayout()
        }
    }

    /// Text typed but not yet a token.
    var pendingText: String { input.stringValue }

    /// The Send in progress: tokens draw disabled and nothing can be edited.
    var isLocked = false {
        didSet {
            input.isEditable = !isLocked
            document.needsDisplay = true
            document.pointerRegionsDidChange()
        }
    }

    /// The view the key-view loop goes through.
    var keyView: NSView { input }

    /// The row's height for the current layout (36 pt per line, up to 88 pt).
    private(set) var rowHeight: CGFloat = Quire.Layout.Composer.fieldRow

    private var tokens: [EmailAddress] = []
    private(set) var selectedIndex: Int? {
        didSet { if oldValue != selectedIndex { document.needsDisplay = true; onFocusChange?() } }
    }
    private var hoveredIndex: Int? {
        didSet { if oldValue != hoveredIndex { document.needsDisplay = true } }
    }
    private var layoutResult = AddressTokenLayout(placements: [], inputLine: 0, inputX: 0, inputWidth: 0, lineCount: 1)
    private var isExpanded = false
    private(set) var hasKeyboardFocus = false

    private let scrollView = NSScrollView()
    private let document = TokenDocumentView()
    let input = TokenInputField()
    private var autocomplete: AddressAutocompleteView?
    private var lookupTask: Task<Void, Never>?
    private var requestedPrefix = ""
    private var toolTipTags: [NSView.ToolTipTag] = []

    private static let suggestionLimit = Int(Quire.Layout.Autocomplete.maxRows)
    private static let debounce = Duration.milliseconds(80)
    /// The typed text keeps at least this much of a line before it wraps under the tokens.
    private static let minimumInputWidth: CGFloat = 96
    /// Tokens start this far into the field so the selected token's ring (2 pt gap + 3 pt in Increase
    /// Contrast) is never clipped; the row puts the field this much left of the value axis.
    static let inset: CGFloat = Quire.Layout.Composer.valueX - Quire.Layout.Composer.focusRingX
    /// The first line's top: the field sits 3 pt into its row, and the token 7 pt.
    static let lineTop: CGFloat = 4

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.verticalScrollElasticity = .none
        scrollView.contentView.drawsBackground = false
        scrollView.documentView = document
        addSubview(scrollView)
        document.field = self
        document.registerForDraggedTypes([.string])
        document.addSubview(input)
        input.delegate = self
        setAccessibilityRole(.group)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("AddressTokenField is built in code")
    }

    deinit {
        lookupTask?.cancel()
    }

    override var isFlipped: Bool { true }

    // MARK: Validation

    /// Commits any text still being typed and reports whether every token is a valid address (and, when
    /// asked, that there is at least one). Invalid tokens show themselves in red.
    @discardableResult
    func validateForSend(requireRecipient: Bool = false) -> Bool {
        commitPendingText()
        let invalid = AddressListParser.invalidEntries(in: tokens)
        return invalid.isEmpty && (!requireRecipient || !tokens.isEmpty)
    }

    // MARK: Focus

    /// Called by the composer whenever the window's first responder changes.
    func firstResponderDidChange() {
        let focused = isFocused
        guard focused != hasKeyboardFocus else {
            onFocusChange?()
            return
        }
        hasKeyboardFocus = focused
        if !focused {
            commitPendingText()
            selectedIndex = nil
            closeAutocomplete()
            scrollView.contentView.scroll(to: .zero)
        }
        isExpanded = focused
        relayout()
        onFocusChange?()
    }

    private var isFocused: Bool {
        guard let responder = window?.firstResponder else { return false }
        if responder === self || responder === input { return true }
        if let editor = responder as? NSTextView, editor.delegate === input { return true }
        return false
    }

    /// True when the selected token carries the focus ring instead of the row (§5.21).
    var focusIsOnToken: Bool { selectedIndex != nil && window?.firstResponder === self }

    override var acceptsFirstResponder: Bool { selectedIndex != nil }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { document.needsDisplay = true }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { document.needsDisplay = true }
        return resigned
    }

    /// The selected token's ring follows the window's key state.
    func windowKeyDidChange() {
        document.needsDisplay = true
    }

    func focusInput() {
        selectedIndex = nil
        window?.makeFirstResponder(input)
        if let editor = input.currentEditor() {
            editor.selectedRange = NSRange(location: (input.stringValue as NSString).length, length: 0)
        }
    }

    // MARK: Layout

    override func layout() {
        super.layout()
        scrollView.frame = bounds
        relayout()
    }

    private func tokenWidth(_ index: Int) -> CGFloat {
        let t = Quire.Layout.Token.self
        let label = Self.label(tokens[index])
        let text = ceil(QuireFont.attributedString(label, role: .body, color: .black).size().width)
        if isInvalid(index) {
            return Self.invalidPadLeft + t.invalidGlyph + t.gap + text + t.padX
        }
        return text + 2 * t.padX
    }

    private static let invalidPadLeft: CGFloat = 6

    private func moreWidth(_ count: Int) -> CGFloat {
        ceil(QuireFont.attributedString(Self.moreLabel(count), role: .body, color: .black).size().width)
    }

    static func moreLabel(_ count: Int) -> String { "+\(count) more" }

    func isInvalid(_ index: Int) -> Bool {
        !AddressListParser.isValid(tokens[index].address)
    }

    static func label(_ address: EmailAddress) -> String {
        if let name = address.name?.trimmingCharacters(in: .whitespaces), !name.isEmpty { return name }
        return address.address
    }

    /// Lays the tokens out for the current width and focus, and tells the row when it must change height.
    func relayout() {
        let t = Quire.Layout.Token.self
        let available = max(40, bounds.width - 2 * Self.inset)
        let widths = tokens.indices.map(tokenWidth)
        if isExpanded || tokens.isEmpty {
            layoutResult = AddressTokenLayout.flow(widths: widths, availableWidth: available, gap: t.gap,
                                                   minimumInputWidth: min(Self.minimumInputWidth, available))
        } else {
            let invalid = Set(tokens.indices.filter(isInvalid))
            layoutResult = AddressTokenLayout.collapse(widths: widths, invalid: invalid, availableWidth: available,
                                                       gap: t.gap, moreGap: t.moreGap, moreWidth: moreWidth)
        }
        let lines = layoutResult.lineCount
        let documentHeight = Self.lineTop * 2 + CGFloat(lines - 1) * t.lineGrow + t.height
        document.frame = NSRect(x: 0, y: 0, width: bounds.width, height: max(documentHeight, bounds.height))
        placeInput()
        let height = AddressTokenLayout.rowHeight(lines: lines, base: Quire.Layout.Composer.fieldRow, lineGrow: t.lineGrow,
                                                  maxLines: Int(t.maxLines))
        updateToolTips()
        document.needsDisplay = true
        document.pointerRegionsDidChange()
        if abs(height - rowHeight) > 0.5 {
            rowHeight = height
            onLayoutChange?()
        }
        scrollCaretLineIntoView()
        if autocomplete != nil { positionAutocomplete() }
    }

    private func placeInput() {
        let t = Quire.Layout.Token.self
        let fieldHeight = input.intrinsicContentSize.height
        let line: Int
        let x: CGFloat
        let width: CGFloat
        if let inputLine = layoutResult.inputLine {
            line = inputLine
            x = layoutResult.inputX
            width = layoutResult.inputWidth
        } else {
            // Collapsed: the empty field waits after the last visible mark so a click or Tab still lands in it.
            line = 0
            var end: CGFloat = 0
            if let moreX = layoutResult.moreX {
                end = moreX + moreWidth(layoutResult.hiddenCount) + t.gap
            } else if let last = layoutResult.placements.last {
                end = last.x + last.width + t.gap
            }
            x = end
            width = max(2, bounds.width - 2 * Self.inset - end)
        }
        let top = lineRectTop(line) + (t.height - fieldHeight) / 2
        input.frame = NSRect(x: Self.inset + x, y: top.rounded(), width: width, height: fieldHeight)
    }

    func lineRectTop(_ line: Int) -> CGFloat {
        Self.lineTop + CGFloat(line) * Quire.Layout.Token.lineGrow
    }

    /// Each visible token's pill, in document coordinates.
    func tokenRects() -> [(index: Int, rect: NSRect)] {
        layoutResult.placements.map { placement in
            (placement.index, NSRect(x: Self.inset + placement.x, y: lineRectTop(placement.line),
                                     width: placement.width, height: Quire.Layout.Token.height))
        }
    }

    func moreRect() -> NSRect? {
        guard let moreX = layoutResult.moreX, layoutResult.hiddenCount > 0 else { return nil }
        return NSRect(x: Self.inset + moreX, y: lineRectTop(0), width: moreWidth(layoutResult.hiddenCount),
                      height: Quire.Layout.Token.height)
    }

    var hiddenCount: Int { layoutResult.hiddenCount }

    private func scrollCaretLineIntoView() {
        guard isExpanded else { return }
        let line = selectedIndex.flatMap { index in layoutResult.placements.first { $0.index == index }?.line }
            ?? layoutResult.inputLine ?? 0
        let rect = NSRect(x: 0, y: lineRectTop(line) - Self.lineTop, width: 1, height: Quire.Layout.Token.lineGrow + Self.lineTop)
        document.scrollToVisible(rect)
    }

    private func updateToolTips() {
        for tag in toolTipTags { document.removeToolTip(tag) }
        toolTipTags = tokenRects().map { item in
            document.addToolTip(item.rect, owner: self, userData: UnsafeMutableRawPointer(bitPattern: item.index + 1))
        }
    }

    // MARK: Editing tokens

    /// Turns everything typed into tokens (focus leaving, Send, Return).
    func commitPendingText() {
        let text = input.stringValue
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            if !text.isEmpty { input.stringValue = "" }
            return
        }
        let parsed = AddressListParser.parse(text)
        input.stringValue = ""
        addTokens(parsed)
    }

    private func addTokens(_ added: [EmailAddress]) {
        let fresh = added.filter { !$0.address.isEmpty }
        guard !fresh.isEmpty else { return }
        tokens.append(contentsOf: fresh)
        relayout()
        onChange?()
    }

    func removeToken(at index: Int) {
        guard tokens.indices.contains(index), !isLocked else { return }
        tokens.remove(at: index)
        selectedIndex = nil
        hoveredIndex = nil
        relayout()
        onChange?()
    }

    /// The token turns back into text with the caret at its end (§5.21, Being edited).
    func editToken(at index: Int) {
        guard tokens.indices.contains(index), !isLocked else { return }
        let address = tokens.remove(at: index)
        commitPendingText()
        input.stringValue = AddressListParser.format(address)
        selectedIndex = nil
        relayout()
        focusInput()
        onChange?()
    }

    func formattedAddress(at index: Int) -> String {
        tokens.indices.contains(index) ? AddressListParser.format(tokens[index]) : ""
    }

    /// Addresses dropped as text (a token from another field, a list from elsewhere) become tokens.
    func acceptDroppedText(_ text: String) -> Bool {
        guard !isLocked else { return false }
        let parsed = AddressListParser.parse(text)
        guard !parsed.isEmpty else { return false }
        addTokens(parsed)
        return true
    }

    func selectToken(_ index: Int) {
        guard tokens.indices.contains(index) else { return }
        closeAutocomplete()
        commitPendingText()
        selectedIndex = index
        window?.makeFirstResponder(self)
        scrollCaretLineIntoView()
    }

    func expandFromMore() {
        isExpanded = true
        relayout()
        focusInput()
    }

    // MARK: Keyboard (a token selected)

    override func keyDown(with event: NSEvent) {
        guard let index = selectedIndex else {
            super.keyDown(with: event)
            return
        }
        let flags = event.modifierFlags.intersection([.command, .control, .option])
        if let special = event.specialKey, flags.isEmpty {
            switch special {
            case .leftArrow:
                selectedIndex = max(0, index - 1)
                scrollCaretLineIntoView()
                return
            case .rightArrow:
                if index + 1 < tokens.count { selectedIndex = index + 1; scrollCaretLineIntoView() } else { focusInput() }
                return
            case .delete, .deleteForward:
                let removed = tokens[index]
                removeToken(at: index)
                focusInput()
                offerUndo(restoring: removed, at: index)
                return
            case .carriageReturn, .enter, .newline:
                editToken(at: index)
                return
            case .tab:
                selectedIndex = nil
                window?.selectKeyView(following: input)
                return
            case .backTab:
                selectedIndex = nil
                window?.selectKeyView(preceding: input)
                return
            default:
                break
            }
        }
        if event.keyCode == 53 { // Esc: back to the text, the token kept.
            focusInput()
            return
        }
        if flags.isEmpty, let characters = event.characters, !characters.isEmpty,
           characters.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) {
            // Typing returns to the text and keeps the keystroke.
            focusInput()
            input.currentEditor()?.insertText(characters)
            return
        }
        super.keyDown(with: event)
    }

    @objc func copy(_ sender: Any?) {
        guard let index = selectedIndex else { return }
        writeToPasteboard(tokens[index])
    }

    @objc func cut(_ sender: Any?) {
        guard let index = selectedIndex else { return }
        let removed = tokens[index]
        writeToPasteboard(removed)
        removeToken(at: index)
        focusInput()
        offerUndo(restoring: removed, at: index)
    }

    /// Removing a selected token can be undone, as it could in `NSTokenField`, whose tokens were text. The
    /// undo joins the field editor's typing undo, so ⌘Z takes it while the caret is in this field (§6.1, row 1)
    /// and it ends with the editing, like the typing does.
    private func offerUndo(restoring address: EmailAddress, at index: Int) {
        guard let undoManager = input.currentEditor()?.undoManager else { return }
        undoManager.registerUndo(withTarget: self) { field in
            field.insertToken(address, at: index)
        }
        undoManager.setActionName("Remove Recipient")
    }

    private func insertToken(_ address: EmailAddress, at index: Int) {
        guard !isLocked else { return }
        tokens.insert(address, at: min(max(0, index), tokens.count))
        selectedIndex = nil
        relayout()
        onChange?()
    }

    @objc func paste(_ sender: Any?) {
        focusInput()
        input.currentEditor()?.paste(sender)
    }

    @objc override func selectAll(_ sender: Any?) {
        focusInput()
        input.currentEditor()?.selectAll(sender)
    }

    private func writeToPasteboard(_ address: EmailAddress) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(AddressListParser.format(address), forType: .string)
    }

    // MARK: Context menu

    func menu(forToken index: Int) -> NSMenu {
        let address = tokens[index]
        let menu = NSMenu()
        menu.autoenablesItems = false
        func add(_ title: String, _ action: Selector) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.tag = index
            item.isEnabled = !isLocked || action == #selector(copyAddress(_:))
            menu.addItem(item)
        }
        add("Copy Address", #selector(copyAddress(_:)))
        add("Edit", #selector(editFromMenu(_:)))
        add("Remove", #selector(removeFromMenu(_:)))
        menu.addItem(.separator())
        add("New Message", #selector(newMessageFromMenu(_:)))
        menu.items.last?.isEnabled = onNewMessage != nil && AddressListParser.isValid(address.address)
        return menu
    }

    @objc private func copyAddress(_ sender: NSMenuItem) {
        guard tokens.indices.contains(sender.tag) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(tokens[sender.tag].address, forType: .string)
    }

    @objc private func editFromMenu(_ sender: NSMenuItem) { editToken(at: sender.tag) }

    @objc private func removeFromMenu(_ sender: NSMenuItem) { removeToken(at: sender.tag) }

    @objc private func newMessageFromMenu(_ sender: NSMenuItem) {
        guard tokens.indices.contains(sender.tag) else { return }
        onNewMessage?(tokens[sender.tag])
    }

    // MARK: Text field delegate

    func controlTextDidChange(_ obj: Notification) {
        selectedIndex = nil
        let text = input.stringValue
        // Separators outside quotes end an entry, so a typed or pasted list becomes tokens as it arrives.
        if text.unicodeScalars.contains(where: AddressListParser.separators.contains) {
            let pieces = AddressListParser.completedEntries(in: text)
            if !pieces.complete.isEmpty {
                input.stringValue = pieces.remainder
                addTokens(pieces.complete.compactMap(AddressListParser.parseEntry))
            }
        }
        scheduleLookup(input.stringValue.trimmingCharacters(in: .whitespaces))
        onChange?()
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        lookupTask?.cancel()
        // A removed token's undo lives as long as the typing undo of this edit (`offerUndo`).
        window?.undoManager?.removeAllActions(withTarget: self)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if let autocomplete {
            switch selector {
            case #selector(NSResponder.moveDown(_:)): autocomplete.moveHighlight(by: 1); return true
            case #selector(NSResponder.moveUp(_:)): autocomplete.moveHighlight(by: -1); return true
            case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)):
                if let suggestion = autocomplete.highlighted { accept(suggestion); return true }
            case #selector(NSResponder.cancelOperation(_:)):
                closeAutocomplete()
                return true
            default: break
            }
        }
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            commitPendingText()
            return true
        case #selector(NSResponder.deleteBackward(_:)), #selector(NSResponder.moveLeft(_:)):
            // From the start of the text, ⌫ and ← reach the last token: the first press selects it.
            if textView.selectedRange() == NSRange(location: 0, length: 0), !tokens.isEmpty {
                selectToken(tokens.count - 1)
                return true
            }
        case #selector(NSResponder.cancelOperation(_:)):
            // With no autocomplete to close, Esc goes to the composer, which closes only if it holds nothing worth
            // keeping (§6.1).
            (window?.windowController as? ComposeWindowController)?.escapeComposer(self)
            return true
        default: break
        }
        return false
    }

    // MARK: Completions

    private func scheduleLookup(_ prefix: String) {
        lookupTask?.cancel()
        requestedPrefix = prefix
        guard !prefix.isEmpty, let provider = suggestionProvider else {
            closeAutocomplete()
            return
        }
        let taken = Set(tokens.map { $0.address.lowercased() })
        lookupTask = Task { [weak self] in
            try? await Task.sleep(for: Self.debounce)
            guard !Task.isCancelled else { return }
            let limit = Self.suggestionLimit + taken.count
            let results = await Task.detached(priority: .userInitiated) {
                (try? provider(prefix, limit)) ?? []
            }.value
            guard !Task.isCancelled, let self, self.requestedPrefix == prefix, self.hasKeyboardFocus else { return }
            let fresh = results.filter { !taken.contains($0.address.lowercased()) }.prefix(Self.suggestionLimit)
            self.showAutocomplete(Array(fresh), prefix: prefix)
        }
    }

    private func showAutocomplete(_ suggestions: [EmailAddress], prefix: String) {
        guard !suggestions.isEmpty, let host = overlayHost else {
            closeAutocomplete()
            return
        }
        let view = autocomplete ?? AddressAutocompleteView()
        if autocomplete == nil {
            view.onAccept = { [weak self] suggestion in self?.accept(suggestion) }
            host.addSubview(view, positioned: .above, relativeTo: nil)
            autocomplete = view
        }
        view.show(suggestions, typed: prefix)
        positionAutocomplete()
    }

    private func positionAutocomplete() {
        guard let autocomplete, let host = overlayHost else { return }
        let line = layoutResult.inputLine ?? 0
        let lineRect = NSRect(x: input.frame.minX, y: lineRectTop(line), width: input.frame.width, height: Quire.Layout.Token.height)
        let hostLine = host.convert(lineRect, from: document)
        let editorStart = input.convert(NSPoint(x: input.textStartX, y: 0), to: host).x
        let a = Quire.Layout.Autocomplete.self
        let frame = ComposePopoverPlacement.autocomplete(
            tokenStartX: editorStart, caretLine: hostLine, size: autocomplete.fittingSize, bounds: host.bounds,
            offsetX: a.offsetX, offsetY: a.offsetY, edgeMin: Quire.Layout.Composer.popoverEdgeMin)
        autocomplete.setFrameFromPopover(frame)
    }

    func closeAutocomplete() {
        autocomplete?.removeFromSuperview()
        autocomplete = nil
    }

    private func accept(_ suggestion: EmailAddress) {
        closeAutocomplete()
        lookupTask?.cancel()
        input.stringValue = ""
        addTokens([suggestion])
        focusInput()
    }

    // MARK: Hover

    func pointerMoved(to point: NSPoint?) {
        guard let point else {
            hoveredIndex = nil
            return
        }
        hoveredIndex = tokenRects().first { $0.rect.contains(point) }?.index
    }

    // MARK: Drawing support

    struct TokenLook {
        var fill: NSColor
        var edge: NSColor?
        var text: NSColor
        var glyph: NSColor?
    }

    func look(for index: Int) -> TokenLook {
        if isLocked { return TokenLook(fill: .qFill, text: .qInkDisabled) }
        if selectedIndex == index { return TokenLook(fill: .qAccentFill, text: .qOnAccent) }
        if isInvalid(index) { return TokenLook(fill: .qDangerWash, edge: .qDanger, text: .qDanger, glyph: .qDanger) }
        if hoveredIndex == index { return TokenLook(fill: .qPressed, text: .qInk) }
        return TokenLook(fill: .qFill, text: .qInk)
    }

    func label(for index: Int) -> String { Self.label(tokens[index]) }

    var showsTokenRing: Bool {
        focusIsOnToken && (window?.isKeyWindow ?? false)
    }

    // MARK: Accessibility

    /// Reused across queries so VoiceOver keeps its place on a recipient while the field relays out.
    private var tokenElements: [NSAccessibilityElement] = []

    override func accessibilityChildren() -> [Any]? {
        var children: [Any] = []
        let rects = Dictionary(uniqueKeysWithValues: tokenRects().map { ($0.index, $0.rect) })
        let fallback = moreRect() ?? input.frame
        while tokenElements.count < tokens.count {
            let element = NSAccessibilityElement()
            element.setAccessibilityRole(.button)
            tokenElements.append(element)
        }
        tokenElements.removeLast(tokenElements.count - tokens.count)
        for index in tokens.indices {
            let element = tokenElements[index]
            var label = "\(label(for: index)), \(tokens[index].address)"
            if isInvalid(index) { label += ", invalid address" }
            element.setAccessibilityLabel(label)
            element.setAccessibilitySelected(selectedIndex == index)
            element.setAccessibilityParent(self)
            let rect = rects[index] ?? fallback
            if let window {
                element.setAccessibilityFrame(window.convertToScreen(document.convert(rect, to: nil)))
            }
            children.append(element)
        }
        children.append(input)
        return children
    }
}

extension AddressTokenField: NSViewToolTipOwner {
    nonisolated func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        let index = Int(bitPattern: data) - 1
        return MainActor.assumeIsolated {
            tokens.indices.contains(index) ? tokens[index].address : ""
        }
    }
}

/// The flipped document inside the field's scroll view: draws the tokens and “+N more”, hosts the text field.
@MainActor
final class TokenDocumentView: NSView, QuirePointerTarget {
    weak var field: AddressTokenField?
    private var trackingArea: NSTrackingArea?

    override var isFlipped: Bool { true }

    // MARK: Pointer

    /// The pointing hand over each token, which a click selects, double-click edits and a drag moves, and over
    /// “+N more” as far as its click reaches; the I-beam over the rest of the field, where a click puts the caret in
    /// the text (§4.17). The text field keeps its own. While a send locks the field a click there changes nothing, so
    /// the tokens and the field show the arrow, as they show the disabled ink.
    var pointerRegions: [QuirePointerRegion] {
        guard let field else { return [] }
        let tokens = field.tokenRects().map(\.rect)
        var taken = tokens + [field.input.frame]
        var regions = tokens.map { QuirePointerRegion.control($0, acts: !field.isLocked) }
        if let more = field.moreRect() {
            // A click takes the tokens and the text field before “+N more”, so its slop leaves them out.
            let reach = more.insetBy(dx: -4, dy: -4).intersection(bounds)
            regions += QuirePointerRegion.regions(reach, cursor: .pointingHand, cutting: taken)
            taken.append(reach)
        }
        return regions + QuirePointerRegion.regions(bounds, cursor: field.isLocked ? .arrow : .iBeam, cutting: taken)
    }

    override func resetCursorRects() {
        addPointerRects()
    }

    // The Cc and Bcc rows start hidden; AppKit does not ask again when they show.
    override func viewDidHide() {
        super.viewDidHide()
        pointerRegionsDidChange()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        pointerRegionsDidChange()
    }

    override func updateTrackingAreas() {
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
        super.updateTrackingAreas()
    }

    override func mouseMoved(with event: NSEvent) {
        field?.pointerMoved(to: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        field?.pointerMoved(to: nil)
    }

    override func mouseDown(with event: NSEvent) {
        guard let field else { return }
        let point = convert(event.locationInWindow, from: nil)
        if let hit = field.tokenRects().first(where: { $0.rect.contains(point) }) {
            if event.clickCount >= 2 {
                field.editToken(at: hit.index)
            } else {
                field.selectToken(hit.index)
                trackDrag(of: hit.index, rect: hit.rect, from: event)
            }
            return
        }
        if let more = field.moreRect(), more.insetBy(dx: -4, dy: -4).contains(point) {
            field.expandFromMore()
            return
        }
        field.focusInput()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let field else { return nil }
        let point = convert(event.locationInWindow, from: nil)
        guard let hit = field.tokenRects().first(where: { $0.rect.contains(point) }) else { return nil }
        return field.menu(forToken: hit.index)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let field else { return }
        let t = Quire.Layout.Token.self
        let radius = t.height / 2
        for item in field.tokenRects() {
            let look = field.look(for: item.index)
            let rect = item.rect
            QuireDraw.fill(rect, radius: radius, look.fill)
            if let edge = look.edge { QuireDraw.strokeInside(rect, radius: radius, width: 1, edge) }
            var textX = rect.minX + t.padX
            if let glyph = look.glyph {
                let glyphRect = NSRect(x: rect.minX + 6, y: rect.minY, width: t.invalidGlyph, height: rect.height)
                QuireSymbol.draw(Quire.Icon.warning, size: .custom(t.invalidGlyph), color: glyph, centredIn: glyphRect)
                textX = glyphRect.maxX + t.gap
            }
            let role = QuireFont.Role.body
            let string = QuireFont.attributedString(field.label(for: item.index), role: role, color: look.text)
            let lineTop = (rect.midY - role.lineHeight / 2).rounded()
            string.draw(with: NSRect(x: textX, y: lineTop, width: max(0, rect.maxX - t.padX - textX + 1), height: role.lineHeight),
                        options: QuireFont.drawingOptions, context: nil)
            if field.showsTokenRing, field.selectedIndex == item.index {
                QuireFocusRing.draw(around: rect, cornerRadius: radius, gap: QuireFocusRing.gapOnFill)
            }
        }
        if let more = field.moreRect() {
            let role = QuireFont.Role.body
            let string = QuireFont.attributedString(AddressTokenField.moreLabel(field.hiddenCount), role: role, color: .qInk2)
            string.draw(with: NSRect(x: more.minX, y: (more.midY - role.lineHeight / 2).rounded(), width: more.width + 1,
                                     height: role.lineHeight), options: QuireFont.drawingOptions, context: nil)
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func isAccessibilityElement() -> Bool { false }

    // MARK: Dragging tokens out

    /// A token dragged past a few points leaves as its formatted address; dropped on another recipient field
    /// it moves there, as `NSTokenField` tokens did.
    private func trackDrag(of index: Int, rect: NSRect, from mouseDown: NSEvent) {
        guard let window, let field, !field.isLocked else { return }
        let start = mouseDown.locationInWindow
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if next.type == .leftMouseUp { return }
            let moved = hypot(next.locationInWindow.x - start.x, next.locationInWindow.y - start.y)
            guard moved > 3 else { continue }
            let item = NSPasteboardItem()
            item.setString(field.formattedAddress(at: index), forType: .string)
            let dragging = NSDraggingItem(pasteboardWriter: item)
            dragging.setDraggingFrame(rect, contents: tokenImage(rect))
            draggedIndex = index
            beginDraggingSession(with: [dragging], event: mouseDown, source: self)
            return
        }
    }

    private var draggedIndex: Int?

    private func tokenImage(_ rect: NSRect) -> NSImage {
        let image = NSImage(size: rect.size)
        if let rep = bitmapImageRepForCachingDisplay(in: rect) {
            cacheDisplay(in: rect, to: rep)
            image.addRepresentation(rep)
        }
        return image
    }

    // MARK: Dropping

    /// Files dropped on a recipient row are attachments like anywhere else in the window: the composer content
    /// view takes them, since a view that registers for a drag type keeps it from its ancestors.
    private var fileDropTarget: ComposeContentView? {
        sequence(first: superview, next: { $0?.superview }).lazy.compactMap { $0 as? ComposeContentView }.first
    }

    private func carriesFiles(_ sender: NSDraggingInfo) -> Bool {
        sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        if let sender, carriesFiles(sender) { fileDropTarget?.draggingExited(sender) }
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        if carriesFiles(sender) { fileDropTarget?.draggingEnded(sender) }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if carriesFiles(sender) { return fileDropTarget?.draggingEntered(sender) ?? [] }
        guard let field, !field.isLocked, sender.draggingPasteboard.string(forType: .string) != nil else { return [] }
        return (sender.draggingSource as? TokenDocumentView).map { $0 === self ? [] : NSDragOperation.move } ?? .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggingEntered(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if carriesFiles(sender) { return fileDropTarget?.performDragOperation(sender) ?? false }
        guard let field, let text = sender.draggingPasteboard.string(forType: .string) else { return false }
        return field.acceptDroppedText(text)
    }
}

extension TokenDocumentView: NSDraggingSource {
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? [.move, .copy] : .copy
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        defer { draggedIndex = nil }
        guard operation == .move, let index = draggedIndex else { return }
        field?.removeToken(at: index)
    }
}

/// The text being typed after the tokens: borderless, `body`, an `accent` caret, no ring of its own (the row
/// draws the inset ring).
@MainActor
final class TokenInputField: NSTextField {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        isBezeled = false
        drawsBackground = false
        focusRingType = .none
        font = QuireFont.font(.body)
        textColor = .qInk
        lineBreakMode = .byClipping
        cell?.usesSingleLineMode = true
        cell?.isScrollable = true
        cell?.wraps = false
        setAccessibilityLabel("Recipients")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("TokenInputField is built in code")
    }

    /// Where the typed text starts, in this field's coordinates (the cell's text inset).
    var textStartX: CGFloat {
        let rect = cell?.drawingRect(forBounds: bounds) ?? bounds
        return rect.minX + 2
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted, let editor = currentEditor() as? NSTextView {
            editor.insertionPointColor = .qAccent
        }
        return accepted
    }
}
