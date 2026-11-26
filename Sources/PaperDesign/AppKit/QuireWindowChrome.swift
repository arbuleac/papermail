import AppKit

/// The main window's chrome (spec §3.2, §5.1): the configuration that puts the traffic lights on the 52 pt
/// title-bar band, and the metrics the shell derives from where AppKit actually put them.
///
/// The empty unified toolbar is there only for its geometry: without a toolbar AppKit lays out the plain title
/// bar (lights near x 7–9, centre y 14–16) and every Quire metric above the horizon would be wrong. The lights
/// are never moved by hand; the rail width and the minimal-mode masthead are read from them instead, because
/// their horizontal extent differs between macOS releases (the lights run from 20 to 72 pt on macOS 15 and in the
/// compatibility appearance AppKit gives an app linked against that SDK, whose button frames reach 19 and 73; from
/// 19 to 79 pt on 26 and later). The rail is as wide as the lights' leading inset mirrored past their end, so its
/// tiles sit under the lights' centre. `WindowChromeTests` builds a
/// window with exactly this configuration, so a release that moves the lights fails a test rather than drifting
/// by eye.
@MainActor
public enum QuireWindowChrome {
    /// The style the main window is created with.
    public nonisolated static let mainStyleMask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]

    /// The default content size, 1304 × 800: room for the day column beside a reader that keeps its keycaps (§3.2).
    public nonisolated static let defaultSize = NSSize(width: Quire.Layout.Window.defaultWidth, height: Quire.Layout.Window.defaultHeight)

    /// The minimum content size, 960 × 600.
    public nonisolated static let minimumSize = NSSize(width: Quire.Layout.Window.minWidth, height: Quire.Layout.Window.minHeight)

    /// The macOS 15 metrics, used before a window exists to measure (a first layout pass, tests of the maths).
    public nonisolated static let fallbackMetrics = Metrics(lightsStart: Quire.Layout.TrafficLights.originX,
                                                            lightsEnd: Quire.Layout.TrafficLights.endX,
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
    /// Control and VoiceOver (“Paper — Demo” in demo mode, §5.43).
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

    /// A reader window's default content size, 840 × 800: the reader pane of a default main window (§5.49).
    public nonisolated static let readerWindowDefaultSize = NSSize(width: Quire.Layout.ReaderWindow.defaultWidth,
                                                                   height: Quire.Layout.ReaderWindow.defaultHeight)

    /// A reader window's minimum content size, 520 × 420.
    public nonisolated static let readerWindowMinimumSize = NSSize(width: Quire.Layout.ReaderWindow.minWidth,
                                                                   height: Quire.Layout.ReaderWindow.minHeight)

    /// Applies a reader window's chrome (§3.2, §5.49): the main window's, empty unified toolbar included, because the
    /// reader header it holds puts its kicker and actions on the lights' centre line, which only that band provides;
    /// only the minimum differs. The title (the conversation's subject) names the window where the band hides it.
    public static func configureReaderWindow(_ window: NSWindow, title: String) {
        configureMainWindow(window, title: title)
        window.contentMinSize = readerWindowMinimumSize
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
        guard zoomRect.width > 0, closeRect.width > 0, closeRect.height > 0 else { return fallbackMetrics }
        // The lights, not their buttons: in the compatibility appearance (an app linked against the macOS 15 SDK)
        // each 12 pt light sits in a 14 pt frame, and the frames' ends would widen the rail for lights that run
        // from 20 to 72.
        let drawnStart = drawnLeadingEdge(of: close).map { closeRect.minX + $0 } ?? closeRect.minX
        let drawnEnd = drawnTrailingEdge(of: zoom).map { zoomRect.minX + $0 } ?? zoomRect.maxX
        return Metrics(lightsStart: max(closeRect.minX, drawnStart), lightsEnd: min(zoomRect.maxX, drawnEnd),
                       lightsCenterY: closeRect.midY)
    }

    /// How far from its leading edge `view` paints, in points: the trailing edge of its last column with any
    /// real coverage. Nil when nothing is painted (a window not drawn yet), so the caller keeps the frame.
    public static func drawnTrailingEdge(of view: NSView) -> CGFloat? {
        drawnColumns(of: view)?.upperBound
    }

    /// Where `view` starts to paint, in points from its leading edge: the leading edge of its first column with
    /// any real coverage. Nil when nothing is painted, as for `drawnTrailingEdge(of:)`.
    public static func drawnLeadingEdge(of view: NSView) -> CGFloat? {
        drawnColumns(of: view)?.lowerBound
    }

    /// The columns `view` paints, in points from its leading edge.
    private static func drawnColumns(of view: NSView) -> ClosedRange<CGFloat>? {
        guard view.bounds.width > 0, view.bounds.height > 0, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / view.bounds.width
        func paints(_ x: Int) -> Bool {
            (0..<rep.pixelsHigh).contains { (rep.colorAt(x: x, y: $0)?.alphaComponent ?? 0) > 0.1 }
        }
        guard let last = stride(from: rep.pixelsWide - 1, through: 0, by: -1).first(where: paints),
              let first = (0...last).first(where: paints) else { return nil }
        return (CGFloat(first) / scale)...(CGFloat(last + 1) / scale)
    }

    /// `rect` in `view`'s coordinates, re-expressed with y measured down from the top.
    private static func topLeading(_ rect: NSRect, in view: NSView) -> NSRect {
        guard !view.isFlipped else { return rect }
        return NSRect(x: rect.minX, y: view.bounds.height - rect.maxY, width: rect.width, height: rect.height)
    }

    /// The rail's width for lights drawn from `lightsStart` to `lightsEnd` (§3.2): the lights' leading inset mirrored
    /// past their end, so the rail's centre is the lights' centre and the tiles, centred on the rail, sit under
    /// them. Rounded up to an even number, so the tiles centre on whole points, and never under 76.
    public nonisolated static func railWidth(lightsStart: CGFloat, lightsEnd: CGFloat) -> CGFloat {
        let even = ((lightsStart + lightsEnd) / 2).rounded(.up) * 2
        return max(Quire.Layout.Rail.minWidth, even)
    }

    /// The first x that is clear of lights ending at `lightsEnd`: the larger of 76 and the smallest even number at
    /// least `lightsEnd` + 4. What stands in the title-bar zone beside the lights counts from it (the masthead of a
    /// window without its rail, a reader window's kicker). It was the rail's width until the rail took the lights'
    /// centre (Quire 1.20), and did not move then.
    public nonisolated static func lightsClearX(lightsEnd: CGFloat) -> CGFloat {
        let needed = lightsEnd + Quire.Layout.Rail.lightsClearance
        let even = (needed / 2).rounded(.up) * 2
        return max(Quire.Layout.TrafficLights.clearX, even)
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
