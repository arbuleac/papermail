import AppKit
import SSCore
import SSDesign

/// The Later menu (spec §5.45): a system `NSMenu` of the presets offered now, each with the time it brings mail back in a
/// right-aligned `ink3` column written as the rows write times (“Tomorrow  Tue 09:00”), a separator, and Pick a Date….
/// L pops it at the selected row (or the reader's header); the row's context menu carries the same items as its Later
/// submenu. Highlight, keyboard (arrows, Return, Esc) and item states are the system's.
@MainActor
enum LaterMenu {
    static let pickDateTitle = "Pick a Date…"

    /// The menu for `now`. Each preset item carries its time as its `representedObject` (a `Date`) and sends
    /// `presetAction`; Pick a Date… sends `pickAction`. Both go to `target`.
    static func build(now: Date, formatter: DateFormatting, calendar: Calendar = .autoupdatingCurrent, target: AnyObject,
                      presetAction: Selector, pickAction: Selector) -> NSMenu {
        let menu = NSMenu(title: "Later")
        for item in items(now: now, formatter: formatter, calendar: calendar, target: target, presetAction: presetAction,
                          pickAction: pickAction) {
            menu.addItem(item)
        }
        return menu
    }

    /// The presets, the separator and Pick a Date…, for the menu or a submenu.
    static func items(now: Date, formatter: DateFormatting, calendar: Calendar = .autoupdatingCurrent, target: AnyObject,
                      presetAction: Selector, pickAction: Selector) -> [NSMenuItem] {
        let offered = LaterPreset.offered(at: now, calendar: calendar).map { (title: $0.preset.title, date: $0.date) }
        var items = timedItems(offered, now: now, formatter: formatter, target: target, action: presetAction) { "Comes back \($0)" }
        items.append(.separator())
        let pick = NSMenuItem(title: pickDateTitle, action: pickAction, keyEquivalent: "")
        pick.target = target
        items.append(pick)
        return items
    }

    /// One item per named time, each name followed by its time in `ink3` on a right tab stop past the longest name, written
    /// as the rows write times; each carries its time as its `representedObject`. Later's presets and Send Later's
    /// (§5.23) are set the same way. `help` words a time for VoiceOver.
    static func timedItems(_ entries: [(title: String, date: Date)], now: Date, formatter: DateFormatting, target: AnyObject,
                           action: Selector, help: (String) -> String) -> [NSMenuItem] {
        let reference = formatter.reference(now: now)
        let times = entries.map { formatter.dueTime(for: $0.date, reference: reference) }
        let font = NSFont.menuFont(ofSize: 0)
        let titleWidth = entries.map { ceil(($0.title as NSString).size(withAttributes: [.font: font]).width) }.max() ?? 0
        let timeWidth = times.map { ceil(($0 as NSString).size(withAttributes: [.font: font]).width) }.max() ?? 0
        // The time column ends on a right tab stop past the longest name, as the title menu sets its sequences.
        let style = NSMutableParagraphStyle()
        style.tabStops = [NSTextTab(textAlignment: .right, location: titleWidth + Quire.Space.s8 + timeWidth)]
        var items: [NSMenuItem] = []
        for (entry, time) in zip(entries, times) {
            let item = NSMenuItem(title: entry.title, action: action, keyEquivalent: "")
            item.target = target
            item.representedObject = entry.date
            let title = NSMutableAttributedString(string: entry.title, attributes: [.font: font, .paragraphStyle: style])
            title.append(NSAttributedString(string: "\t" + time, attributes: [.font: font, .paragraphStyle: style,
                                                                              .foregroundColor: NSColor.qInk3]))
            item.attributedTitle = title
            item.setAccessibilityHelp(help(time))
            items.append(item)
        }
        return items
    }

    /// The date a preset item brings mail back at; nil for Pick a Date… and anything else.
    static func date(of item: NSMenuItem) -> Date? {
        item.representedObject as? Date
    }
}
