import AppKit

/// One tab of `QuireUnderlineTabs` for VoiceOver: a radio button with the tab subrole (“Reply, selected, tab 1
/// of 2”), pressable.
@MainActor
final class QuireTabAccessibilityElement: NSAccessibilityElement {
    weak var tabs: QuireUnderlineTabs?
    let index: Int

    init(tabs: QuireUnderlineTabs, index: Int) {
        self.tabs = tabs
        self.index = index
        super.init()
    }

    override func accessibilityRole() -> NSAccessibility.Role? { .radioButton }
    override func accessibilitySubrole() -> NSAccessibility.Subrole? { .tabButtonSubrole }
    override func accessibilityParent() -> Any? { tabs }

    override func accessibilityLabel() -> String? {
        guard let tabs, tabs.items.indices.contains(index) else { return nil }
        return tabs.items[index].title
    }

    override func accessibilityValue() -> Any? {
        NSNumber(value: tabs?.selectedIndex == index ? 1 : 0)
    }

    override func isAccessibilityEnabled() -> Bool {
        guard let tabs, tabs.items.indices.contains(index) else { return false }
        return tabs.isEnabled && tabs.items[index].isEnabled
    }

    override func isAccessibilitySelected() -> Bool { tabs?.selectedIndex == index }

    override func accessibilityFrame() -> NSRect {
        guard let tabs, let window = tabs.window else { return .zero }
        return window.convertToScreen(tabs.convert(tabs.hitRect(forTab: index), to: nil))
    }

    override func accessibilityPerformPress() -> Bool {
        guard let tabs, isAccessibilityEnabled() else { return false }
        tabs.choose(index)
        return true
    }
}
