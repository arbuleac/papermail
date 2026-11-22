import AppKit
import XCTest
@testable import PaperDesign

/// What controls do: forced display states, activation, keyboard movement, Reduce Motion, progress modes.
@MainActor
final class ComponentBehaviourTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        // Target-action goes through NSApp, which only exists once something has asked for it.
        _ = NSApplication.shared
        QuireTestEnvironment.forceDefaults()
    }

    override func tearDown() async throws {
        QuireTestEnvironment.reset()
        try await super.tearDown()
    }

    private final class Target: NSObject {
        var count = 0
        @objc func fire(_ sender: Any?) { count += 1 }
    }

    // MARK: Display state

    func testDisplayStateForcesOneLook() {
        let button = QuireButton(title: "Send", variant: .primary)
        XCTAssertEqual(button.interactionState, .rest)
        XCTAssertFalse(button.showsFocusRing)
        button.displayState = .hover
        XCTAssertEqual(button.interactionState, .hover)
        button.displayState = .pressed
        XCTAssertEqual(button.interactionState, .pressed)
        XCTAssertFalse(button.showsFocusRing)
        button.displayState = .focused
        XCTAssertEqual(button.interactionState, .rest, "focused draws the rest face plus the ring")
        XCTAssertTrue(button.showsFocusRing, "a forced focus shows even without a key window")
        button.displayState = nil
        XCTAssertFalse(button.showsFocusRing, "no first responder in no window")
    }

    func testDisabledControlsRestAndRefuseFocus() {
        let button = QuireButton(title: "Send")
        button.isEnabled = false
        button.setHovered(true)
        XCTAssertEqual(button.interactionState, .rest)
        XCTAssertFalse(button.acceptsFirstResponder)
        button.isEnabled = true
        XCTAssertEqual(button.interactionState, .hover)
        XCTAssertTrue(button.acceptsFirstResponder)
    }

    func testFocusRingNeedsAKeyWindow() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let button = QuireButton(title: "Send")
        window.contentView?.addSubview(button)
        XCTAssertTrue(window.makeFirstResponder(button))
        XCTAssertTrue(button.hasKeyboardFocus)
        button.windowKeyOverride = false
        XCTAssertFalse(button.showsFocusRing, "no first responder is shown in a window that is not key (§3.4)")
        button.windowKeyOverride = true
        XCTAssertTrue(button.showsFocusRing)
    }

    func testControlsJoinTheKeyViewLoopUnlessTheyAskForFullKeyboardAccess() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: .titled, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let button = QuireButton(title: "Send")
        window.contentView?.addSubview(button)
        XCTAssertTrue(button.acceptsFirstResponder)
        button.requiresFullKeyboardAccess = true
        if !(NSApp?.isFullKeyboardAccessEnabled ?? false) {
            XCTAssertFalse(button.canBecomeKeyView, "Cc and Bcc join the loop only with Full Keyboard Access")
        }
    }

    func testFieldContainersHandFocusToTheirTextField() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 60), styleMask: .titled, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let field = QuireTextField(placeholder: "Client ID")
        let search = QuireSearchField()
        window.contentView?.addSubview(field)
        window.contentView?.addSubview(search)
        XCTAssertFalse(field.acceptsFirstResponder, "Tab lands on the text field, not its container")
        XCTAssertFalse(search.acceptsFirstResponder)
        XCTAssertTrue(window.makeFirstResponder(field.textField))
        XCTAssertTrue(field.hasKeyboardFocus)
        field.windowKeyOverride = true
        XCTAssertTrue(field.showsFocusRing, "the container rings its editing field")
        XCTAssertTrue(window.makeFirstResponder(search.textField))
        XCTAssertFalse(field.hasKeyboardFocus)
        XCTAssertTrue(search.hasKeyboardFocus)
        XCTAssertFalse(search.showsKeycap, "the “/” keycap hides while focused")
    }

    // MARK: Activation

    func testButtonsActivateOnPerformClickSpaceAndKeyEquivalent() {
        let target = Target()
        let button = QuireButton(title: "Send", variant: .primary, target: target, action: #selector(Target.fire(_:)))
        button.performClick(nil)
        XCTAssertEqual(target.count, 1)
        let space = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                     characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49)!
        button.keyDown(with: space)
        XCTAssertEqual(target.count, 2)
        button.keyEquivalent = "\r"
        button.keyEquivalentModifierMask = .command
        let commandReturn = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: 0, context: nil,
                                             characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
        XCTAssertTrue(button.performKeyEquivalent(with: commandReturn))
        XCTAssertEqual(target.count, 3)
        // Caps Lock never blocks ⌘↩, and keypad Enter counts as Return, as with NSButton.
        let capsLock = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .capsLock], timestamp: 0, windowNumber: 0,
                                        context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
        XCTAssertTrue(button.performKeyEquivalent(with: capsLock))
        XCTAssertEqual(target.count, 4)
        let enter = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .numericPad], timestamp: 0, windowNumber: 0,
                                     context: nil, characters: "\u{3}", charactersIgnoringModifiers: "\u{3}", isARepeat: false, keyCode: 76)!
        XCTAssertTrue(button.performKeyEquivalent(with: enter))
        XCTAssertEqual(target.count, 5)
        let shifted = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .shift], timestamp: 0, windowNumber: 0,
                                       context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
        XCTAssertFalse(button.performKeyEquivalent(with: shifted), "another modifier is another shortcut")
        button.isEnabled = false
        button.performClick(nil)
        XCTAssertFalse(button.accessibilityPerformPress())
        XCTAssertEqual(target.count, 5, "disabled buttons do nothing")
    }

    func testCheckboxCyclesAndSendsItsAction() {
        let target = Target()
        let box = QuireCheckbox(title: "Show sender", state: .mixed, target: target, action: #selector(Target.fire(_:)))
        box.performClick(nil)
        XCTAssertEqual(box.state, .on, "mixed → on")
        box.performClick(nil)
        XCTAssertEqual(box.state, .off)
        XCTAssertEqual(target.count, 2)
    }

    func testRadioGroupIsOneTabStopAndArrowsMoveTheChoice() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 60), styleMask: .titled, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let group = QuireRadioGroupView(titles: ["Standard", "Compact", "Roomy"], selectedIndex: 0)
        window.contentView?.addSubview(group)
        var changes: [Int] = []
        group.onChange = { changes.append($0) }
        XCTAssertTrue(group.isTabStop(group.buttons[0]))
        XCTAssertFalse(group.isTabStop(group.buttons[1]))
        group.buttons[1].isEnabled = false
        group.moveSelection(from: group.buttons[0], by: 1)
        XCTAssertEqual(group.selectedIndex, 2, "disabled radios are skipped")
        XCTAssertTrue(window.firstResponder === group.buttons[2], "focus moves with the choice")
        XCTAssertTrue(group.isTabStop(group.buttons[2]))
        group.moveSelection(from: group.buttons[2], by: 1)
        XCTAssertEqual(group.selectedIndex, 0, "wraps")
        group.buttons[2].performClick(nil)
        XCTAssertEqual(group.selectedIndex, 2)
        XCTAssertEqual(group.buttons.filter(\.isSelected).count, 1)
        XCTAssertEqual(changes, [2, 0, 2])
    }

    func testToggleAnimatesItsKnobUnlessReduceMotion() {
        let toggle = QuireToggle()
        let knob = toggle.knob
        toggle.performClick(nil)
        XCTAssertTrue(toggle.isOn)
        XCTAssertEqual(toggle.knobRect, toggle.knobFrame(on: true, stretched: false), "the model is at the end at once")
        XCTAssertNotNil(knob.animation(forKey: "quire.position"), "travels over dur.quick")
        Quire.Motion.finishAll()
        XCTAssertNil(knob.animation(forKey: "quire.position"), "a keystroke finishes it")

        QuireEnvironment.shared.setOverrides(.init(isGraphite: false, increaseContrast: false, reduceMotion: true, reduceTransparency: false))
        toggle.performClick(nil)
        XCTAssertFalse(toggle.isOn)
        XCTAssertNil(knob.animation(forKey: "quire.position"), "instant under Reduce Motion")
        XCTAssertEqual(toggle.knobRect, toggle.knobFrame(on: false, stretched: false))
    }

    func testTogglePressStretchesTheKnobAtOnce() {
        let toggle = QuireToggle(isOn: true)
        toggle.isPressed = true
        toggle.stateDidChange()
        XCTAssertEqual(toggle.knobRect.width, 18)
        XCTAssertEqual(toggle.knobRect.maxX, toggle.knobFrame(on: true, stretched: false).maxX, "toward the centre")
        toggle.isPressed = false
        toggle.pressDidEnd(activated: false)
        XCTAssertEqual(toggle.knobRect.width, 14)
    }

    func testTabsChooseEnabledTabsOnly() {
        let target = Target()
        let tabs = QuireUnderlineTabs(items: [.init("Reply"), .init("Reply all", isEnabled: false), .init("Forward")])
        tabs.target = target
        tabs.action = #selector(Target.fire(_:))
        tabs.choose(1)
        XCTAssertEqual(tabs.selectedIndex, 0)
        let right = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.numericPad, .function], timestamp: 0, windowNumber: 0, context: nil,
                                     characters: String(UnicodeScalar(NSRightArrowFunctionKey)!), charactersIgnoringModifiers: String(UnicodeScalar(NSRightArrowFunctionKey)!),
                                     isARepeat: false, keyCode: 124)!
        tabs.keyDown(with: right)
        XCTAssertEqual(tabs.selectedIndex, 2, "→ skips the disabled tab")
        XCTAssertEqual(target.count, 1)
        tabs.isEnabled = false
        tabs.choose(0)
        XCTAssertEqual(tabs.selectedIndex, 2, "disabled: nothing can be chosen")
    }

    func testIconButtonTogglesWhenAsked() {
        let target = Target()
        let bold = QuireIconButton(symbolName: Quire.Icon.bold, target: target, action: #selector(Target.fire(_:)))
        bold.performClick(nil)
        XCTAssertFalse(bold.isOn, "a plain icon button only sends its action")
        bold.togglesOnClick = true
        bold.performClick(nil)
        XCTAssertTrue(bold.isOn)
        XCTAssertEqual(target.count, 2)
    }

    /// The Send button's drop-down (§5.23): a menu button acts on mouse-down, as a pull-down opens, draws pressed while
    /// its action (the menu tracking) runs, and is at rest after; VoiceOver hears a menu button.
    func testAMenuButtonActsOnMouseDownAndDrawsPressedMeanwhile() throws {
        @MainActor final class Recorder: NSObject {
            var states: [QuireDisplayState] = []
            @objc func fire(_ sender: Any?) { states.append((sender as? QuireIconButton)?.interactionState ?? .rest) }
        }
        let recorder = Recorder()
        let chevron = QuireIconButton(symbolName: Quire.Icon.titleMenu, size: .large, accessibilityLabel: "Send Options",
                                      target: recorder, action: #selector(Recorder.fire(_:)))
        chevron.frame = chevron.frame(forVisualRect: NSRect(x: 0, y: 0, width: 28, height: 28))
        XCTAssertEqual(chevron.accessibilityRole(), .button)
        chevron.isMenuButton = true
        XCTAssertEqual(chevron.accessibilityRole(), .menuButton)
        let down = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                                    context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        chevron.mouseDown(with: down)
        XCTAssertEqual(recorder.states, [.pressed], "acted on mouse-down, pressed while the menu tracks")
        XCTAssertEqual(chevron.interactionState, .rest, "at rest once it closes")
        chevron.performClick(nil)
        XCTAssertEqual(recorder.states.count, 2, "Space and VoiceOver's press open it too")
        chevron.isEnabled = false
        chevron.mouseDown(with: down)
        XCTAssertEqual(recorder.states.count, 2, "disabled: nothing")
    }

    func testPopupSelection() {
        let popup = QuirePopUpButton(titles: ["5 seconds", "10 seconds", "20 seconds"], selectedIndex: 1)
        XCTAssertEqual(popup.title, "10 seconds")
        XCTAssertEqual(popup.itemMenu.items.map(\.state), [.off, .on, .off], "a checkmark on the current value")
        popup.selectedIndex = 2
        XCTAssertEqual(popup.itemMenu.items.map(\.state), [.off, .off, .on])
        XCTAssertTrue(popup.itemMenu.items.allSatisfy { $0.target === popup })
    }

    // MARK: Progress

    func testDeterminateBarNeverGoesBackwardsWithinARun() {
        let bar = QuireProgressBar(mode: .determinate(0.5))
        bar.setFrameSize(NSSize(width: 100, height: 4))
        bar.layoutSubtreeIfNeeded()
        XCTAssertEqual(bar.displayedFraction, 0.5, accuracy: 0.001)
        bar.mode = .determinate(0.3)
        XCTAssertEqual(bar.displayedFraction, 0.5, accuracy: 0.001, "never backwards")
        bar.mode = .determinate(0.8)
        XCTAssertEqual(bar.displayedFraction, 0.8, accuracy: 0.001, "jumps forward")
        bar.reset(to: 0.1)
        XCTAssertEqual(bar.displayedFraction, 0.1, accuracy: 0.001)
    }

    func testIndeterminateUsesAStaticSegmentUnderReduceMotion() {
        QuireEnvironment.shared.setOverrides(.init(isGraphite: false, increaseContrast: false, reduceMotion: true, reduceTransparency: false))
        let bar = QuireProgressBar(mode: .indeterminate)
        bar.setFrameSize(NSSize(width: 100, height: 4))
        bar.layoutSubtreeIfNeeded()
        XCTAssertEqual(bar.displayedFraction, 0.4, accuracy: 0.001)
        let contrail = QuireContrailView(mode: .indeterminate)
        contrail.setFrameSize(NSSize(width: 200, height: 4))
        contrail.layoutSubtreeIfNeeded()
        XCTAssertNil(contrail.layer?.sublayers?.first?.sublayers?.compactMap { $0.animation(forKey: "quire.contrail") }.first, "no sweep")
    }

    func testCountdownClockSteps() {
        let clock = QuireCountdownClock(duration: 5, remaining: 5)
        XCTAssertEqual(clock.steppedFraction, 1)
        let partial = QuireCountdownClock(duration: 5, remaining: 3.4)
        XCTAssertEqual(partial.steppedFraction, 0.8, accuracy: 0.0001, "4 whole seconds left of 5 (“Sending in 4 s”)")
        XCTAssertEqual(partial.fraction, 0.68, accuracy: 0.0001)
        let done = QuireCountdownClock(duration: 5, remaining: 0)
        XCTAssertEqual(done.steppedFraction, 0)
    }

    func testContrailCountdownDrainsPausesAndStepsUnderReduceMotion() {
        let contrail = QuireContrailView(mode: .countdown(duration: 5, remaining: 2.5))
        contrail.setFrameSize(NSSize(width: 200, height: 4))
        contrail.layoutSubtreeIfNeeded()
        XCTAssertEqual(contrail.countdownRemaining ?? 0, 2.5, accuracy: 0.1)
        contrail.isPaused = true
        let frozen = contrail.countdownRemaining ?? 0
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(contrail.countdownRemaining ?? 0, frozen, accuracy: 0.0001, "frozen while paused")
        XCTAssertEqual(contrail.displayedFraction, CGFloat(frozen / 5), accuracy: 0.01)

        QuireEnvironment.shared.setOverrides(.init(isGraphite: false, increaseContrast: false, reduceMotion: true, reduceTransparency: false))
        contrail.isPaused = false
        XCTAssertEqual(contrail.displayedFraction, 0.6, accuracy: 0.001, "3 whole seconds of 5, stepped")
        Quire.Motion.finishAll()
        XCTAssertNotNil(contrail.countdownRemaining, "a keystroke never ends a countdown")
    }

    func testSlipShowsItsContrailOnlyWithAnAction() {
        let slip = QuireSlipView(kind: .confirmation, message: "Undid Archive")
        slip.startLifetime(2)
        XCTAssertTrue(slip.lifetimeContrail.isHidden, "no contrail without an action")
        slip.setAction("Undo", keycap: "Z")
        XCTAssertFalse(slip.lifetimeContrail.isHidden)
        slip.stopLifetime()
        XCTAssertTrue(slip.lifetimeContrail.isHidden)
    }

    func testSkeletonRevealsAfterItsDelay() {
        let skeleton = QuireSkeleton(.body)
        skeleton.reveal()
        XCTAssertTrue(skeleton.isHidden, "never before 300 ms")
        RunLoop.main.run(until: Date().addingTimeInterval(Quire.Motion.skeletonDelay + 0.15))
        XCTAssertFalse(skeleton.isHidden)
        skeleton.conceal()
        XCTAssertTrue(skeleton.isHidden)
    }

    func testSearchFieldEscapeClearsThenCancels() {
        let search = QuireSearchField()
        var cancelled = 0
        var queries: [String] = []
        search.onCancel = { cancelled += 1 }
        search.onQueryChange = { queries.append($0) }
        search.query = "lisbon"
        let editor = NSTextView()
        XCTAssertTrue(search.control(search.textField, textView: editor, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        XCTAssertEqual(search.query, "")
        XCTAssertEqual(queries, [""])
        XCTAssertEqual(cancelled, 0)
        XCTAssertTrue(search.control(search.textField, textView: editor, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        XCTAssertEqual(cancelled, 1, "Esc in an empty field returns focus to the list")
    }
}
