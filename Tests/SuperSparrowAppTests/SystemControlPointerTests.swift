import AppKit
import SSCore
import SSDesign
import XCTest
@testable import SuperSparrowApp

/// The pointer over controls AppKit makes (spec §4.17): every app alert's buttons and the Later sheet's take the hand
/// from an overlay that takes no clicks, Snooze's following it as it is enabled and disabled; the Design Gallery's bar of
/// system popups and checkboxes does the same; and the gallery's scrim specimen keeps the hand of the button under it
/// from showing through.
@MainActor
final class SystemControlPointerTests: XCTestCase {
    /// Every alert the app shows is built by `makeAlert`: each button gets the hand over the whole button, and clicks
    /// still reach it.
    func testEveryAlertsButtonsTakeTheHand() throws {
        for made in [AppAlert.sendWithoutSubject, AppAlert.discardDraft(recipient: "Ben Carter"),
                     AppAlert.discardDrafts(count: 3, recipient: nil)] {
            let alert = made.makeAlert()
            alert.layout()
            XCTAssertEqual(alert.buttons.count, made.buttons.count)
            for button in alert.buttons {
                let overlay = try XCTUnwrap(overlay(on: button), "\(made.title): \(button.title)")
                XCTAssertEqual(overlay.frame, button.bounds, "sized with the button")
                XCTAssertEqual(overlay.pointerRegions, [QuirePointerRegion(button.bounds, cursor: .pointingHand)])
                XCTAssertNil(overlay.hitTest(NSPoint(x: button.bounds.midX, y: button.bounds.midY)), "clicks reach the button")
            }
        }
    }

    /// The Later and Send Later sheet: Snooze (Schedule) and Cancel take the hand; Snooze takes the arrow while the time
    /// chosen has passed, which disables it, and the hand again once it is ahead. The calendar and the time field are
    /// AppKit's own composite controls and keep the system's pointer.
    func testTheLaterSheetsButtonsTakeTheHandAndSnoozeFollowsItsState() throws {
        let now = try XCTUnwrap(Calendar.autoupdatingCurrent.date(bySettingHour: 15, minute: 0, second: 0, of: Date()))
        for purpose in [LaterDatePicker.Purpose.snooze(count: 1), .sendLater] {
            let picker = LaterDatePicker(purpose: purpose, now: { now })
            picker.alert.layout()
            let snooze = try XCTUnwrap(overlay(on: picker.snoozeButton))
            let cancel = try XCTUnwrap(overlay(on: picker.alert.buttons[1]))
            XCTAssertTrue(picker.snoozeButton.isEnabled, "tomorrow at 09:00 is ahead")
            XCTAssertEqual(snooze.pointerRegions.map(\.cursor), [.pointingHand])
            XCTAssertEqual(cancel.pointerRegions.map(\.cursor), [.pointingHand])

            picker.calendarPicker.dateValue = now
            picker.timePicker.dateValue = now.addingTimeInterval(-3_600)
            picker.updateSnoozeButton()
            XCTAssertFalse(picker.snoozeButton.isEnabled)
            XCTAssertEqual(snooze.pointerRegions.map(\.cursor), [.arrow], "a disabled Snooze shows the arrow")
            picker.timePicker.dateValue = now.addingTimeInterval(3_600)
            picker.updateSnoozeButton()
            XCTAssertEqual(snooze.pointerRegions.map(\.cursor), [.pointingHand])
            XCTAssertNil(overlay(on: picker.calendarPicker))
            XCTAssertNil(overlay(on: picker.timePicker))
        }
    }

    /// The gallery's bar is system popups and checkboxes: each takes the hand.
    func testTheGallerysBarTakesTheHand() throws {
        let bar = DesignGalleryControlsBar()
        bar.layoutSubtreeIfNeeded()
        let controls = descendants(NSControl.self, of: bar).filter { $0 is NSPopUpButton || $0 is NSButton }
        XCTAssertEqual(controls.count, 7, "three popups and four checkboxes")
        for control in controls {
            let overlay = try XCTUnwrap(overlay(on: control), "\(control)")
            XCTAssertEqual(overlay.pointerRegions, [QuirePointerRegion(control.bounds, cursor: .pointingHand)])
        }
    }

    /// The scrim specimen lies on a live button that a click on it never reaches: the arrow over all of it.
    func testTheGallerysScrimSpecimenKeepsTheArrowOverTheButtonUnderIt() throws {
        let card = DesignGalleryCards.rules()
        let scrim = try XCTUnwrap(descendants(QuireScrimView.self, of: card).first)
        let specimen = try XCTUnwrap(scrim.superview as? QuirePointerTarget)
        let behind = try XCTUnwrap(descendants(QuireButton.self, of: specimen.superview).first { $0.title == "Behind" })
        XCTAssertEqual(specimen.pointerRegions, [QuirePointerRegion(specimen.bounds, cursor: .arrow)])
        XCTAssertTrue(specimen.bounds.contains(specimen.convert(behind.hitRect, from: behind)), "it covers the button")
        XCTAssertEqual(scrim.frame, specimen.bounds)
    }

    // MARK: Helpers

    private func overlay(on control: NSControl) -> QuirePointerOverlay? {
        control.subviews.lazy.compactMap { $0 as? QuirePointerOverlay }.first
    }

    private func descendants<T: NSView>(_ type: T.Type, of view: NSView?) -> [T] {
        guard let view else { return [] }
        let own: [T] = (view as? T).map { [$0] } ?? []
        return own + view.subviews.flatMap { descendants(type, of: $0) }
    }
}
