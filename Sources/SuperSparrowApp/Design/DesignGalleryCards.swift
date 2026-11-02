#if DEBUG
import AppKit
import SSDesign

/// The AppKit cards of the gallery, one per specimen card of section D that SSDesign has a component for.
/// Copy (titles, captions, sample words) follows the specimen so the two read side by side; every state a
/// sample shows is forced (`displayState`, `isEnabled`, `windowKeyOverride`) and named in its row or caption.
@MainActor
enum DesignGalleryCards {
    typealias S = DesignGallerySamples

    // MARK: Buttons (§5.24)

    static func buttons() -> DesignGalleryCard {
        DesignGalleryCard("Buttons", code: "layout.button",
                          caption: "One primary per window. Destructive is never the default. Hit rect ≥ 24 × 24 pt even when the "
                              + "visual is smaller. On accent fills the focus ring sits outside a 2 pt gap.",
                          span: 7) { block in
            // `.bmx`: a 76 pt label column, columns as wide as their widest sample, 10 / 6 pt gaps.
            block.labelWidth = 76
            block.labelGap = 6
            let states: [QuireDisplayState?] = [nil, .hover, .pressed, .focused]
            let variants: [(String, QuireButton.Variant, String, String?)] = [
                ("Primary", .primary, "Send", "Sending…"), ("Secondary", .secondary, "Reconnect", "Loading…"),
                ("Ghost", .ghost, "Cancel", "Cancel"), ("Destructive", .destructive, "Discard", "Removing…"),
                ("Link", .link, "Load images", nil),
            ]
            var rows: [(String, [NSView])] = variants.map { name, variant, title, loading in
                var cells: [NSView] = states.map { S.button(title, variant, state: $0) }
                let disabled = S.button(title, variant)
                disabled.isEnabled = false
                cells.append(disabled)
                if let loading {
                    let busy = S.button(title, variant)
                    busy.loadingTitle = loading
                    busy.isLoading = true
                    busy.sizeToFit()
                    cells.append(busy)
                }
                return (name, cells)
            }
            var icons: [NSView] = states.map { S.forced(QuireIconButton(symbolName: Quire.Icon.archive, accessibilityLabel: "Archive"), $0) }
            icons.append(S.forced(QuireIconButton(symbolName: Quire.Icon.archive, accessibilityLabel: "Archive"), nil, enabled: false))
            let loadingIcon = QuireIconButton(symbolName: Quire.Icon.archive, accessibilityLabel: "Archive")
            loadingIcon.isLoading = true
            icons.append(loadingIcon)
            rows.append(("Icon", icons))

            let xs = DesignGalleryBlock.columns(rows.map { $0.1 }, gap: 6)
            block.heads(["Rest", "Hover", "Pressed", "Focused", "Disabled", "Loading"], at: xs)
            for (name, cells) in rows { block.row(name, cells, at: xs) }

            block.labelWidth = 0
            block.note("Sizes: small 22 · regular 28 · large 36 · inactive window (primary draws as secondary)", top: 2)
            let inactive = S.button("Send", .primary)
            inactive.windowKeyOverride = false
            block.row(nil, [
                S.button("Send", .primary, size: .small),
                S.button("Send", .primary, symbol: Quire.Icon.send),
                S.button("Send", .primary, size: .large, symbol: Quire.Icon.send),
                S.button("Reconnect", .secondary, size: .small),
                S.button("Add Gmail account", .secondary, size: .large),
                inactive,
            ])

            block.note("Keycaps · icon on states · icon sizes 22 / 24 / 28 (hover)", top: 2)
            let send = S.button("Send", .primary, symbol: Quire.Icon.send)
            send.keycap = "⌘↩"
            send.sizeToFit()
            let reply = S.button("Reply", .ghost, symbol: Quire.Icon.reply)
            reply.keycap = "R"
            reply.keycapGap = Quire.Layout.Reader.targetKeycapGap
            reply.sizeToFit()
            let star = QuireIconButton(symbolName: Quire.Icon.star, accessibilityLabel: "Star")
            star.onSymbolName = Quire.Icon.unstar
            star.isOn = true
            let quiet = QuireIconButton(symbolName: Quire.Icon.format, accessibilityLabel: "Format")
            quiet.onStyle = .quiet
            quiet.isOn = true
            let sizes: [NSView] = QuireIconButton.Size.allCases.map {
                S.forced(QuireIconButton(symbolName: Quire.Icon.compose, size: $0, accessibilityLabel: "Compose"), .hover)
            }
            block.row(nil, [send, reply, star, quiet] + sizes, ann: "star on · quiet on")
        }
    }

    // MARK: Text field, toggles, popup (§5.25–5.27)

    static func fields() -> DesignGalleryCard {
        DesignGalleryCard("Text field, toggles, popup", code: "layout.textField · toggle · popup",
                          caption: "Every state-bearing edge is ruleStrong (≥ 3:1). Focus is the 2 pt ring (3 pt in increased "
                              + "contrast), never a 1 pt colour change.",
                          span: 5, surface: .sheet) { block in
            // `.c5 .st`: 76 pt labels, two equal columns 14 pt apart.
            block.labelWidth = 76
            let column = ((block.contentWidth - 14) / 2).rounded(.down)
            let xs: [CGFloat] = [0, column + 14]
            let fieldSize = NSSize(width: column, height: Quire.Layout.TextField.height)

            let hover = S.forced(S.sized(QuireTextField(placeholder: "Hover"), fieldSize), .hover)
            block.row("Text field", [S.sized(QuireTextField(placeholder: "Client ID"), fieldSize), hover], at: xs)
            let focused = S.sized(QuireTextField(placeholder: "Client ID"), fieldSize)
            focused.stringValue = "alex@contoso"
            focused.displayState = .focused
            let disabled = S.sized(QuireTextField(placeholder: "Disabled"), fieldSize)
            disabled.stringValue = "Disabled"
            disabled.isEnabled = false
            block.row("", [focused, disabled], at: xs)

            let error = QuireTextField(placeholder: "Client ID")
            error.stringValue = "1084-ab3f.apps"
            error.errorMessage = "That doesn't look like a Google client ID."
            S.sized(error, fieldSize)
            S.sized(error, NSSize(width: column, height: error.intrinsicContentSize.height))
            let mono = S.sized(QuireTextField(), fieldSize)
            mono.isMonospaced = true
            mono.stringValue = "1084-ab3f.apps.googleusercontent.com"
            block.row("Error", [error, mono], at: xs)

            @MainActor func secure(_ state: QuireDisplayState?, revealed: Bool = false) -> QuireTextField {
                let field = S.sized(QuireTextField(placeholder: "Client secret", isSecure: true), fieldSize)
                field.isMonospaced = true
                field.stringValue = "GOCSPX-k2v9f3Qm"
                field.isRevealed = revealed
                field.displayState = state
                return field
            }
            block.row("Secure", [secure(nil), secure(.hover)], at: xs)
            block.row("", [secure(.hover, revealed: true)], at: xs, ann: "rest · hover (reveal) · revealed", annWidth: column)
            let disabledEmpty = S.sized(QuireTextField(placeholder: "Disabled placeholder"), fieldSize)
            disabledEmpty.isEnabled = false
            block.row("", [disabledEmpty], at: xs)

            @MainActor func check(_ state: NSControl.StateValue, _ display: QuireDisplayState? = nil, enabled: Bool = true) -> NSView {
                S.forced(QuireCheckbox(state: state), display, enabled: enabled)
            }
            block.row("Checkbox", [check(.off), check(.on), check(.mixed), check(.off, .focused), check(.on, .focused),
                                   check(.off, enabled: false)],
                      ann: "off · on · mixed · focused · on + focused · disabled")
            block.row("", [check(.off, .hover), check(.off, .pressed), check(.on, .hover), check(.on, .pressed),
                           S.forced(QuireRadioButton(isSelected: true), .pressed)],
                      ann: "off hover · off pressed · on hover · on pressed (controlOnPressed) · radio on pressed")
            block.row("Radio", [S.forced(QuireRadioButton(), nil), S.forced(QuireRadioButton(isSelected: true), nil),
                                S.forced(QuireRadioButton(), .focused), S.forced(QuireRadioButton(), nil, enabled: false)],
                      ann: "off · on · focused · disabled")
            block.row("", [QuireRadioGroupView(titles: ["Standard", "Compact"], selectedIndex: 0)], ann: "group: one Tab stop, arrows move")

            @MainActor func toggle(_ on: Bool, _ display: QuireDisplayState? = nil, enabled: Bool = true) -> NSView {
                S.forced(QuireToggle(isOn: on), display, enabled: enabled)
            }
            block.row("Toggle", [toggle(false), toggle(true), toggle(false, .focused), toggle(true, .focused), toggle(false, enabled: false)],
                      ann: "off · on · focused · on + focused · disabled")
            block.row("", [toggle(false, .pressed), toggle(true, .pressed)],
                      ann: "off pressed · on pressed: the knob stretches to 18 pt; no wash on the track or the knob")
            block.row("", [QuireToggle(title: "New mail", isOn: true), QuireCheckbox(title: "Show sender and subject", state: .on)],
                      ann: "labels: body ink, 8 pt from the control")

            block.row("Popup", [
                QuirePopUpButton(titles: ["5 seconds", "10 seconds", "20 seconds"]),
                S.forced(QuirePopUpButton(titles: ["Hover"]), .hover),
                S.forced(QuirePopUpButton(titles: ["Focused"]), .focused),
                S.forced(QuirePopUpButton(titles: ["Off"]), nil, enabled: false),
            ])
            let from = QuirePopUpButton(titles: ["Alex Morgan <alex@contoso.test>"], isBorderless: true)
            from.inkMark = .dot(slot: 0)
            from.sizeToFit()
            block.row("Borderless", [from], ann: "composer From: no edge until hover")
            let fromPressed = QuirePopUpButton(titles: ["Alex Morgan"], isBorderless: true)
            fromPressed.inkMark = .dot(slot: 0)
            fromPressed.sizeToFit()
            let swatch = QuirePopUpButton(titles: ["Persimmon"])
            swatch.inkMark = .swatch(slot: 0)
            swatch.sizeToFit()
            block.row("Pressed", [S.forced(fromPressed, .pressed), S.forced(swatch, .pressed)],
                      ann: "the dot and swatch keep a 2 pt raised halo")
        }
    }

    // MARK: List header, tabs, search (§5.5, §5.6)

    /// Tabs in their 40 pt header row, over the header's bottom hairline: the selected underline overlaps it.
    static func onHeader(_ tabs: QuireUnderlineTabs, width: CGFloat) -> NSView {
        let height = tabs.alignmentRect(forFrame: tabs.frame).height
        let row = DesignGalleryFlippedView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        let rule = QuireHairline()
        rule.frame = NSRect(x: 0, y: height - 1, width: width, height: 1)
        row.addSubview(rule)
        let visual = tabs.alignmentRect(forFrame: tabs.frame)
        tabs.frame = tabs.frame(forAlignmentRect: NSRect(origin: .zero, size: visual.size))
        row.addSubview(tabs)
        return row
    }

    static func listHeader() -> DesignGalleryCard {
        DesignGalleryCard("List header, tabs, search", code: "layout.listHeader",
                          caption: "Tabs carry state with weight and a 2 pt underline (≥ 3:1). Search has a resting 1 pt "
                              + "ruleStrong edge.",
                          span: 4) { block in
            let titles = ["All", "Focused", "Other"]
            let hover = QuireUnderlineTabs(titles: titles)
            hover.displayStateIndex = 1
            S.forced(hover, .hover)
            block.row("Tabs", [onHeader(hover, width: block.contentWidth)], caption: "All selected · Focused hover", captionGap: 4)
            let focus = QuireUnderlineTabs(titles: titles)
            focus.displayStateIndex = 2
            S.forced(focus, .focused)
            block.row("Focused", [onHeader(focus, width: block.contentWidth)], caption: "Other focused", captionGap: 4)
            let idle = QuireUnderlineTabs(items: [.init("All"), .init("Focused", isEnabled: false), .init("Other", isEnabled: false)])
            idle.windowKeyOverride = false
            block.row("Not key / first sync", [onHeader(idle, width: block.contentWidth)])
            let modes = QuireUnderlineTabs(items: [.init("Reply", symbolName: Quire.Icon.reply),
                                                   .init("Reply all", symbolName: Quire.Icon.replyAll)], style: .replyMode)
            block.row("Reply mode", [modes])

            block.row("Search rest", [QuireSearchField()])
            block.row("Hover", [S.forced(QuireSearchField(), .hover)])
            let typing = QuireSearchField()
            typing.query = "lisbon flat"
            typing.resultCount = 38
            typing.displayState = .focused
            S.sized(typing, NSSize(width: 250, height: Quire.Layout.ListHeader.searchHeight))
            block.row("Focused, typing", [typing])
            let searching = QuireSearchField()
            searching.query = "lisbon"
            searching.isSearching = true
            searching.displayState = .focused
            S.sized(searching, NSSize(width: 250, height: Quire.Layout.ListHeader.searchHeight))
            block.row("Searching", [searching])
            block.row("Disabled", [S.forced(QuireSearchField(), nil, enabled: false)])
        }
    }
}
#endif
