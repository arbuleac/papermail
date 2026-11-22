#if DEBUG
import AppKit
import PaperCore
import PaperDesign

/// `--snapshot-state=send-…` (debug builds): Send's split button (spec §5.23) in a state a render cannot reach by itself,
/// on the quick reply's tool row with `--snapshot` (a short reply typed, so Send can send) and on a reply composer's bar
/// with `--snapshot-compose`. Only drawing is forced, as a gallery forces it; nothing is sent.
///
/// - `send-key`: the window's key look on every control of the bar or the row (a render launched from a terminal may
///   never be the key window);
/// - `send-hover`, `send-hover-options`, `send-pressed`, `send-pressed-options`, `send-focus`, `send-focus-options`: one
///   segment hovered, pressed or holding the keyboard;
/// - `send-sending`: Send loading (“Sending…”), its drop-down waiting;
/// - `send-norecipient`: Send waiting for a recipient, its drop-down still open to choose;
/// - `send-locked`: both waiting, as while a reply streams in (§5.56);
/// - `send-notkey`: the look of a window that is not key;
/// - `send-narrow` (with `--snapshot`): the window at its minimum width and the list at its widest, so the reader is as
///   narrow as the shell lets it be and the quick reply's tool row has the least room it ever has (§5.18);
/// - `send-menu`, `send-menu-send`: after the window's snapshot, the drop-down as AppKit draws it, with Send and Archive or
///   Send as the choice, opened over a plain window of the app's own, its window number written beside the snapshot for a
///   capture of it alone (`<path>-menu.png.window`).
@MainActor
enum SendSnapshotStates {
    static var requested: Set<String> {
        guard let argument = CommandLine.arguments.first(where: { $0.hasPrefix("--snapshot-state=") }) else { return [] }
        return Set(argument.dropFirst("--snapshot-state=".count).split(separator: ",").map(String.init)).filter { $0.hasPrefix("send-") }
    }

    static let reply = "Tuesday at ten works. I\u{2019}ll bring the draft budget."

    /// Forces the requested look on `split`, and the key look on `others` with it.
    static func apply(_ states: Set<String>, to split: QuireSplitButton, others: [NSView]) {
        if states.contains("send-key") {
            split.windowKeyOverride = true
            others.forEach { forceKey($0) }
        }
        if states.contains("send-notkey") {
            split.windowKeyOverride = false
            others.forEach { forceKey($0, key: false) }
        }
        let action = split.actionSegment, menu = split.menuSegment
        let forced: [(String, QuireControl, QuireDisplayState)] = [
            ("send-hover", action, .hover), ("send-hover-options", menu, .hover), ("send-pressed", action, .pressed),
            ("send-pressed-options", menu, .pressed), ("send-focus", action, .focused), ("send-focus-options", menu, .focused),
        ]
        for (state, control, look) in forced where states.contains(state) { control.displayState = look }
        if states.contains("send-sending") {
            action.isLoading = true
            menu.isEnabled = false
        }
        if states.contains("send-norecipient") { action.isEnabled = false }
        if states.contains("send-locked") {
            action.isEnabled = false
            menu.isEnabled = false
        }
    }

    private static func forceKey(_ view: NSView, key: Bool = true) {
        (view as? QuireControl)?.windowKeyOverride = key
        view.subviews.forEach { forceKey($0, key: key) }
    }

    // MARK: The drop-down

    /// Opens `menu` over a plain window of the app's own (so the menu's material shows nothing but it) and, once it is on
    /// screen, writes the open menu's window number to `path` + `.window`, for a screen capture of that window alone
    /// (`screencapture -l`, run by the render script: the app starts no process); then closes both a few seconds later. The
    /// menu is AppKit's own: its rows, checkmark and key equivalents as the system draws them.
    static func showMenuForCapture(_ menu: NSMenu, path: String) {
        let backdrop = NSWindow(contentRect: NSRect(x: 80, y: 120, width: 520, height: 420), styleMask: [.borderless], backing: .buffered,
                                defer: false)
        backdrop.backgroundColor = .qPaper
        backdrop.isReleasedWhenClosed = false
        backdrop.orderFrontRegardless()
        NSApp.activate()
        let announce = Timer(timeInterval: 0.8, repeats: false) { _ in
            MainActor.assumeIsolated {
                let pid = ProcessInfo.processInfo.processIdentifier
                let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
                // The open menu is this process's window at the pop-up menu level.
                let menuWindow = windows.first {
                    ($0[kCGWindowOwnerPID as String] as? Int32) == pid
                        && ($0[kCGWindowLayer as String] as? Int ?? 0) >= Int(CGWindowLevelForKey(.popUpMenuWindow))
                }
                if let id = menuWindow?[kCGWindowNumber as String] as? Int {
                    try? "\(id)\n".write(toFile: path + ".window", atomically: true, encoding: .utf8)
                }
            }
        }
        let close = Timer(timeInterval: 4, repeats: false) { _ in MainActor.assumeIsolated { menu.cancelTracking() } }
        RunLoop.main.add(announce, forMode: .common)
        RunLoop.main.add(close, forMode: .common)
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                menu.popUp(positioning: nil, at: NSPoint(x: 40, y: 380), in: backdrop.contentView)
                backdrop.orderOut(nil)
            }
        }
    }
}

extension MainWindowController {
    /// `--snapshot-state=send-…` on the quick reply, once the first conversation's render lands: a reply typed, then the
    /// state forced on its Send.
    func applyDebugSendStates() {
        let states = SendSnapshotStates.requested
        guard !states.isEmpty, !CommandLine.arguments.contains(where: { $0.hasPrefix("--snapshot-compose=") }) else { return }
        if states.contains("send-narrow"), let window, let content = window.contentView {
            window.setContentSize(NSSize(width: Quire.Layout.Window.minWidth, height: content.frame.height))
            content.layoutSubtreeIfNeeded()
            // The list as wide as it goes: the reader keeps only its own minimum.
            splitView.setPosition(splitView.bounds.width, ofDividerAt: 1)
            content.layoutSubtreeIfNeeded()
        }
        conversation.whenShownRenderLands(timeout: 10) { [weak self] _ in
            guard let self, self.conversation.focusQuickReply(all: false) else { return }
            let bar = self.conversation.quickReplyBar
            // A `write-…` state types its own notes and writes the reply (WriteSnapshotStates).
            if WriteSnapshotStates.requested == nil {
                bar.writingTextView.insertText(SendSnapshotStates.reply, replacementRange: bar.writingTextView.selectedRange())
            }
            bar.needsLayout = true
            bar.layoutSubtreeIfNeeded()
            SendSnapshotStates.apply(states, to: bar.sendSplitButton, others: [bar])
        }
    }
}

extension ComposeWindowController {
    /// `--snapshot-compose` with `--snapshot-state=send-…`: the state forced on the composer's Send.
    func stageDebugSendStates() {
        let states = SendSnapshotStates.requested
        guard !states.isEmpty else { return }
        keepNoDraft()
        // After the reply's prefill, whose recipients set Send's enabled state again.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                SendSnapshotStates.apply(states, to: self.content.bottomBar.send, others: [self.content.bottomBar, self.content.formatRow])
            }
        }
    }

    /// The drop-down's menu with `current` as the choice, built as `sendOptionsMenu()` builds it, without changing the
    /// user's choice (a render).
    func debugSendOptionsMenu(current: SendAction) -> NSMenu {
        debugSendActionMenu.menu(current: current)
    }
}
#endif
