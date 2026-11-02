import AppKit
import XCTest
@testable import SSDesign

/// State that must survive motion, reuse, window changes and VoiceOver: the regressions found in review of the
/// foundation (finishAll inside groups, superseded completions, avatar scale, sticky hover, accessibility
/// notifications, field truncation, sheet focus, the sweep's snapshot position, banner glyphs, secure fields
/// and the increased-contrast render).
@MainActor
final class ComponentStateTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        QuireTestEnvironment.forceDefaults()
    }

    override func tearDown() async throws {
        QuireAccessibility.observer = nil
        Quire.Motion.finishAll()
        QuireTestEnvironment.reset()
        try await super.tearDown()
    }

    private func hostWindow(_ size: NSSize = NSSize(width: 400, height: 200)) -> (NSWindow, NSView) {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = QuireFlippedView(frame: NSRect(origin: .zero, size: size))
        host.wantsLayer = true
        window.contentView = host
        return (window, host)
    }

    // MARK: Motion

    func testFinishAllLeavesSpinnersAndCountdownsInsideAGroupRunning() {
        let (window, host) = hostWindow()
        let parent = QuireFlippedView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
        parent.wantsLayer = true
        host.addSubview(parent)
        let spinner = QuireSpinnerView(size: .small)
        spinner.delay = 0
        spinner.frame = NSRect(x: 10, y: 10, width: 12, height: 12)
        parent.addSubview(spinner)
        spinner.startAnimation()
        let contrail = QuireContrailView(mode: .countdown(10))
        contrail.frame = NSRect(x: 0, y: 40, width: 200, height: 4)
        parent.addSubview(contrail)
        // AppKit builds the layer tree of nested layer-backed views once the window is on screen and the run
        // loop turns; only then is the spinner's layer inside the container's, as in the app.
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        XCTAssertTrue(spinner.layer?.superlayer === parent.layer, "the spinner's layer is in the container's tree")
        contrail.layoutSubtreeIfNeeded()
        XCTAssertTrue(spinner.isTurning)
        XCTAssertTrue(contrail.isMoving)
        // A group still running over the container, as `run(participants:)` registers one while its frame
        // animates (off screen AppKit may end the group at once, so it is registered directly here).
        let move = CABasicAnimation(keyPath: "position.y")
        move.fromValue = 0
        move.toValue = 20
        move.duration = 10
        parent.layer?.add(move, forKey: "position")
        let group = GroupAnimation(participants: [parent], completion: nil)
        Quire.Motion.register(group)
        Quire.Motion.finishAll()
        XCTAssertTrue(group.isDone)
        XCTAssertNil(parent.layer?.animation(forKey: "position"), "the group's own animation is finished")
        XCTAssertTrue(spinner.isTurning, "a keystroke never stops a spinner, even inside an animated container")
        XCTAssertTrue(contrail.isMoving, "the countdown keeps draining instead of snapping to its empty model value")
        XCTAssertGreaterThan(contrail.countdownRemaining ?? 0, 9)
        _ = window
    }

    func testASupersededAnimationSkipsItsCompletion() {
        let layer = CALayer()
        var first = false
        var second = false
        Quire.Motion.animate(layer, keyPath: "opacity", to: Float(0), duration: Quire.Motion.slow, curve: .leave, reduced: .keep) { first = true }
        Quire.Motion.animate(layer, keyPath: "opacity", to: Float(1), duration: Quire.Motion.slow, curve: .settle, reduced: .keep) { second = true }
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        XCTAssertFalse(first, "the fade-out was replaced: its remove-from-superview must not run")
        XCTAssertEqual(layer.opacity, 1)
        Quire.Motion.finishAll()
        XCTAssertTrue(second, "finishAll still finishes the newer one")
        XCTAssertFalse(first)
    }

    // MARK: Avatars

    func testFaceCacheKeepsOneFacePerScale() {
        let renderer = QuireAvatarRenderer()
        let aqua = NSAppearance(named: .aqua)!
        let one = renderer.face(initials: "AB", tint: .slate, diameter: 30, appearance: aqua, scale: 1)
        let two = renderer.face(initials: "AB", tint: .slate, diameter: 30, appearance: aqua, scale: 2)
        XCTAssertEqual(one.cgImage(forProposedRect: nil, context: nil, hints: nil)?.width, 30)
        XCTAssertEqual(two.cgImage(forProposedRect: nil, context: nil, hints: nil)?.width, 60, "a 2× row never gets the 1× face")
        XCTAssertNotEqual(QuireAvatarRenderer.cacheKey(initials: "AB", tint: .slate, diameter: 30, appearance: aqua, scale: 1),
                          QuireAvatarRenderer.cacheKey(initials: "AB", tint: .slate, diameter: 30, appearance: aqua, scale: 2))
        XCTAssertTrue(renderer.cachedFace(initials: "AB", tint: .slate, diameter: 30, appearance: aqua, scale: 1) === one)
    }

    // MARK: Hover and press

    func testHoverAndPressNeverStickAcrossRemoval() {
        let (window, host) = hostWindow()
        let button = QuireButton(title: "Archive", variant: .secondary)
        host.addSubview(button)
        button.setHovered(true)
        XCTAssertEqual(button.interactionState, .hover)
        button.removeFromSuperview()
        host.addSubview(button)
        XCTAssertFalse(button.isHovered, "a reused control comes back at rest")
        XCTAssertEqual(button.interactionState, .rest)
        button.setHovered(true)
        button.isHidden = true
        XCTAssertFalse(button.isHovered, "hiding clears hover too")
        _ = window
    }

    // MARK: Accessibility

    func testStateChangesAreAnnounced() {
        var posted: [NSAccessibility.Notification] = []
        QuireAccessibility.observer = { notification, _ in posted.append(notification) }
        QuireCheckbox(state: .off).state = .on
        QuireRadioButton().isSelected = true
        let toggle = QuireToggle(isOn: false)
        toggle.isOn = true
        let star = QuireIconButton(symbolName: Quire.Icon.star, accessibilityLabel: "Star")
        star.togglesOnClick = true
        star.performClick(nil)
        XCTAssertEqual(posted, Array(repeating: .valueChanged, count: 4))
        let plain = QuireIconButton(symbolName: Quire.Icon.archive, accessibilityLabel: "Archive")
        plain.isOn = true
        XCTAssertEqual(posted.count, 4, "a button that does not toggle has no value to announce")
    }

    func testFieldErrorsReachVoiceOver() {
        var spoken: [String] = []
        QuireAccessibility.observer = { _, text in if let text { spoken.append(text) } }
        let field = QuireTextField(placeholder: "Client ID")
        field.errorMessage = "That doesn't look like a Google client ID."
        XCTAssertEqual(field.textField.accessibilityHelp(), "That doesn't look like a Google client ID.")
        XCTAssertEqual(spoken, ["That doesn't look like a Google client ID."])
        field.errorMessage = nil
        XCTAssertNil(field.textField.accessibilityHelp())
    }

    func testSlipAnnouncesItselfAndItsKey() {
        let slip = QuireSlipView(kind: .undoable, message: "Archived", symbolName: Quire.Icon.archive)
        slip.setAction("Undo", keycap: "Z")
        XCTAssertEqual(slip.announcement, "Archived. Press Z to undo.")
        let confirm = QuireSlipView(kind: .confirmation, message: "Undid Archive")
        XCTAssertEqual(confirm.announcement, "Undid Archive.")
        var spoken: [String] = []
        QuireAccessibility.observer = { _, text in if let text { spoken.append(text) } }
        slip.announce()
        XCTAssertEqual(spoken, ["Archived. Press Z to undo."])
        XCTAssertEqual(QuireAccessibility.spoken(keycap: "⇧⌘R"), "Shift-Command-R")
    }

    func testToastActionsJoinTheTabLoopOnlyWithFullKeyboardAccess() {
        let slip = QuireSlipView(kind: .undoable, message: "Archived")
        let action = slip.setAction("Undo", keycap: "Z")
        XCTAssertEqual(action?.requiresFullKeyboardAccess, true, "Z undoes from anywhere; Tab skips the toast (§5.30)")
        let panel = QuireUndoPanelView(summary: "Re: Lunch")
        XCTAssertEqual(panel.actionButton?.requiresFullKeyboardAccess, false, "the undo panel's action is an ordinary Tab stop (§5.31)")
    }

    func testSearchFieldNamesItsResults() {
        let search = QuireSearchField()
        search.query = "lisbon"
        search.resultCount = 38
        XCTAssertEqual(search.resultsText, "38 results")
        search.resultCount = 1
        XCTAssertEqual(search.resultsText, "1 result")
        var spoken: [String] = []
        QuireAccessibility.observer = { _, text in if let text { spoken.append(text) } }
        search.announceResults()
        XCTAssertEqual(spoken, ["1 result"])
    }

    // MARK: Fields

    func testLongValuesTruncateAtRestAndScrollWhileEditing() {
        let (window, host) = hostWindow()
        let field = QuireTextField()
        field.isMonospaced = true
        field.stringValue = "1084-ab3f.apps.googleusercontent.com"
        field.setFrameSize(field.frame(forAlignmentRect: NSRect(x: 0, y: 0, width: 160, height: 28)).size)
        host.addSubview(field)
        let cell = field.textField.cell!
        XCTAssertFalse(cell.isScrollable, "a scrollable cell never truncates")
        XCTAssertEqual(field.textField.lineBreakMode, .byTruncatingTail)
        window.makeKeyAndOrderFront(nil)
        XCTAssertTrue(window.makeFirstResponder(field.textField))
        XCTAssertTrue(cell.isScrollable, "the caret reaches the end while editing")
        window.makeFirstResponder(nil)
        XCTAssertFalse(cell.isScrollable)
        window.orderOut(nil)
    }

    func testSecureFieldShowsBulletsAndARevealButtonOnHover() {
        let (window, host) = hostWindow()
        let delegate = FieldDelegate()
        let field = QuireTextField(placeholder: "Client secret", isSecure: true)
        field.isMonospaced = true
        field.setFrameSize(field.frame(forAlignmentRect: NSRect(x: 0, y: 0, width: 240, height: 28)).size)
        field.stringValue = "GOCSPX-k2v9"
        field.textField.delegate = delegate
        host.addSubview(field)
        XCTAssertTrue(field.textField is NSSecureTextField)
        XCTAssertEqual(field.revealButton?.isHidden, true, "the reveal button shows only on hover")
        let bullets = QuireSecureTextFieldCell.bullets(for: field.stringValue, font: field.textField.font, color: nil)
        XCTAssertEqual(bullets.string, String(repeating: "•", count: 11))
        XCTAssertEqual(bullets.attribute(.kern, at: 0, effectiveRange: nil) as? CGFloat, Quire.Layout.TextField.secureTracking)
        field.setHovered(true)
        XCTAssertEqual(field.revealButton?.isHidden, false)
        XCTAssertEqual(field.revealButton?.symbolName, Quire.Icon.reveal)
        field.layoutSubtreeIfNeeded()
        let buttonVisual = field.revealButton!.alignmentRect(forFrame: field.revealButton!.frame)
        XCTAssertLessThanOrEqual(field.textField.frame.maxX, buttonVisual.minX, "the text keeps clear of the button")
        XCTAssertEqual(buttonVisual.midY, field.faceRect.midY, accuracy: 0.5, "centred in the field's height")
        field.revealButton?.performClick(nil)
        XCTAssertTrue(field.isRevealed)
        XCTAssertFalse(field.textField is NSSecureTextField, "revealed, the text shows")
        XCTAssertEqual(field.stringValue, "GOCSPX-k2v9", "the text carries over")
        XCTAssertTrue(field.textField.delegate === delegate, "so does the delegate")
        XCTAssertEqual(field.revealButton?.symbolName, Quire.Icon.conceal)
        field.setHovered(false)
        XCTAssertEqual(field.revealButton?.isHidden, false, "while revealed the button stays, so the text can be hidden again")
        field.isRevealed = false
        XCTAssertTrue(field.textField is NSSecureTextField)
        XCTAssertEqual(field.revealButton?.isHidden, true)
        field.isSecure = false
        XCTAssertNil(field.revealButton)
        _ = window
    }

    private final class FieldDelegate: NSObject, NSTextFieldDelegate {}

    // MARK: Surfaces and marks

    func testSheetFocusRingNeedsAKeyWindow() {
        let sheet = QuireSheetView(frame: NSRect(x: 0, y: 0, width: 200, height: 60))
        sheet.isFocused = true
        XCTAssertFalse(sheet.showsFocusRing, "no first responder is drawn in a window that is not key (§3.4)")
        XCTAssertFalse(sheet.surface.isRingShown)
        sheet.windowKeyOverride = true
        XCTAssertTrue(sheet.surface.isRingShown)
        sheet.windowKeyOverride = false
        XCTAssertFalse(sheet.surface.isRingShown)
    }

    func testIndeterminateContrailRestsMidSweepForSnapshots() {
        let contrail = QuireContrailView(mode: .indeterminate)
        contrail.frame = NSRect(x: 0, y: 0, width: 200, height: 4)
        contrail.layoutSubtreeIfNeeded()
        let segment = 200 * Quire.Layout.Progress.indeterminateSegment
        XCTAssertEqual(contrail.sweepModelFrame.width, segment, accuracy: 0.01)
        XCTAssertEqual(contrail.sweepModelFrame.minX, (200 - segment) / 2, accuracy: 0.01, "the model, which snapshots draw, is in view")
    }

    func testPartialFailureBannerDrawsItsGlyphInWarning() {
        for mode in [QuireMode.light, .dark] {
            let banner = QuireBannerView(kind: .neutral, message: "2 images couldn't load.", symbolName: Quire.Icon.warning)
            banner.glyphColor = .qWarning
            banner.setFrameSize(NSSize(width: 300, height: Quire.Layout.Banner.height))
            let snapshot = ComponentSnapshot.render(banner, mode: mode, surface: .qSheet)
            let b = Quire.Layout.Banner.self
            // Look for the warning ink inside the glyph box.
            let box = NSRect(x: b.padLeft, y: (b.height - b.glyph) / 2, width: b.glyph, height: b.glyph)
            let warning = expected("warning", mode: mode)
            var found = false
            for x in stride(from: box.minX, to: box.maxX, by: 0.5) {
                for y in stride(from: box.minY, to: box.maxY, by: 0.5) where snapshot.matches(warning, at: NSPoint(x: x, y: y), tolerance: 6) {
                    found = true
                }
            }
            XCTAssertTrue(found, "\(mode): the triangle is warning, the wash stays fill")
            XCTAssertTrue(snapshot.matches(expected("sheet", "fill", mode: mode), at: NSPoint(x: 280, y: 4)), "\(mode) fill wash")
        }
    }

    // MARK: Row drawing

    /// Rows draw badges, tags and symbols in their own `draw(_:)` with the same code the views use (§8.2).
    func testStaticDrawingMatchesTheViews() {
        for kind in [QuireBadge.Kind.unread(3), .unread(120), .messageCount(4), .dot, .attention] {
            XCTAssertEqual(QuireBadge.size(for: kind), QuireBadge(kind).intrinsicContentSize, "\(kind)")
        }
        XCTAssertEqual(QuireBadge.size(for: .messageCount(4)).height, Quire.Layout.Badge.height)
        XCTAssertEqual(QuireTag.size(for: "Other"), QuireTag("Other").intrinsicContentSize)
        let first = QuireSymbol.cachedImage(Quire.Icon.attach, size: .row)
        XCTAssertNotNil(first)
        XCTAssertTrue(first === QuireSymbol.cachedImage(Quire.Icon.attach, size: .row), "one configured image per name and size")

        // A row-like view drawing a count badge and a tag statically renders the same pixels as the views.
        final class Row: NSView {
            override var isFlipped: Bool { true }
            override func draw(_ dirtyRect: NSRect) {
                NSColor.qPaper.setFill()
                bounds.fill()
                QuireBadge.draw(.messageCount(4), in: NSRect(origin: NSPoint(x: 4, y: 4), size: QuireBadge.size(for: .messageCount(4))))
                QuireTag.draw("Other", in: NSRect(origin: NSPoint(x: 40, y: 4), size: QuireTag.size(for: "Other")))
            }
        }
        let row = Row(frame: NSRect(x: 0, y: 0, width: 100, height: 24))
        let snapshot = ComponentSnapshot.render(row, mode: .light)
        XCTAssertTrue(snapshot.matches(expected("paper", "fill", mode: .light), at: NSPoint(x: 6, y: 12)), "message count face")
        XCTAssertTrue(snapshot.matches(expected("ruleStrong", mode: .light), at: NSPoint(x: 40.25, y: 12)), "tag edge")
    }

    // MARK: Increased contrast off screen

    func testOffscreenRendererDrawsIncreasedContrast() {
        for mode in [QuireMode.lightHC, .darkHC] {
            var button: QuireButton!
            let rep = QuireOffscreenRenderer.render(mode: mode, scale: 2) {
                let host = SnapshotHost(frame: NSRect(x: 0, y: 0, width: 160, height: 60))
                host.fill = .qPaper
                button = QuireButton(title: "Focused", variant: .secondary)
                button.sizeToFit()
                button.displayState = .focused
                button.setFrameOrigin(NSPoint(x: 20, y: 10))
                host.addSubview(button)
                return host
            }!
            let snapshot = ComponentSnapshot(rep: rep, scale: 2)
            let face = button.convert(button.faceRect, to: button.superview)
            let y = face.midY
            let gap = QuireFocusRing.gap
            // The ring sits outside the gap: 3 pt of focus (IC), then paper.
            for offset in stride(from: 0.25, to: 3, by: 0.5) {
                XCTAssertTrue(snapshot.matches(expected("focus", mode: mode), at: NSPoint(x: face.minX - gap - offset, y: y)),
                              "\(mode) ring at \(offset): \(snapshot.hex(at: NSPoint(x: face.minX - gap - offset, y: y)))")
            }
            XCTAssertTrue(snapshot.matches(expected("paper", mode: mode), at: NSPoint(x: face.minX - gap - 3.25, y: y)), "\(mode): 3 pt, no more")
            XCTAssertTrue(snapshot.matches(expected("ruleStrong", mode: mode), at: NSPoint(x: face.minX + 0.25, y: y)), "\(mode) IC edge")
        }
        XCTAssertNil(QuireEnvironment.shared.overrides.increaseContrast == true ? "leaked" : nil, "the override is given back")
    }
}
