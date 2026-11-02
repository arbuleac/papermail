import AppKit

/// The main window's chrome (spec §3.2, §5.1): the configuration that puts the traffic lights on the 52 pt
/// title-bar band, and the metrics the shell derives from where AppKit actually put them.
///
/// The empty unified toolbar is there only for its geometry: without a toolbar AppKit lays out the plain title
/// bar (lights near x 7–9, centre y 14–16) and every Quire metric above the horizon would be wrong. The lights
/// are never moved by hand; the rail width and the minimal-mode masthead are read from them instead, because
/// their horizontal extent differs between macOS releases (72 pt to the zoom button's end on macOS 15, 79 pt on
/// 26 and later, 73 pt for an app AppKit lays out in its compatibility appearance). `WindowChromeTests` builds a
/// window with exactly this configuration, so a release that moves the lights fails a test rather than drifting
/// by eye.
@MainActor
public enum QuireWindowChrome {
    /// The style the main window is created with.
    public nonisolated static let mainStyleMask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]

    /// The default content size, 1280 × 800.
    public nonisolated static let defaultSize = NSSize(width: Quire.Layout.Window.defaultWidth, height: Quire.Layout.Window.defaultHeight)

    /// The minimum content size, 960 × 600.
    public nonisolated static let minimumSize = NSSize(width: Quire.Layout.Window.minWidth, height: Quire.Layout.Window.minHeight)

    /// The macOS 15 metrics, used before a window exists to measure (a first layout pass, tests of the maths).
    public nonisolated static let fallbackMetrics = Metrics(lightsEnd: Quire.Layout.TrafficLights.endX,
                                                lightsCenterY: Quire.Layout.TrafficLights.centerY)

    // MARK: Configuring

    /// A main window of the default size with the §3.2 chrome, not yet on screen.
    public static func makeMainWindow(title: String) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: defaultSize), styleMask: mainStyleMask,
                              backing: .buffered, defer: false)
        configureMainWindow(window, title: title)
        return window
    }

    /// Applies the §3.2 chrome to `window`: transparent title bar with hidden title, the empty unified toolbar
    /// with no separator, and the minimum size. The title still names the window in the Window menu, Mission
    /// Control and VoiceOver (“SuperSparrow — Demo” in demo mode, §5.43).
    public static func configureMainWindow(_ window: NSWindow, title: String) {
        window.styleMask.formUnion(mainStyleMask)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = title
        let toolbar = NSToolbar(identifier: "main")
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        window.titlebarSeparatorStyle = .none
        window.contentMinSize = minimumSize
    }

    /// Applies the composer's chrome (§3.2): the same transparent title bar over `paper`, but with the title
    /// visible and no toolbar, so AppKit keeps the plain system title bar (28 pt on macOS 15, 32 pt from 26 on).
    /// The field rows start at `titlebarHeight(of:)`.
    public static func configureComposerWindow(_ window: NSWindow) {
        window.styleMask.formUnion(mainStyleMask)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .visible
        window.toolbar = nil
    }

    // MARK: Measuring

    /// Reads the lights where AppKit put them, converted to the content view and measured from its top-leading
    /// corner. Falls back to the macOS 15 values when the window has no content view or buttons yet.
    public static func metrics(of window: NSWindow) -> Metrics {
        guard let content = window.contentView,
              let close = window.standardWindowButton(.closeButton),
              let zoom = window.standardWindowButton(.zoomButton) else { return fallbackMetrics }
        let zoomRect = topLeading(zoom.convert(zoom.bounds, to: content), in: content)
        let closeRect = topLeading(close.convert(close.bounds, to: content), in: content)
        guard zoomRect.width > 0, closeRect.height > 0 else { return fallbackMetrics }
        return Metrics(lightsEnd: zoomRect.maxX, lightsCenterY: closeRect.midY)
    }

    /// `rect` in `view`'s coordinates, re-expressed with y measured down from the top.
    private static func topLeading(_ rect: NSRect, in view: NSView) -> NSRect {
        guard !view.isFlipped else { return rect }
        return NSRect(x: rect.minX, y: view.bounds.height - rect.maxY, width: rect.width, height: rect.height)
    }

    /// The rail width for lights ending at `lightsEnd`: the larger of 76 and the smallest even number at least
    /// `lightsEnd` + 4, so the lights always sit on the rail with 4 pt before its trailing hairline.
    public nonisolated static func railWidth(lightsEnd: CGFloat) -> CGFloat {
        let needed = lightsEnd + Quire.Layout.Rail.lightsClearance
        let even = (needed / 2).rounded(.up) * 2
        return max(Quire.Layout.Rail.width, even)
    }

    /// The height of a window's title-bar band as AppKit laid it out: the content view's height above
    /// `contentLayoutRect`. Composer windows start their field rows here (28 pt on macOS 15, 32 pt from 26 on);
    /// it is read, never assumed (§3.2).
    public static func titlebarHeight(of window: NSWindow) -> CGFloat {
        guard let content = window.contentView else { return 0 }
        let layout = content.convert(window.contentLayoutRect, from: nil)
        return max(0, content.isFlipped ? layout.minY : content.bounds.height - layout.maxY)
    }
}
