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

    // MARK: Feedback slips (§5.30)

    static func slips() -> DesignGalleryCard {
        DesignGalleryCard("Feedback slips", code: "slip · e2 / e3 · contrail",
                          caption: "The slip is dark in both appearances. The contrail drains along the bottom edge over the undo "
                              + "window and pauses while the pointer rests on the toast. A hovered or pressed action draws its "
                              + "keycap legend in onSlip.",
                          span: 4, surface: .studio) { block in
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
            block.full(undoable("Archived", symbol: Quire.Icon.archive, action: nil, left: 0.55), x: 6)
            block.full(undoable("Archived 3 conversations", symbol: Quire.Icon.archive, action: .hover, left: 0.42), x: 6)
            block.full(undoable("Moved to Trash", symbol: Quire.Icon.trash, action: .pressed, left: 0.2), x: 6)

            let confirm = QuireSlipView(kind: .confirmation, message: "Undid Archive")
            confirm.setFrameSize(confirm.intrinsicContentSize)
            block.full(confirm, x: 6)

            let error = QuireSlipView(kind: .error, message: "Couldn't archive. Restored.")
            error.setAction("Details")?.displayState = .focused
            error.setFrameSize(error.intrinsicContentSize)
            block.full(error, x: 6)

            let panel = QuireSlipActionButton(title: "Undo", keycap: "⌘Z")
            panel.showsRestingOutline = true
            panel.sizeToFit()
            block.row(nil, [S.surface(.qSlip, size: NSSize(width: 120, height: 40), radius: 8, centring: panel)],
                      ann: "undo-panel action: resting onSlipEdge outline")
            block.note("rest (contrail paused) · action hover · action pressed · undo confirmation (no action) · error, action focused",
                       top: 0, bottom: 0)
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
            block.full(banner(.neutral, "2 images couldn't load.", symbol: Quire.Icon.warning))
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
