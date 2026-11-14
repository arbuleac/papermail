#if DEBUG
import AppKit
import SSDesign

/// The gallery window's bar: an appearance popup, a font popup, a theme popup and the four Quire environment overrides.
/// System controls on purpose: the bar is a tool for looking at Quire, not part of it.
@MainActor
final class DesignGalleryControlsBar: NSView {
    var onChange: (() -> Void)?

    private let appearancePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    /// "App Font" follows Settings › Appearance › Font; the others force a face for the gallery's check.
    private let fontPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    /// "App Theme" follows Settings › Appearance › Theme; the others force a theme for the gallery without saving it.
    private let themePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let graphite = NSButton(checkboxWithTitle: "Graphite", target: nil, action: nil)
    private let contrast = NSButton(checkboxWithTitle: "Increase Contrast", target: nil, action: nil)
    private let motion = NSButton(checkboxWithTitle: "Reduce Motion", target: nil, action: nil)
    private let transparency = NSButton(checkboxWithTitle: "Reduce Transparency", target: nil, action: nil)

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 640, height: 32))
        appearancePopup.addItems(withTitles: ["System Appearance", "Light", "Dark"])
        // Start from what the app is showing, so `--appearance` carries into the bar.
        if NSApp.appearance?.name == .aqua { appearancePopup.selectItem(at: 1) }
        if NSApp.appearance?.name == .darkAqua { appearancePopup.selectItem(at: 2) }
        fontPopup.addItems(withTitles: ["App Font", "New York", "SF Pro"])
        switch QuireEnvironment.shared.overrides.typeface {
        case .newYork?: fontPopup.selectItem(at: 1)
        case .sfPro?: fontPopup.selectItem(at: 2)
        case nil: fontPopup.selectItem(at: 0)
        }
        themePopup.addItems(withTitles: ["App Theme"] + QuireTheme.allCases.map(\.name))
        themePopup.selectItem(at: QuireEnvironment.shared.overrides.theme.map { $0.index + 1 } ?? 0)
        for popup in [appearancePopup, fontPopup, themePopup] {
            popup.controlSize = .small
            popup.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        }
        let current = QuireEnvironment.shared.snapshot
        let checks = [(graphite, current.isGraphite), (contrast, current.increaseContrast),
                      (motion, current.reduceMotion), (transparency, current.reduceTransparency)]
        for (box, on) in checks {
            box.controlSize = .small
            box.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            box.state = on ? .on : .off
        }
        for control in [appearancePopup, fontPopup, themePopup] + checks.map(\.0) as [NSControl] {
            control.target = self
            control.action = #selector(changed(_:))
            // System controls set no pointer of their own; the gallery's bar shows the app's (§4.17).
            QuirePointerOverlay.install(on: control)
        }
        let stack = NSStackView(views: [appearancePopup, fontPopup, themePopup] + checks.map(\.0))
        stack.orientation = .horizontal
        stack.spacing = 16
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// The forced appearance, or nil to follow the app.
    var chosenAppearance: NSAppearance? {
        switch appearancePopup.indexOfSelectedItem {
        case 1: return NSAppearance(named: .aqua)
        case 2: return NSAppearance(named: .darkAqua)
        default: return nil
        }
    }

    var overrides: QuireEnvironment.Overrides {
        let typeface: QuireFont.Typeface? = switch fontPopup.indexOfSelectedItem {
        case 1: .newYork
        case 2: .sfPro
        default: nil
        }
        let themes = QuireTheme.allCases
        let theme = themes.indices.contains(themePopup.indexOfSelectedItem - 1) ? themes[themePopup.indexOfSelectedItem - 1] : nil
        return QuireEnvironment.Overrides(isGraphite: graphite.state == .on, increaseContrast: contrast.state == .on,
                                          reduceMotion: motion.state == .on, reduceTransparency: transparency.state == .on,
                                          typeface: typeface, theme: theme)
    }

    @objc private func changed(_ sender: Any?) {
        onChange?()
    }
}
#endif
