#if DEBUG
import AppKit
import SSDesign

/// Surfaces and feedback: the message sheet, slips and banners.
extension DesignGalleryCards {
    // MARK: Message sheet (§5.14)

    static func sheet() -> DesignGalleryCard {
        DesignGalleryCard("Message sheet", code: "layout.reader · sheet",
                          caption: "The open sheet lifts with e1. The target message (what R, A, F and Space act on) gains a "
                              + "ruleStrong edge while several messages are open; focus rings it outside a 2 pt desk gap.",
                          span: 4, surface: .canvas) { block in
            block.labelWidth = 0
            let size = NSSize(width: block.width - 12, height: 56)
            @MainActor func sheet(_ words: String, configure: (QuireSheetView) -> Void) -> QuireSheetView {
                let sheet = QuireSheetView(frame: NSRect(origin: .zero, size: size))
                configure(sheet)
                let text = DesignGalleryText(words, role: .snippet, color: .qInk2, maxWidth: size.width - 32)
                text.setFrameOrigin(NSPoint(x: 16, y: ((size.height - text.frame.height) / 2).rounded()))
                sheet.contentView.addSubview(text)
                return sheet
            }
            block.full(sheet("Open sheet: sheet fill, e1, 1 pt rule edge") { _ in }, x: 6)
            block.space(4)
            block.full(sheet("Target: ruleStrong edge") { $0.isTarget = true }, x: 6)
            block.space(4)
            block.full(sheet("Focused: ring outside a 2 pt desk gap") { $0.isFocused = true }, x: 6)
            block.space(4)
            let raised = sheet("Raised fill, e2, no edge") {
                $0.fillColor = .qRaised
                $0.elevation = Quire.Elevation.e2
                $0.showsEdge = false
            }
            block.full(raised, x: 6)
            block.note("rest · target · focused · e2 surface (menus, popovers)", top: 4, bottom: 0)
        }
    }

    // MARK: Feedback slips (§5.30–5.32)

    /// Views stacked top to bottom, `gap` apart, each placed by its visual rect, with an optional caption.
    static func stack(_ views: [NSView], gap: CGFloat, caption: String? = nil, captionWidth: CGFloat = 300) -> NSView {
        let column = DesignGalleryFlippedView(frame: .zero)
        var y: CGFloat = 0
        var width: CGFloat = 0
        for view in views {
            let visual = DesignGalleryBlock.visualSize(of: view)
            DesignGalleryBlock.place(view, visual: NSRect(origin: NSPoint(x: 0, y: y), size: visual), in: column)
            y += visual.height + gap
            width = max(width, visual.width)
        }
        if let caption {
            let text = DesignGalleryText(caption, maxWidth: captionWidth)
            text.setFrameOrigin(NSPoint(x: 0, y: y))
            column.addSubview(text)
            y = text.frame.maxY + gap
            width = max(width, text.frame.width)
        }
        column.setFrameSize(NSSize(width: width, height: max(0, y - gap)))
        return column
    }

    static func slips() -> DesignGalleryCard {
        DesignGalleryCard("Feedback slips", code: "slip · e2 / e3 · contrail",
                          caption: "The slip is dark in both appearances. The contrail is the one drawn element that means time is "
                              + "moving: it drains along the bottom edge over the undo window and pauses while the pointer rests on "
                              + "the toast. A hovered or pressed action draws its keycap legend in onSlip. An undo confirms itself "
                              + "with an action-less toast.",
                          span: 12, surface: .studio) { block in
            block.labelWidth = 0
            block.space(4)
            @MainActor func undoable(_ message: String, symbol: String, action: QuireDisplayState?, left: Double) -> QuireSlipView {
                let slip = QuireSlipView(kind: .undoable, message: message, symbolName: symbol)
                slip.setAction("Undo", keycap: "Z")?.displayState = action
                slip.setFrameSize(slip.intrinsicContentSize)
                slip.startLifetime(Quire.Motion.toastLife)
                // Frozen part-way through its life, as the specimen draws it, so the contrail shows.
                slip.lifetimeContrail.mode = .countdown(duration: Quire.Motion.toastLife, remaining: Quire.Motion.toastLife * left)
                slip.lifetimeContrail.isPaused = true
                return slip
            }
            let confirm = QuireSlipView(kind: .confirmation, message: "Undid Archive")
            confirm.setFrameSize(confirm.intrinsicContentSize)
            let error = QuireSlipView(kind: .error, message: "Couldn't archive. Restored.")
            error.setAction("Details")?.displayState = .focused
            error.setFrameSize(error.intrinsicContentSize)
            let toasts = stack([
                undoable("Archived", symbol: Quire.Icon.archive, action: nil, left: 0.55),
                undoable("Archived 3 conversations", symbol: Quire.Icon.archive, action: .hover, left: 0.42),
                undoable("Moved to Trash", symbol: Quire.Icon.trash, action: .pressed, left: 0.2),
                confirm, error,
            ], gap: 12, caption: "rest (contrail paused) · action hover · action pressed · undo confirmation (no action) · error, "
                + "action focused")

            let summary = "Re: Contoso rollout · to Ben Carter"
            @MainActor func counting(left: Double, action: QuireDisplayState? = nil, ownsUndoKey: Bool = true) -> QuireUndoPanelView {
                let panel = QuireUndoPanelView(summary: summary)
                panel.startCountdown(5, remaining: left)
                // Frozen, as the specimen draws it: a live panel never pauses (§5.31).
                panel.isCountdownPaused = true
                panel.ownsUndoKey = ownsUndoKey
                panel.actionButton?.displayState = action
                return panel
            }
            let panels = stack([
                counting(left: 3.9),
                counting(left: 2.9, action: .hover),
                QuireUndoPanelView(state: .sending, summary: summary),
                QuireUndoPanelView(state: .sent, summary: summary),
                QuireUndoPanelView(state: .undoTooLate, summary: summary),
                QuireUndoPanelView(state: .failed, summary: summary),
                counting(left: 1.9, ownsUndoKey: false),
            ], gap: 12, caption: "counting (Undo outlined at rest) · Undo hovered · sending · sent · undo too late · failed · "
                + "a newer toast took ⌘Z (keycap hidden)")

            let hud = stack([QuireSequenceHUDView()], gap: 12,
                            caption: "g-sequence HUD: appears 500 ms after G when no second key has come; the rows are the cheat "
                                + "sheet's “G then …” rows.", captionWidth: 240)
            // Top-aligned columns, as the specimen's grid aligns them: each column takes the tallest height,
            // its content staying at the top of its flipped frame.
            let columns = [toasts, panels, hud]
            let tallest = columns.map(\.frame.height).max() ?? 0
            for column in columns { column.setFrameSize(NSSize(width: column.frame.width, height: tallest)) }
            block.row(nil, columns, at: [0, 380, 720])
        }
    }

    // MARK: Cheat sheet overlay (§5.32)

    static func cheatSheet() -> DesignGalleryCard {
        DesignGalleryCard("Cheat sheet overlay", code: "layout.cheatSheet · cheatSheetContent · scrim",
                          caption: "An in-window overlay, not a system sheet: scrim over the window (scrimSolid, opaque, under Reduce "
                              + "Transparency), the panel centred with its top at 92 pt, focus trapped in it, single keys swallowed. "
                              + "Esc, ?, ⌘/, ⌘W, the close button or a click on the scrim dismisses it. 816 × 604 pt, drawn from "
                              + "cheatSheetContent; shown here in a 720 pt window, the height it fits whole.",
                          span: 12, surface: .studio) { block in
            block.labelWidth = 0
            let size = NSSize(width: block.width, height: Quire.Layout.CheatSheet.top + QuireCheatSheetPanel.naturalHeight()
                                  + Quire.Layout.CheatSheet.minMargin)
            let window = DesignGalleryFlippedView(frame: NSRect(origin: .zero, size: size))
            window.fill = .qPaper
            window.cornerRadius = 8
            // Something to dim: the list's first rows, as skeletons.
            for index in 0..<8 {
                let row = QuireSkeleton(.row(index: index))
                row.frame = NSRect(x: 0, y: CGFloat(index) * Quire.Layout.Row.height + 8, width: 364, height: Quire.Layout.Row.height)
                row.reveal(after: 0)
                window.addSubview(row)
            }
            let overlay = QuireCheatSheetOverlay(frame: window.bounds)
            overlay.autoresizingMask = [.width, .height]
            window.addSubview(overlay)
            block.full(window)
        }
    }

    // MARK: Banners (§5.16, §5.38)

    static func banners() -> DesignGalleryCard {
        DesignGalleryCard("Banners", code: "layout.banner",
                          caption: "Privacy is not a warning: the remote-images banner is neutral. Semantic banners always pair "
                              + "colour with a glyph and words.",
                          span: 5, surface: .sheet) { block in
            block.labelWidth = 0
            let width = block.width
            @MainActor func banner(_ kind: QuireBannerView.Kind, _ message: String, symbol: String? = nil, action: String? = nil,
                        actionState: QuireDisplayState? = nil, configure: (QuireBannerView) -> Void = { _ in }) -> QuireBannerView {
                let banner = QuireBannerView(kind: kind, message: message, symbolName: symbol)
                if let action { banner.setAction(action)?.displayState = actionState }
                configure(banner)
                banner.setFrameSize(NSSize(width: width, height: banner.height(forWidth: width)))
                return banner
            }
            block.rowGap = 8
            block.full(banner(.neutral, "3 remote images hidden to protect your privacy.", symbol: Quire.Icon.loadImages, action: "Load images"))
            block.full(banner(.neutral, "Link hover: underline, no wash", symbol: Quire.Icon.loadImages, action: "Load images", actionState: .hover))
            block.full(banner(.neutral, "Link pressed: ink2, underline, no wash", symbol: Quire.Icon.loadImages, action: "Load images",
                              actionState: .pressed))
            block.full(banner(.neutral, "Link focused: ring", symbol: Quire.Icon.loadImages, action: "Load images", actionState: .focused))
            block.full(banner(.neutral, "Loading 3 images…") { $0.isLoading = true })
            block.full(banner(.neutral, "2 images couldn't load.", symbol: Quire.Icon.warning) { $0.glyphColor = .qWarning })
            block.full(banner(.warning, "This message uses its own colours.", symbol: Quire.Icon.originalColors) { _ = $0.setDismissible(true) })
            block.full(banner(.info, "Focused mirrors Gmail Primary."))
            block.full(banner(.success, "OAuth clients saved."))
            block.full(banner(.danger, "Couldn't load this message.", action: "Retry"))
            block.full(banner(.danger, "Couldn't send: Microsoft 365 rejected the attachment size. The draft is kept on this Mac, "
                              + "so nothing is lost.", action: "Open draft") { $0.allowsMultipleLines = true })
            block.note("neutral · link hover · link pressed · link focused · loading · partial failure · warning, dismissible · "
                       + "info · success · danger · multi-line", top: 0, bottom: 0)
        }
    }
}
#endif
