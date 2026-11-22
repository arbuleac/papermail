#if DEBUG
import AppKit
import PaperCore

/// `--snapshot-state=reader-mode` (debug builds): reader mode (spec §5.59) on the demo's conversation that holds one
/// message of each kind of text, every card open. The experiment's gate and reader mode are held in memory for the run
/// (`keepsExperimentsInMemory`), never saved or reported. Options after a comma:
/// - `end`: the page scrolled to its last message, the HTML-only one whose quoted history folds;
/// - `original`: Alex's message, the one with a text part, shown as sent (Show original), so its line reads “Original”
///   with Show text.
/// With `--snapshot-cheatsheet` the Keyboard Shortcuts sheet lists ⇧⌘R and the header shows the toggle.
extension MainWindowController {
    static var snapshotsReaderMode: Bool {
        readerModeSnapshotOptions.contains("reader-mode")
    }

    private static var readerModeSnapshotOptions: [Substring] {
        CommandLine.arguments.first { $0.hasPrefix("--snapshot-state=") }?.split(separator: "=").last?.split(separator: ",") ?? []
    }

    /// The gate and reader mode on for the run, in memory; safe to call more than once.
    func holdDebugReaderMode() {
        guard Self.snapshotsReaderMode, !settings.offersReaderMode else { return }
        settings.keepsExperimentsInMemory = true
        settings.offersReaderMode = true
    }

    /// Turns reader mode on for the run and names the conversation to open on, before the first selection renders.
    func prepareDebugReaderMode() -> ConversationID? {
        guard Self.snapshotsReaderMode else { return nil }
        holdDebugReaderMode()
        let store = environment.store
        return list.conversations.first { row in
            ((try? store.messages(in: row.id)) ?? []).contains { $0.subject == DemoReaderSample.subject }
        }?.id
    }

    /// Every card open once the render lands, so each one's line shows.
    func applyDebugReaderMode() {
        guard Self.snapshotsReaderMode else { return }
        let options = Self.readerModeSnapshotOptions
        let toEnd = options.contains("end")
        // Alex is the demo's own account: his message is the sample's one sent.
        let original = options.contains("original") ? list.selectedConversationID.flatMap { id in
            ((try? environment.store.messages(in: id)) ?? []).first { $0.roles.contains(.sent) }?.id
        } : nil
        conversation.whenShownRenderLands(timeout: 10) { [weak self] webView in
            // Once the page is up, so it patches in place as the user's click would.
            if let original { self?.conversation.showReaderOriginal(true, for: original) }
            // After the demo's first bodies have landed, which a fresh demo is still storing as the page first renders.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                webView?.evaluateJavaScript("window.ss && window.ss.expandAll()")
                guard toEnd else { return }
                // Once the frames have measured themselves.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    webView?.evaluateJavaScript("window.scrollTo(0, document.documentElement.scrollHeight)")
                }
            }
        }
    }
}
#endif
