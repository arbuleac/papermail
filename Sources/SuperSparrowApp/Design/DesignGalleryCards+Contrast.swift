import AppKit
import SSDesign

/// The specimen's “Increased contrast” card: the same components with every token at its `lightHC` /
/// `darkHC` value and 3 pt focus rings, drawn inside a container pinned to the high-contrast appearance.
extension DesignGalleryCards {
    static func increasedContrast() -> NSView {
        let card = DesignGalleryCard("Increased contrast", code: "lightHC / darkHC",
                                     caption: "The same components with every token at its increased-contrast value: sheets and slips "
                                         + "gain stronger edges, focus rings grow to 3 pt.",
                                     span: 12) { block in
            block.labelWidth = 0
            let focused = S.button("Focused", .secondary, state: .focused)
            block.row(nil, [
                S.button("Send", .primary), S.button("Reconnect", .secondary), S.button("Cancel", .ghost),
                S.button("Discard", .destructive), focused, S.button("Load images", .link, state: .hover),
                QuireBadge(.unread(21)), QuireBadge(.messageCount(4)), QuireTag("Other"), QuireKeycap("⌘Z"),
            ])
            let field = S.sized(QuireTextField(placeholder: "Client ID"), NSSize(width: 220, height: Quire.Layout.TextField.height))
            let focusField = S.sized(QuireTextField(placeholder: "Client ID"), NSSize(width: 220, height: Quire.Layout.TextField.height))
            focusField.stringValue = "alex@contoso"
            focusField.displayState = .focused
            let tabs = QuireUnderlineTabs(titles: ["All", "Focused", "Other"])
            block.row(nil, [
                field, focusField, QuireCheckbox(state: .on), QuireCheckbox(state: .off), QuireToggle(isOn: true), QuireToggle(isOn: false),
                QuireRadioButton(isSelected: true), tabs, S.forced(QuireSearchField(), .hover),
            ])
            let slip = QuireSlipView(kind: .undoable, message: "Archived", symbolName: Quire.Icon.archive)
            _ = slip.setAction("Undo", keycap: "Z")
            slip.setFrameSize(slip.intrinsicContentSize)
            slip.startLifetime(Quire.Motion.toastLife)
            slip.lifetimeContrail.mode = .countdown(duration: Quire.Motion.toastLife, remaining: Quire.Motion.toastLife * 0.6)
            slip.lifetimeContrail.isPaused = true
            let banner = QuireBannerView(kind: .danger, message: "Couldn't load this message.")
            _ = banner.setAction("Retry")
            banner.setFrameSize(NSSize(width: 300, height: Quire.Layout.Banner.height))
            let sheet = QuireSheetView(frame: NSRect(x: 0, y: 0, width: 200, height: 44))
            sheet.isTarget = true
            block.row(nil, [slip, banner, sheet, S.spinner(.medium)], gap: 16)
        }
        let container = DesignGalleryContrastView(frame: card.frame)
        card.autoresizingMask = [.width, .height]
        container.addSubview(card)
        return container
    }
}
