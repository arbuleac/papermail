#if DEBUG
import AppKit
import SSDesign
import os

/// Debug › Design Gallery: every SSDesign component in every state, AppKit cards then the hosted SwiftUI
/// Settings controls, on a scrolling page laid out like section D of the specimen. A bar above the page
/// forces the appearance and the Quire environment (Graphite, Increase Contrast, Reduce Motion, Reduce
/// Transparency) for this check; closing the window gives the environment back to the system.
///
/// `--gallery` opens it at launch; `--snapshot-gallery=<png>` renders the whole page with `renderSnapshot`.
@MainActor
final class DesignGalleryWindowController: NSWindowController, NSWindowDelegate {
    private static let log = Logger(subsystem: "io.supersparrow.mac", category: "design")

    private let scrollView = NSScrollView()
    private var documentView = DesignGalleryDocumentView()
    private let controls = DesignGalleryControlsBar()
    private let savedOverrides = QuireEnvironment.shared.overrides

    /// Called after the window closed and the environment is given back; the owner drops the controller.
    var onClose: (@MainActor () -> Void)?

    init() {
        let screen = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1440, height: 900)
        let size = NSSize(width: min(DesignGalleryStudio.pageWidth + 16, screen.width), height: min(960, screen.height))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "Design Gallery"
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.minSize = NSSize(width: 640, height: 400)
        super.init(window: window)
        window.delegate = self

        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = DesignGalleryStudio.background
        scrollView.documentView = documentView
        window.contentView = scrollView

        let accessory = NSTitlebarAccessoryViewController()
        accessory.view = controls
        accessory.layoutAttribute = .bottom
        window.addTitlebarAccessoryViewController(accessory)
        controls.onChange = { [weak self] in self?.applyControls() }

        window.initialFirstResponder = documentView
        window.center()
        window.setFrameAutosaveName("DesignGallery")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func show() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        scrollToTop()
    }

    func windowWillClose(_ notification: Notification) {
        // The overrides are app-wide; the gallery only borrows them. The forced appearance goes too, and the
        // owner starts a new controller next time, whose bar reads the restored state.
        QuireEnvironment.shared.setOverrides(savedOverrides)
        window?.appearance = nil
        onClose?()
    }

    private func scrollToTop() {
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func applyControls() {
        window?.appearance = controls.chosenAppearance
        QuireEnvironment.shared.setOverrides(controls.overrides)
        // Samples resolve layer colours and cached faces when the environment changes, but rebuilding the page
        // also re-measures text for the new contrast and keeps forced states exact.
        let origin = scrollView.contentView.bounds.origin
        documentView = DesignGalleryDocumentView()
        scrollView.documentView = documentView
        window?.makeFirstResponder(documentView)
        scrollView.contentView.scroll(to: origin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    // MARK: Snapshot

    /// Renders the whole page, top to bottom, in `appearance` (the app's when nil). The page is built in its
    /// own borderless window as tall as the page, ordered in far off screen: everything it shows is then in
    /// a visible window, so SwiftUI, spinners and layer content all draw. `settle` covers the spinners' and
    /// skeletons' reveal delays and SwiftUI's first layout passes.
    static func renderSnapshot(appearance: NSAppearance?, settle: TimeInterval = 0.8,
                               completion: @escaping @MainActor (NSBitmapImageRep?) -> Void) {
        let page = DesignGalleryDocumentView()
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -30_000, y: -30_000), size: page.frame.size),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = appearance ?? NSApp.effectiveAppearance
        let container = DesignGalleryFlippedView(frame: NSRect(origin: .zero, size: page.frame.size))
        container.addSubview(page)
        window.contentView = container
        window.setFrame(NSRect(origin: NSPoint(x: -30_000, y: -30_000), size: page.frame.size), display: false)
        window.initialFirstResponder = page
        window.makeFirstResponder(page)
        window.orderBack(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + settle) {
            MainActor.assumeIsolated {
                page.layoutSubtreeIfNeeded()
                page.displayIfNeeded()
                let bitmap = SnapshotRenderer.render(page)
                window.orderOut(nil)
                window.contentView = nil
                if bitmap == nil { log.error("gallery snapshot: nothing rendered") }
                completion(bitmap)
            }
        }
    }
}
#endif
