import AppKit
import XCTest
@testable import SSDesign

/// Every control exposes the right NSAccessibility role, label and value (spec §4.14, §5.18 “Reply, selected,
/// tab 1 of 2”).
@MainActor
final class ComponentAccessibilityTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        QuireTestEnvironment.forceDefaults()
    }

    override func tearDown() async throws {
        QuireTestEnvironment.reset()
        try await super.tearDown()
    }

    func testButtons() {
        let button = QuireButton(title: "Send", variant: .primary)
        XCTAssertTrue(button.isAccessibilityElement())
        XCTAssertEqual(button.accessibilityRole(), .button)
        XCTAssertEqual(button.accessibilityLabel(), "Send")
        button.loadingTitle = "Sending…"
        button.isLoading = true
        XCTAssertEqual(button.accessibilityLabel(), "Sending…")
        button.isEnabled = false
        XCTAssertFalse(button.isAccessibilityEnabled())

        let icon = QuireIconButton(symbolName: Quire.Icon.compose, accessibilityLabel: "New Message")
        XCTAssertEqual(icon.accessibilityRole(), .button)
        XCTAssertEqual(icon.accessibilityLabel(), "New Message", "custom glyph buttons carry the action name")
        let toggle = QuireIconButton(symbolName: Quire.Icon.bold, size: .large, accessibilityLabel: "Bold")
        toggle.togglesOnClick = true
        XCTAssertEqual(toggle.accessibilityRole(), .checkBox)
        XCTAssertEqual(toggle.accessibilitySubrole(), .toggle)
        XCTAssertEqual(toggle.accessibilityValue() as? NSNumber, 0)
        XCTAssertTrue(toggle.accessibilityPerformPress())
        XCTAssertEqual(toggle.accessibilityValue() as? NSNumber, 1)
    }

    func testChoices() {
        let checkbox = QuireCheckbox(title: "Show sender", state: .mixed)
        XCTAssertEqual(checkbox.accessibilityRole(), .checkBox)
        XCTAssertEqual(checkbox.accessibilityLabel(), "Show sender")
        XCTAssertEqual(checkbox.accessibilityValue() as? NSNumber, 2)

        let toggle = QuireToggle(title: "New mail", isOn: true)
        XCTAssertEqual(toggle.accessibilityRole(), .checkBox)
        XCTAssertEqual(toggle.accessibilitySubrole(), .switch)
        XCTAssertEqual(toggle.accessibilityValue() as? NSNumber, 1)

        let group = QuireRadioGroup(titles: ["Standard", "Compact"], selectedIndex: 1)
        XCTAssertEqual(group.accessibilityRole(), .radioGroup)
        let radios = group.accessibilityChildren() as? [QuireRadioButton]
        XCTAssertEqual(radios?.count, 2)
        XCTAssertEqual(radios?.first?.accessibilityRole(), .radioButton)
        XCTAssertEqual(radios?.map { $0.accessibilityValue() as? NSNumber }, [0, 1])
        XCTAssertEqual(radios?.last?.accessibilityLabel(), "Compact")
    }

    func testPopupAndTabs() {
        let popup = QuirePopUpButton(titles: ["5 seconds", "10 seconds"], selectedIndex: 1)
        XCTAssertEqual(popup.accessibilityRole(), .popUpButton)
        XCTAssertEqual(popup.accessibilityValue() as? String, "10 seconds")

        let tabs = QuireUnderlineTabs(items: [.init("Reply"), .init("Reply all", isEnabled: false)])
        XCTAssertEqual(tabs.accessibilityRole(), .tabGroup)
        let children = tabs.accessibilityChildren() as? [NSAccessibilityElement]
        XCTAssertEqual(children?.count, 2)
        XCTAssertEqual(children?.first?.accessibilityRole(), .radioButton)
        XCTAssertEqual(children?.first?.accessibilitySubrole(), .tabButtonSubrole)
        XCTAssertEqual(children?.first?.accessibilityLabel(), "Reply")
        XCTAssertEqual(children?.first?.accessibilityValue() as? NSNumber, 1)
        XCTAssertEqual(children?.first?.isAccessibilitySelected(), true)
        XCTAssertEqual(children?.last?.isAccessibilityEnabled(), false, "Reply all with one participant")
        XCTAssertFalse(children?.last?.accessibilityPerformPress() ?? true)
    }

    func testIndicatorsAndStaticElements() {
        let spinner = QuireSpinnerView()
        XCTAssertEqual(spinner.accessibilityRole(), .busyIndicator)
        XCTAssertFalse(spinner.isAccessibilityElement(), "hidden until it appears")
        XCTAssertEqual(QuireProgressBar(mode: .determinate(0.25)).accessibilityRole(), .progressIndicator)
        XCTAssertEqual(QuireProgressBar(mode: .determinate(0.25)).accessibilityValue() as? NSNumber, 0.25)
        XCTAssertEqual(QuireContrailView(mode: .determinate(0.5)).accessibilityRole(), .progressIndicator)
        XCTAssertEqual(QuireSkeleton(.body).accessibilityRole(), .busyIndicator)

        XCTAssertEqual(QuireBadge(.unread(128)).accessibilityRole(), .staticText)
        XCTAssertEqual(QuireBadge(.unread(128)).accessibilityLabel(), "128 unread", "VoiceOver hears the real count")
        XCTAssertEqual(QuireBadge(.attention).accessibilityLabel(), "Sign in required")
        XCTAssertEqual(QuireTag("Other").accessibilityLabel(), "Other")
        XCTAssertEqual(QuireKeycap("⌘Z").accessibilityRole(), .staticText)

        let empty = QuireEmptyStateView(sentence: "No conversation selected", hint: [.keys(["J", "K"]), .text("to move")])
        XCTAssertEqual(empty.accessibilityRole(), .staticText)
        XCTAssertEqual(empty.accessibilityLabel(), "No conversation selected J K to move")

        XCTAssertFalse(QuireHairline().isAccessibilityElement())
        XCTAssertFalse(QuireMarginRule().isAccessibilityElement())
    }

    func testSurfacesAndFields() {
        let banner = QuireBanner(kind: .danger, message: "Couldn't load this message.")
        let retry = banner.setAction("Retry")
        XCTAssertEqual(banner.accessibilityRole(), .group)
        XCTAssertEqual(banner.accessibilityLabel(), "Couldn't load this message.")
        XCTAssertEqual(retry?.accessibilityRole(), .button)
        XCTAssertEqual(banner.setDismissible(true)?.accessibilityLabel(), "Dismiss")

        let slip = QuireSlipView(kind: .undoable, message: "Archived")
        let undo = slip.setAction("Undo", keycap: "Z")
        XCTAssertEqual(slip.accessibilityRole(), .group)
        XCTAssertEqual(slip.accessibilityLabel(), "Archived")
        XCTAssertEqual(undo?.accessibilityRole(), .button)
        XCTAssertEqual(undo?.accessibilityLabel(), "Undo")

        let field = QuireTextField(placeholder: "Client ID")
        XCTAssertFalse(field.isAccessibilityElement(), "the text field inside is the element")
        XCTAssertEqual(field.textField.cell?.isAccessibilityElement(), true, "NSTextField is reached through its cell")
        let search = QuireSearchField(placeholder: "Search Inbox")
        XCTAssertFalse(search.isAccessibilityElement())
        XCTAssertEqual(search.textField.accessibilityLabel(), "Search Inbox")
    }
}
