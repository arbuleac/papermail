#if DEBUG
import AppKit
import PaperDesign

/// The specimen's “Increased contrast” card: the same components with every token at its `lightHC` /
/// `darkHC` value and 3 pt focus rings, rendered off screen with Increase Contrast forced
/// (`DesignGalleryContrastView`) and shown as an image beside the normal page.
extension DesignGalleryCards {
    static func increasedContrast() -> NSView {
        let size = increasedContrastCard().frame.size
        return DesignGalleryContrastView(size: size) { increasedContrastCard() }
    }

    private static func increasedContrastCard() -> NSView {
        DesignGalleryCard("Increased contrast", code: "lightHC / darkHC",
                          caption: "The same components with every token at its increased-contrast value: sheets and slips "
                              + "gain stronger edges, focus rings grow to 3 pt. Rendered off screen with Increase Contrast forced, "
                              + "so it shows lightHC / darkHC whatever the bar says.",
                          span: 12) { block in
            block.labelWidth = 0
            let focused = S.button("Focused", .secondary, state: .focused)
            block.row(nil, [
                S.button("Send", .primary), S.button("Reconnect", .secondary), S.button("Cancel", .ghost),
                S.button("Discard", .destructive), focused, S.button("Load images", .link, state: .hover),
                QuireBadge(.unread(21)), QuireBadge(.messageCount(4)), QuireTag("Gmail"), QuireKeycap("⌘Z"),
            ])
            let field = S.sized(QuireTextField(placeholder: "Client ID"), NSSize(width: 220, height: Quire.Layout.TextField.height))
            let focusField = S.sized(QuireTextField(placeholder: "Client ID"), NSSize(width: 220, height: Quire.Layout.TextField.height))
            focusField.stringValue = "alex@contoso"
            focusField.displayState = .focused
            let tabs = QuireUnderlineTabs(items: [.init("Reply", symbolName: Quire.Icon.reply), .init("Reply all", symbolName: Quire.Icon.replyAll)])
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
    }
}
#endif
