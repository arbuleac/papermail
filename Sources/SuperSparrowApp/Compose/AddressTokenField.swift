import AppKit
import SSCore

/// Recipient field. Tokens are `EmailAddress` values; completions come from the store's contact table,
/// looked up off the main thread after an 80 ms pause in typing so a fast typist never waits on SQLite.
@MainActor
final class AddressTokenField: NSTokenField, NSTokenFieldDelegate, NSViewToolTipOwner {
    typealias SuggestionProvider = @Sendable (_ prefix: String, _ limit: Int) throws -> [EmailAddress]

    /// Usually `store.suggestAddresses(prefix:limit:)`.
    var suggestionProvider: SuggestionProvider?
    var onChange: (() -> Void)?

    var addresses: [EmailAddress] {
        get { Self.addresses(in: objectValue) }
        set {
            objectValue = newValue
            invalidateIntrinsicContentSize()
        }
    }

    private(set) var showsInvalidOutline = false {
        didSet { needsDisplay = true }
    }

    private struct CompletionCache {
        var prefix: String
        var results: [EmailAddress]
    }

    private var completionCache: CompletionCache?
    private var requestedPrefix = ""
    private var lookupTask: Task<Void, Never>?
    private var toolTipTag: NSView.ToolTipTag?
    private var lastLayoutWidth: CGFloat = 0

    private static let suggestionLimit = 8
    private static let debounce = Duration.milliseconds(80)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        delegate = self
        tokenStyle = .rounded
        tokenizingCharacterSet = CharacterSet(charactersIn: ",;\n")
        isBezeled = false
        drawsBackground = false
        focusRingType = .none
        font = NSFont.systemFont(ofSize: 13)
        lineBreakMode = .byWordWrapping
        cell?.wraps = true
        cell?.isScrollable = false
        cell?.usesSingleLineMode = false
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.defaultHigh, for: .vertical)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("AddressTokenField is built in code")
    }

    deinit {
        lookupTask?.cancel()
    }

    // MARK: Validation

    /// Commits any text still being typed, flags invalid entries and reports whether sending may proceed.
    @discardableResult
    func validateForSend(requireRecipient: Bool = false) -> Bool {
        validateEditing()
        let current = addresses
        let invalid = AddressListParser.invalidEntries(in: current)
        let valid = invalid.isEmpty && (!requireRecipient || !current.isEmpty)
        showsInvalidOutline = !valid
        return valid
    }

    func clearValidation() {
        showsInvalidOutline = false
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard showsInvalidOutline else { return }
        NSColor.systemRed.setStroke()
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.75, dy: 0.75), xRadius: 4, yRadius: 4)
        path.lineWidth = 1.5
        path.stroke()
    }

    // MARK: Layout

    override func layout() {
        super.layout()
        // Wrapping fields only report a multi-line intrinsic height once they know their width.
        if abs(bounds.width - lastLayoutWidth) > 0.5 {
            lastLayoutWidth = bounds.width
            preferredMaxLayoutWidth = bounds.width
            invalidateIntrinsicContentSize()
        }
        if let toolTipTag { removeToolTip(toolTipTag) }
        toolTipTag = addToolTip(bounds, owner: self, userData: nil)
    }

    override var intrinsicContentSize: NSSize {
        var size = super.intrinsicContentSize
        size.height = max(size.height, 22)
        return size
    }

    // MARK: Completions

    func tokenField(_ tokenField: NSTokenField, completionsForSubstring substring: String, indexOfToken tokenIndex: Int, indexOfSelectedItem selectedIndex: UnsafeMutablePointer<Int>?) -> [Any]? {
        let prefix = substring.trimmingCharacters(in: .whitespaces)
        guard !prefix.isEmpty else { return nil }
        selectedIndex?.pointee = 0
        if let cache = completionCache, cache.prefix == prefix {
            return completionStrings(cache.results)
        }
        scheduleLookup(prefix)
        // Narrow the previous results while the lookup is pending so the menu does not blink.
        if let cache = completionCache, prefix.hasPrefix(cache.prefix) {
            let needle = prefix.lowercased()
            let narrowed = cache.results.filter {
                $0.address.lowercased().hasPrefix(needle) || ($0.name ?? "").lowercased().contains(needle)
            }
            return completionStrings(narrowed)
        }
        return nil
    }

    private func completionStrings(_ results: [EmailAddress]) -> [Any]? {
        let taken = Set(addresses.map { $0.address.lowercased() })
        let strings = results
            .filter { !taken.contains($0.address.lowercased()) }
            .map(QuotedReply.displayString)
        return strings.isEmpty ? nil : strings
    }

    private func scheduleLookup(_ prefix: String) {
        lookupTask?.cancel()
        requestedPrefix = prefix
        guard let provider = suggestionProvider else { return }
        lookupTask = Task { [weak self] in
            try? await Task.sleep(for: Self.debounce)
            guard !Task.isCancelled else { return }
            let limit = Self.suggestionLimit
            let results = await Task.detached(priority: .userInitiated) {
                (try? provider(prefix, limit)) ?? []
            }.value
            guard !Task.isCancelled, let self, self.requestedPrefix == prefix else { return }
            self.completionCache = CompletionCache(prefix: prefix, results: results)
            guard !results.isEmpty, let editor = self.currentEditor() as? NSTextView else { return }
            // Re-ask for completions now that there are some to show.
            editor.complete(nil)
        }
    }

    // MARK: Tokens

    func tokenField(_ tokenField: NSTokenField, representedObjectForEditing editingString: String) -> Any? {
        AddressListParser.parseEntry(editingString) ?? editingString
    }

    func tokenField(_ tokenField: NSTokenField, displayStringForRepresentedObject representedObject: Any) -> String? {
        guard let address = representedObject as? EmailAddress else { return representedObject as? String }
        if let name = address.name, !name.isEmpty { return name }
        return address.address
    }

    func tokenField(_ tokenField: NSTokenField, editingStringForRepresentedObject representedObject: Any) -> String? {
        guard let address = representedObject as? EmailAddress else { return representedObject as? String }
        return QuotedReply.displayString(address)
    }

    func tokenField(_ tokenField: NSTokenField, shouldAdd tokens: [Any], at index: Int) -> [Any] {
        let added = tokens.compactMap { token -> EmailAddress? in
            if let address = token as? EmailAddress { return address.address.isEmpty ? nil : address }
            if let string = token as? String { return AddressListParser.parseEntry(string) }
            return nil
        }
        DispatchQueue.main.async { [weak self] in
            self?.invalidateIntrinsicContentSize()
            self?.onChange?()
        }
        return added
    }

    func tokenField(_ tokenField: NSTokenField, styleForRepresentedObject representedObject: Any) -> NSTokenField.TokenStyle {
        if let address = representedObject as? EmailAddress, !AddressListParser.isValid(address.address) {
            return .squared
        }
        return .rounded
    }

    func tokenField(_ tokenField: NSTokenField, hasMenuForRepresentedObject representedObject: Any) -> Bool {
        representedObject is EmailAddress
    }

    func tokenField(_ tokenField: NSTokenField, menuForRepresentedObject representedObject: Any) -> NSMenu? {
        guard let address = representedObject as? EmailAddress else { return nil }
        let menu = NSMenu()
        let copy = NSMenuItem(title: address.address, action: #selector(copyAddress(_:)), keyEquivalent: "")
        copy.target = self
        copy.representedObject = address.address
        menu.addItem(copy)
        menu.addItem(.separator())
        let remove = NSMenuItem(title: "Remove", action: #selector(removeToken(_:)), keyEquivalent: "")
        remove.target = self
        remove.representedObject = address
        menu.addItem(remove)
        return menu
    }

    @objc private func copyAddress(_ sender: NSMenuItem) {
        guard let address = sender.representedObject as? String else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(address, forType: .string)
    }

    @objc private func removeToken(_ sender: NSMenuItem) {
        guard let address = sender.representedObject as? EmailAddress else { return }
        addresses = addresses.filter { $0 != address }
        onChange?()
    }

    // MARK: Pasteboard

    func tokenField(_ tokenField: NSTokenField, readFrom pboard: NSPasteboard) -> [Any]? {
        guard let string = pboard.string(forType: .string) else { return nil }
        let parsed = AddressListParser.parse(string)
        return parsed.isEmpty ? nil : parsed
    }

    func tokenField(_ tokenField: NSTokenField, writeRepresentedObjects objects: [Any], to pboard: NSPasteboard) -> Bool {
        let text = objects.compactMap { ($0 as? EmailAddress).map(QuotedReply.displayString) }.joined(separator: ", ")
        pboard.clearContents()
        pboard.setString(text, forType: .string)
        return true
    }

    // MARK: Editing notifications

    func controlTextDidChange(_ obj: Notification) {
        showsInvalidOutline = false
        invalidateIntrinsicContentSize()
        onChange?()
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        lookupTask?.cancel()
        invalidateIntrinsicContentSize()
        onChange?()
    }

    // MARK: Tooltips

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        guard let address = token(at: point) else { return "" }
        return address.address
    }

    private func token(at point: NSPoint) -> EmailAddress? {
        let objects = addresses
        guard !objects.isEmpty else { return nil }
        if let editor = currentEditor() as? NSTextView, let layoutManager = editor.layoutManager,
           let container = editor.textContainer, let storage = editor.textStorage {
            var local = convert(point, to: editor)
            local.x -= editor.textContainerOrigin.x
            local.y -= editor.textContainerOrigin.y
            return Self.token(at: local, layoutManager: layoutManager, container: container, string: storage.string, objects: objects)
        }
        // Not editing: lay the cell's attributed value out the way the cell draws it.
        let titleRect = cell?.titleRect(forBounds: bounds) ?? bounds
        let storage = NSTextStorage(attributedString: attributedStringValue)
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: titleRect.width, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)
        let local = NSPoint(x: point.x - titleRect.minX, y: isFlipped ? point.y - titleRect.minY : titleRect.maxY - point.y)
        return Self.token(at: local, layoutManager: layoutManager, container: container, string: storage.string, objects: objects)
    }

    private static func token(at point: NSPoint, layoutManager: NSLayoutManager, container: NSTextContainer, string: String, objects: [EmailAddress]) -> EmailAddress? {
        let glyphCount = layoutManager.numberOfGlyphs
        guard glyphCount > 0 else { return nil }
        let glyph = layoutManager.glyphIndex(for: point, in: container, fractionOfDistanceThroughGlyph: nil)
        guard glyph < glyphCount, layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container).contains(point) else {
            return nil
        }
        let character = layoutManager.characterIndexForGlyph(at: glyph)
        let text = string as NSString
        guard character < text.length, text.character(at: character) == 0xFFFC else { return nil }
        var ordinal = 0
        for index in 0..<character where text.character(at: index) == 0xFFFC { ordinal += 1 }
        return ordinal < objects.count ? objects[ordinal] : nil
    }

    // MARK: Helpers

    private static func addresses(in objectValue: Any?) -> [EmailAddress] {
        guard let items = objectValue as? [Any] else { return [] }
        return items.compactMap { item in
            if let address = item as? EmailAddress { return address }
            if let string = item as? String { return AddressListParser.parseEntry(string) }
            return nil
        }
    }
}
