#if DEBUG
import AppKit
import SSCore

/// `--snapshot-state=reader-mode` (debug builds): reader mode (spec §5.59) on the demo's conversation that holds one
/// message of each kind of text, every card open. The experiment's gate and reader mode are held in memory for the run
/// (`keepsExperimentsInMemory`), never saved or reported. With `end` (`--snapshot-state=reader-mode,end`) the page is
/// scrolled to its last message, the HTML-only one whose quoted history folds.
extension MainWindowController {
    static var snapshotsReaderMode: Bool {
        CommandLine.arguments.contains { $0.hasPrefix("--snapshot-state=") && $0.split(separator: "=").last?.split(separator: ",").contains("reader-mode") == true }
    }

    /// Turns reader mode on for the run and names the conversation to open on, before the first selection renders.
    func prepareDebugReaderMode() -> ConversationID? {
        guard Self.snapshotsReaderMode else { return nil }
        settings.keepsExperimentsInMemory = true
        settings.offersReaderMode = true
        let store = environment.store
        return list.conversations.first { row in
            ((try? store.messages(in: row.id)) ?? []).contains { $0.subject == DemoReaderSample.subject }
        }?.id
    }

    /// Every card open once the render lands, so each one's line shows.
    func applyDebugReaderMode() {
        guard Self.snapshotsReaderMode else { return }
        let toEnd = CommandLine.arguments.contains { $0.hasPrefix("--snapshot-state=") && $0.contains("end") }
        conversation.whenShownRenderLands(timeout: 10) { webView in
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
