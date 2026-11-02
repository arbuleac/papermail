import AppKit
@testable import SSDesign

/// Every AppKit component in every state, laid out like section D of the specimen, for visual checks
/// (`ComponentGalleryTests`, which writes PNGs only when asked).
@MainActor
enum ComponentGallery {
    static let width: CGFloat = 1180

    static func make() -> NSView {
        let root = SnapshotHost(frame: NSRect(x: 0, y: 0, width: width, height: 1800))
        var builder = Builder(root: root)

        builder.section("Buttons · rest · hover · pressed · focused · disabled · loading")
        for variant in QuireButton.Variant.allCases {
            builder.label(variant.rawValue)
            let title = variant == .link ? "Load images" : variant == .destructive ? "Discard" : variant == .primary ? "Send" : variant == .ghost ? "Cancel" : "Reconnect"
            for state in [QuireDisplayState.rest, .hover, .pressed, .focused] {
                builder.add(button(title, variant, state: state), width: 120)
            }
            let disabled = button(title, variant)
            disabled.isEnabled = false
            builder.add(disabled, width: 120)
            let loading = button(title, variant)
            loading.loadingTitle = variant == .destructive ? "Removing…" : variant == .primary ? "Sending…" : "Loading…"
            loading.isLoading = true
            builder.add(loading, width: 120)
            builder.newline()
        }
        builder.label("sizes")
        builder.add(button("Send", .primary, size: .small), width: 70)
        let symbol = button("Send", .primary)
        symbol.symbolName = Quire.Icon.send
        builder.add(symbol, width: 90)
        let large = button("Send", .primary, size: .large)
        large.symbolName = Quire.Icon.send
        builder.add(large, width: 110)
        builder.add(button("Reconnect", .secondary, size: .small), width: 100)
        builder.add(button("Add Gmail account", .secondary, size: .large), width: 180)
        let inactive = button("Send", .primary)
        inactive.windowKeyOverride = false
        builder.add(inactive, width: 70)
        let keyed = button("Send", .primary)
        keyed.symbolName = Quire.Icon.send
        keyed.keycap = "⌘↩"
        builder.add(keyed, width: 130)
        let reply = button("Reply", .ghost)
        reply.symbolName = Quire.Icon.reply
        reply.keycap = "R"
        reply.keycapGap = Quire.Layout.Reader.targetKeycapGap
        builder.add(reply, width: 110)
        builder.newline()

        builder.section("Icon buttons · rest · hover · pressed · focused · on · quiet on · disabled · loading · 22 / 24 / 28")
        builder.label("icon")
        for state in [QuireDisplayState.rest, .hover, .pressed, .focused] {
            let b = QuireIconButton(symbolName: Quire.Icon.archive)
            b.displayState = state
            b.windowKeyOverride = true
            builder.add(b, width: 44)
        }
        let star = QuireIconButton(symbolName: Quire.Icon.star)
        star.onSymbolName = Quire.Icon.unstar
        star.isOn = true
        builder.add(star, width: 44)
        let quiet = QuireIconButton(symbolName: Quire.Icon.format)
        quiet.onStyle = .quiet
        quiet.isOn = true
        builder.add(quiet, width: 44)
        let disabledIcon = QuireIconButton(symbolName: Quire.Icon.replyAll)
        disabledIcon.isEnabled = false
        builder.add(disabledIcon, width: 44)
        let loadingIcon = QuireIconButton(symbolName: Quire.Icon.archive)
        loadingIcon.isLoading = true
        builder.add(loadingIcon, width: 44)
        for size in QuireIconButton.Size.allCases {
            let b = QuireIconButton(symbolName: Quire.Icon.compose, size: size)
            b.displayState = .hover
            builder.add(b, width: 44)
        }
        builder.newline()

        builder.section("Badges · tags · keycaps")
        builder.label("badges")
        for kind in [QuireBadge.Kind.unread(3), .unread(21), .unread(128), .messageCount(2), .messageCount(14), .dot, .attention] {
            builder.add(QuireBadge(kind), width: 44)
        }
        let spineTile = SnapshotHost(frame: NSRect(x: 0, y: 0, width: 44, height: 28))
        spineTile.fill = .qSpine
        let cut = QuireBadge(.unread(7), cutoutColor: .qSpine)
        cut.setFrameOrigin(NSPoint(x: 8, y: 2))
        spineTile.addSubview(cut)
        builder.add(spineTile, width: 60)
        for tag in ["Other", "Gmail", "Microsoft 365"] { builder.add(QuireTag(tag), width: tag.count < 7 ? 50 : 100) }
        builder.newline()
        builder.label("keycaps")
        for legend in ["E", "#", "⌘↩", "⇧⌘R", "esc", "G", "J"] { builder.add(QuireKeycap(legend), width: 40) }
        builder.add(QuireKeycap("K", style: .large), width: 40)
        builder.add(QuireKeycap("/", style: .inField), width: 30)
        let slipKeys = SnapshotHost(frame: NSRect(x: 0, y: 0, width: 80, height: 26))
        slipKeys.fill = .qSlip
        let k1 = QuireKeycap("Z", style: .onSlip)
        k1.setFrameOrigin(NSPoint(x: 6, y: 4))
        let k2 = QuireKeycap("⌘Z", style: .onSlip)
        k2.isHighlighted = true
        k2.setFrameOrigin(NSPoint(x: 34, y: 4))
        slipKeys.addSubview(k1)
        slipKeys.addSubview(k2)
        builder.add(slipKeys, width: 90)
        builder.newline()

        builder.section("Progress · spinner 12 / 16 / 32 · bar · contrail · skeleton")
        builder.label("progress")
        for size in QuireSpinnerView.Size.allCases {
            let s = QuireSpinnerView(size: size)
            s.delay = 0
            s.startAnimation()
            builder.add(s, width: 44)
        }
        let bar = QuireProgressBar(mode: .determinate(0.6))
        bar.setFrameSize(NSSize(width: 160, height: 4))
        builder.add(bar, width: 180)
        let contrail = QuireContrailView(mode: .determinate(0.6))
        contrail.setFrameSize(NSSize(width: 160, height: 4))
        builder.add(contrail, width: 180)
        let reduced = QuireProgressBar(mode: .countdown(duration: 5, remaining: 2.5))
        reduced.isPaused = true
        reduced.setFrameSize(NSSize(width: 120, height: 4))
        builder.add(reduced, width: 140)
        builder.newline()
        builder.label("skeleton")
        let row = QuireSkeleton(.row(index: 0))
        row.setFrameSize(NSSize(width: 364, height: 68))
        builder.add(row, width: 380)
        let compact = QuireSkeleton(.compactRow(index: 1))
        compact.setFrameSize(NSSize(width: 364, height: 48))
        builder.add(compact, width: 380)
        let body = QuireSkeleton(.body)
        body.setFrameSize(NSSize(width: 200, height: QuireSkeleton.height(of: .body)!))
        builder.add(body, width: 220)
        builder.newline()
        builder.label("rules")
        let hair = QuireHairline()
        hair.setFrameSize(NSSize(width: 120, height: 1))
        builder.add(hair, width: 140)
        let ruleKey = QuireMarginRule(height: 36)
        ruleKey.windowKeyOverride = true
        builder.add(ruleKey, width: 20)
        let ruleIdle = QuireMarginRule(height: 36)
        ruleIdle.windowKeyOverride = false
        builder.add(ruleIdle, width: 20)
        builder.newline()

        builder.section("Empty states · banners")
        let zero = QuireEmptyStateView(sentence: "Nothing left to read.", hint: "New mail will land here.", glyph: .sparrow)
        zero.setFrameSize(NSSize(width: 300, height: 90))
        builder.add(zero, width: 320)
        let none = QuireEmptyStateView(sentence: "No conversation selected",
                                       hint: [.keys(["J", "K"]), .text("to move ·"), .keys(["↩"]), .text("to open")])
        none.setFrameSize(NSSize(width: 300, height: 70))
        builder.add(none, width: 320)
        let offline = QuireEmptyStateView(sentence: "You're offline", hint: "Mail will appear when you reconnect.", glyph: .offline)
        offline.setFrameSize(NSSize(width: 300, height: 90))
        builder.add(offline, width: 320)
        builder.newline()
        let banners: [(QuireBannerView.Kind, String, String?, String?)] = [
            (.neutral, "3 remote images hidden to protect your privacy.", Quire.Icon.loadImages, "Load images"),
            (.warning, "This message uses its own colours.", Quire.Icon.originalColors, nil),
            (.info, "Focused mirrors Gmail Primary.", nil, nil),
            (.success, "OAuth clients saved.", nil, nil),
            (.danger, "Couldn't load this message.", nil, "Retry"),
        ]
        for (index, spec) in banners.enumerated() {
            let banner = QuireBannerView(kind: spec.0, message: spec.1, symbolName: spec.2)
            if let action = spec.3 { banner.setAction(action) }
            if index == 1 { banner.setDismissible(true) }
            banner.setFrameSize(NSSize(width: 380, height: 32))
            builder.add(banner, width: 390)
            if index % 3 == 2 { builder.newline() }
        }
        let multi = QuireBannerView(kind: .danger, message: "Couldn't send: Microsoft 365 rejected the attachment size. The draft is kept on this Mac.")
        multi.allowsMultipleLines = true
        multi.setAction("Open draft")
        multi.setFrameSize(NSSize(width: 380, height: multi.height(forWidth: 380)))
        builder.add(multi, width: 390)
        builder.newline()

        builder.section("Sheet · slips")
        let sheet = QuireSheetView(frame: NSRect(x: 0, y: 0, width: 160, height: 60))
        builder.add(sheet, width: 180)
        let target = QuireSheetView(frame: NSRect(x: 0, y: 0, width: 160, height: 60))
        target.isTarget = true
        builder.add(target, width: 180)
        let focused = QuireSheetView(frame: NSRect(x: 0, y: 0, width: 160, height: 60))
        focused.isFocused = true
        builder.add(focused, width: 180)
        let toast = QuireSlipView(kind: .undoable, message: "Archived", symbolName: Quire.Icon.archive)
        toast.setAction("Undo", keycap: "Z")
        toast.setFrameSize(toast.intrinsicContentSize)
        toast.startLifetime(5)
        toast.lifetimeContrail.isPaused = true
        builder.add(toast, width: toast.frame.width + 20)
        builder.newline()
        let hovered = QuireSlipView(kind: .undoable, message: "Moved to Trash", symbolName: Quire.Icon.trash)
        hovered.setAction("Undo", keycap: "Z")?.displayState = .hover
        hovered.setFrameSize(hovered.intrinsicContentSize)
        builder.add(hovered, width: hovered.frame.width + 20)
        let confirm = QuireSlipView(kind: .confirmation, message: "Undid Archive")
        confirm.setFrameSize(confirm.intrinsicContentSize)
        builder.add(confirm, width: confirm.frame.width + 20)
        let error = QuireSlipView(kind: .error, message: "Couldn't archive. Restored.")
        error.setAction("Details")?.displayState = .focused
        error.setFrameSize(error.intrinsicContentSize)
        builder.add(error, width: error.frame.width + 20)
        builder.newline()

        builder.section("Text field · search")
        let field = QuireTextField(placeholder: "Client ID")
        builder.add(field, width: 230)
        let hoverField = QuireTextField(placeholder: "Hover")
        hoverField.displayState = .hover
        builder.add(hoverField, width: 230)
        let focusField = QuireTextField(placeholder: "Client ID")
        focusField.stringValue = "alex@contoso"
        focusField.displayState = .focused
        builder.add(focusField, width: 230)
        let disabledField = QuireTextField(placeholder: "Disabled")
        disabledField.isEnabled = false
        builder.add(disabledField, width: 230)
        builder.newline()
        let errorField = QuireTextField(placeholder: "Client ID")
        errorField.stringValue = "1084-ab3f.apps"
        errorField.errorMessage = "That doesn't look like a Google client ID."
        errorField.setFrameSize(errorField.frame(forAlignmentRect: NSRect(x: 0, y: 0, width: 220, height: errorField.intrinsicContentSize.height)).size)
        builder.add(errorField, width: 300, fit: false)
        let mono = QuireTextField()
        mono.isMonospaced = true
        mono.stringValue = "1084-ab3f.apps.googleusercontent.com"
        builder.add(mono, width: 230)
        builder.newline()
        let search = QuireSearchField()
        builder.add(search, width: 190)
        let hoverSearch = QuireSearchField()
        hoverSearch.displayState = .hover
        builder.add(hoverSearch, width: 190)
        let typing = QuireSearchField()
        typing.query = "lisbon flat"
        typing.resultCount = 38
        typing.displayState = .focused
        typing.setFrameSize(typing.frame(forAlignmentRect: NSRect(x: 0, y: 0, width: 250, height: 26)).size)
        builder.add(typing, width: 270, fit: false)
        let disabledSearch = QuireSearchField()
        disabledSearch.isEnabled = false
        builder.add(disabledSearch, width: 190)
        builder.newline()

        builder.section("Checkbox · radio · toggle · popup")
        builder.label("checkbox")
        let checks: [(NSControl.StateValue, QuireDisplayState?, Bool)] = [
            (.off, nil, true), (.on, nil, true), (.mixed, nil, true), (.off, .focused, true), (.on, .focused, true), (.off, nil, false),
            (.off, .hover, true), (.off, .pressed, true), (.on, .hover, true), (.on, .pressed, true),
        ]
        for spec in checks {
            let c = QuireCheckbox(state: spec.0)
            c.displayState = spec.1
            c.isEnabled = spec.2
            builder.add(c, width: 28)
        }
        builder.add(QuireCheckbox(title: "Show sender and subject", state: .on), width: 200)
        builder.newline()
        builder.label("radio")
        for spec in [(false, nil), (true, nil), (false, QuireDisplayState.focused), (true, .pressed), (false, .hover)] as [(Bool, QuireDisplayState?)] {
            let r = QuireRadioButton(isSelected: spec.0)
            r.displayState = spec.1
            builder.add(r, width: 28)
        }
        let disabledRadio = QuireRadioButton()
        disabledRadio.isEnabled = false
        builder.add(disabledRadio, width: 28)
        builder.add(QuireRadioGroupView(titles: ["Standard", "Compact"], selectedIndex: 0), width: 200)
        builder.newline()
        builder.label("toggle")
        for spec in [(false, nil), (true, nil), (false, QuireDisplayState.focused), (true, .focused), (false, .pressed), (true, .pressed)] as [(Bool, QuireDisplayState?)] {
            let t = QuireToggle(isOn: spec.0)
            t.displayState = spec.1
            builder.add(t, width: 44)
        }
        let disabledToggle = QuireToggle(isOn: true)
        disabledToggle.isEnabled = false
        builder.add(disabledToggle, width: 44)
        builder.add(QuireToggle(title: "New mail", isOn: true), width: 120)
        builder.newline()
        builder.label("popup")
        let popup = QuirePopUpButton(titles: ["5 seconds", "10 seconds", "20 seconds"])
        builder.add(popup, width: 120)
        for state in [QuireDisplayState.hover, .focused] {
            let p = QuirePopUpButton(titles: [state == .hover ? "Hover" : "Focused"])
            p.displayState = state
            builder.add(p, width: 100)
        }
        let disabledPopup = QuirePopUpButton(titles: ["Off"])
        disabledPopup.isEnabled = false
        builder.add(disabledPopup, width: 70)
        let from = QuirePopUpButton(titles: ["Alex Morgan <alex@contoso.test>"], isBorderless: true)
        from.inkMark = .dot(slot: 0)
        builder.add(from, width: 260)
        let fromPressed = QuirePopUpButton(titles: ["Alex Morgan"], isBorderless: true)
        fromPressed.inkMark = .dot(slot: 0)
        fromPressed.displayState = .pressed
        builder.add(fromPressed, width: 140)
        let swatch = QuirePopUpButton(titles: ["Persimmon"])
        swatch.inkMark = .swatch(slot: 0)
        swatch.displayState = .pressed
        builder.add(swatch, width: 140)
        builder.newline()

        builder.section("Tabs · avatars · scrim")
        let tabs = QuireUnderlineTabs(titles: ["All", "Focused", "Other"])
        tabs.windowKeyOverride = true
        builder.add(tabs, width: 170)
        let hoverTabs = QuireUnderlineTabs(titles: ["All", "Focused", "Other"])
        hoverTabs.windowKeyOverride = true
        hoverTabs.displayState = .hover
        builder.add(hoverTabs, width: 170)
        let focusTabs = QuireUnderlineTabs(titles: ["All", "Focused", "Other"], selectedIndex: 2)
        focusTabs.displayState = .focused
        builder.add(focusTabs, width: 170)
        let idleTabs = QuireUnderlineTabs(titles: ["All", "Focused", "Other"])
        idleTabs.windowKeyOverride = false
        builder.add(idleTabs, width: 170)
        let firstSync = QuireUnderlineTabs(titles: ["All", "Focused", "Other"])
        firstSync.isEnabled = false
        builder.add(firstSync, width: 170)
        let modes = QuireUnderlineTabs(items: [.init("Reply", symbolName: Quire.Icon.reply), .init("Reply all", symbolName: Quire.Icon.replyAll)],
                                       style: .replyMode)
        modes.windowKeyOverride = true
        builder.add(modes, width: 200)
        builder.newline()
        builder.label("avatars")
        builder.add(AvatarSample(diameter: 24, initials: "AM", address: "alex@contoso.test", ring: nil), width: 40)
        builder.add(AvatarSample(diameter: 30, initials: "PR", address: "priya@example.test", ring: nil), width: 46)
        builder.add(AvatarSample(diameter: 36, initials: "BC", address: "ben@contoso.test", ring: nil), width: 52)
        builder.add(AvatarSample(diameter: 30, initials: "PR", address: "priya@example.test", ring: 1), width: 46)
        builder.add(AvatarSample(diameter: 30, initials: "C", address: "", ring: 0, accountSlot: 0), width: 46)
        builder.add(AvatarSample(diameter: 30, initials: "Ga", address: "", ring: 4, accountSlot: 4), width: 46)
        builder.add(AvatarSample(diameter: 24, initials: "C", address: "", ring: 0, accountSlot: 0), width: 46)
        let scrimBox = SnapshotHost(frame: NSRect(x: 0, y: 0, width: 120, height: 40))
        scrimBox.fill = .qCanvas
        let behind = QuireButton(title: "Behind", variant: .primary)
        behind.setFrameOrigin(NSPoint(x: 8, y: 2))
        scrimBox.addSubview(behind)
        let scrim = QuireScrimView(frame: scrimBox.bounds)
        scrimBox.addSubview(scrim)
        builder.add(scrimBox, width: 140)
        builder.newline()

        root.setFrameSize(NSSize(width: width, height: builder.y + 16))
        return root
    }

    private static func button(_ title: String, _ variant: QuireButton.Variant, size: QuireButton.Size = .regular,
                               state: QuireDisplayState? = nil) -> QuireButton {
        let b = QuireButton(title: title, variant: variant, size: size)
        b.displayState = state
        b.windowKeyOverride = true
        return b
    }

    /// Lays samples out in rows; Quire controls are placed by their visual rect.
    @MainActor struct Builder {
        let root: NSView
        var x: CGFloat = 16
        var y: CGFloat = 12
        var rowHeight: CGFloat = 0

        init(root: NSView) { self.root = root }

        mutating func section(_ title: String) {
            if x > 16 { newline() }
            y += 10
            let text = NSTextField(labelWithString: title.uppercased())
            text.font = QuireFont.font(.runningHead)
            text.textColor = .qInk3
            text.sizeToFit()
            text.setFrameOrigin(NSPoint(x: 16, y: y))
            root.addSubview(text)
            y += 24
        }

        mutating func label(_ title: String) {
            let text = NSTextField(labelWithString: title)
            text.font = QuireFont.font(.meta)
            text.textColor = .qInk3
            text.sizeToFit()
            text.setFrameOrigin(NSPoint(x: 16, y: y + 6))
            root.addSubview(text)
            x = 100
        }

        mutating func add(_ view: NSView, width: CGFloat, fit: Bool = true) {
            if fit, let control = view as? QuireControl { control.sizeToFit() }
            reveal(view)
            let visual = view.alignmentRect(forFrame: view.frame)
            let origin = NSPoint(x: x, y: y)
            view.frame = view.frame(forAlignmentRect: NSRect(origin: origin, size: visual.size))
            root.addSubview(view)
            x += max(width, visual.width + 8)
            rowHeight = max(rowHeight, visual.height)
        }

        /// Shows loading spinners now instead of after their 150 ms delay.
        private func reveal(_ view: NSView) {
            let spinner = (view as? QuireButton)?.spinner ?? (view as? QuireIconButton)?.spinner ?? (view as? QuireBannerView)?.spinner
            guard let spinner, !spinner.isRevealed else { return }
            spinner.stopAnimation()
            spinner.delay = 0
            spinner.startAnimation()
        }

        mutating func newline() {
            y += max(rowHeight, 20) + 14
            x = 16
            rowHeight = 0
        }
    }
}

/// An avatar face (or account face) with an optional account ring, drawn the way a row will.
@MainActor
final class AvatarSample: NSView {
    let diameter: CGFloat
    let initials: String
    let address: String
    let ring: Int?
    let accountSlot: Int?

    init(diameter: CGFloat, initials: String, address: String, ring: Int?, accountSlot: Int? = nil) {
        self.diameter = diameter
        self.initials = initials
        self.address = address
        self.ring = ring
        self.accountSlot = accountSlot
        super.init(frame: NSRect(x: 0, y: 0, width: diameter + 8, height: diameter + 8))
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let face = NSRect(x: 4, y: 4, width: diameter, height: diameter)
        let appearance = NSAppearance.currentDrawing()
        let image: NSImage
        if let accountSlot {
            image = QuireAvatarRenderer.shared.accountFace(monogram: initials, slot: accountSlot, diameter: diameter, appearance: appearance)
        } else {
            image = QuireAvatarRenderer.shared.face(initials: initials, tint: QuireAvatarRenderer.tint(forAddress: address),
                                                    diameter: diameter, appearance: appearance)
        }
        image.draw(in: face, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        if let ring { QuireAvatarRenderer.drawRing(around: face, accountSlot: ring) }
    }
}
