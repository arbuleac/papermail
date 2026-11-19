#if DEBUG
import AppKit
import SSCore

extension MainWindowController {
    /// `--snapshot-state=…` (debug builds), the calendar's states (spec §5.54), applied once the first selection is made:
    /// `invite` selects the demo's dinner invitation and `critique` the design critique's, so the column pencils them in;
    /// `today` selects a mail that names no time, so the column stays on today (turning it would lose to the newest
    /// mail's invitation, whose context lands after); `day+N` turns the column N days on; `hidden` hides the column as its toggle does; `week` opens the week; `strip` narrows the window below 1,088 pt so the column
    /// folds to its strip, and `strip-open` opens the column over the reader's edge.
    func applyDebugCalendarStates() {
        guard let argument = CommandLine.arguments.first(where: { $0.hasPrefix("--snapshot-state=") }) else { return }
        let states = argument.dropFirst("--snapshot-state=".count).split(separator: ",").map(String.init)
        for state in states {
            switch state {
            case "invite": selectDebugConversation(subjectContaining: "Sam's birthday dinner")
            case "critique": selectDebugConversation(subjectContaining: "Design critique")
            case "today": selectDebugConversation(subjectContaining: "Photos from the offsite")
            case "hidden": if desk.isColumnOn { toggleDay() }
            case "week": toggleWeekView()
            case "strip", "strip-open":
                guard let window else { continue }
                window.setContentSize(NSSize(width: 1_040, height: window.contentView?.frame.height ?? 800))
                window.contentView?.layoutSubtreeIfNeeded()
                if state == "strip-open" { openStrip() }
            case let state where state.hasPrefix("day+"):
                if let days = Int(state.dropFirst("day+".count)) { turnDay(by: days) }
            default: continue
            }
        }
    }

    private func selectDebugConversation(subjectContaining words: String) {
        guard let row = list.conversations.first(where: { $0.subject.contains(words) }) else { return }
        list.selectedConversationID = row.id
        present(selection: [row.id])
    }
}
#endif
