import AppKit
import SSDesign

/// Small builders the gallery cards share.
@MainActor
enum DesignGallerySamples {
    /// A control in a forced state. Its size is left alone: states never change a control's size, and some
    /// samples are stretched to a column first.
    @discardableResult
    static func forced<T: QuireControl>(_ control: T, _ state: QuireDisplayState?, enabled: Bool = true) -> T {
        control.displayState = state
        control.isEnabled = enabled
        return control
    }

    static func button(_ title: String, _ variant: QuireButton.Variant, size: QuireButton.Size = .regular,
                       state: QuireDisplayState? = nil, symbol: String? = nil) -> QuireButton {
        let button = QuireButton(title: title, variant: variant, size: size, symbolName: symbol)
        button.sizeToFit()
        return forced(button, state)
    }

    /// A Quire control whose visual rect is exactly `size` (fields, search, popups stretched to a column).
    @discardableResult
    static func sized<T: NSView>(_ view: T, _ size: NSSize) -> T {
        view.setFrameSize(view.frame(forAlignmentRect: NSRect(origin: .zero, size: size)).size)
        return view
    }

    /// A patch of surface with samples on it, for components that only read right on their own surface
    /// (a cut-out badge on the rail's `spine`, keycaps on a slip, counts on the selection wash).
    static func surface(_ fill: NSColor, size: NSSize, radius: CGFloat = 6, _ samples: [(NSView, NSPoint)]) -> NSView {
        let tile = DesignGalleryFlippedView(frame: NSRect(origin: .zero, size: size))
        tile.fill = fill
        tile.cornerRadius = radius
        for (sample, origin) in samples {
            let visual = sample.alignmentRect(forFrame: sample.frame)
            sample.frame = sample.frame(forAlignmentRect: NSRect(origin: origin, size: visual.size))
            tile.addSubview(sample)
        }
        return tile
    }

    /// Centres one sample on a surface patch.
    static func surface(_ fill: NSColor, size: NSSize, radius: CGFloat = 6, centring sample: NSView) -> NSView {
        let visual = sample.alignmentRect(forFrame: sample.frame).size
        let origin = NSPoint(x: ((size.width - visual.width) / 2).rounded(), y: ((size.height - visual.height) / 2).rounded())
        return surface(fill, size: size, radius: radius, [(sample, origin)])
    }

    /// Spinners wait 150 ms before they show; a gallery shows them at once.
    static func spinner(_ size: QuireSpinnerView.Size, color: NSColor = .qInk3) -> QuireSpinnerView {
        let spinner = QuireSpinnerView(size: size, color: color)
        spinner.delay = 0
        spinner.startAnimation()
        return spinner
    }

    /// Pins every Quire control under `view` to the key-window look unless a sample asked for another, so a
    /// snapshot taken while the window is not key (or off screen) still shows rest states as they are.
    static func pinKeyWindow(in view: NSView) {
        if let control = view as? QuireControl, control.windowKeyOverride == nil { control.windowKeyOverride = true }
        if let rule = view as? QuireMarginRule, rule.windowKeyOverride == nil { rule.windowKeyOverride = true }
        if let sheet = view as? QuireSheetView, sheet.windowKeyOverride == nil { sheet.windowKeyOverride = true }
        for subview in view.subviews { pinKeyWindow(in: subview) }
    }
}
