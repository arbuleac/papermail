import AppKit
import SSCore
import SSDesign
import WebKit

/// Find in conversation (spec §5.19a): the bar over the reader and its traffic with the shell, which does the finding.
///
/// The bar belongs to the conversation it searched: showing another conversation, several or none closes it. The query
/// is kept for the session, so ⌥⌘F opens with it selected and ⌘G finds it again in the next conversation. One shell call
/// is in flight at a time and a newer query replaces any not yet sent, so a fast typist never queues finds the page
/// will not show; the shell's reports name their query, and only the bar's own is shown. While the selected
/// conversation's page has not landed (its render is still on its way to another slot), nothing is sent: the page on
/// screen is the conversation being left, which is never searched.
@MainActor
final class ReaderFind {
    private(set) var bar: QuireFindBar?
    /// The slot the find runs in, nil until the selected conversation's page is on screen; reports from any other are
    /// not this find's.
    private(set) weak var slot: PooledConversationView?
    /// The conversation the bar searches: the one selected when it opened.
    private(set) var conversation: ConversationID?
    /// The last query with something to find, kept while the app runs.
    private(set) var lastQuery = ""
    /// The shell's latest report for the bar's query.
    private(set) var result: ConversationFind.Result?

    /// Where the bar goes, and the view it hangs under.
    weak var host: NSView?
    weak var header: NSView?
    /// The slot on screen, once it holds the selected conversation; nil while that conversation is on its way.
    var currentSlot: () -> PooledConversationView? = { nil }
    /// The conversation selected in the reader, on screen or on its way.
    var selectedConversation: () -> ConversationID? = { nil }
    /// Gives the keyboard back to the reader's page when the bar goes from under it.
    var focusReader: () -> Void = {}

    private var queue: [String] = []
    private var inFlight = false
    private var generation = 0

    var isOpen: Bool { bar != nil }

    /// What ⌘G and ⇧⌘G would look for: the bar's query while it is open, else the one kept from earlier.
    var stepQuery: String { bar?.query ?? lastQuery }

    var canStep: Bool { ConversationFind.isSearchable(stepQuery) }

    // MARK: Opening and closing

    /// ⌥⌘F: opens the bar with the kept query selected and finds it, or gives an open bar the keyboard again.
    func open() {
        if let bar {
            bar.focus()
            return
        }
        guard let host else { return }
        let bar = QuireFindBar()
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.onQueryChange = { [weak self] query in self?.queryChanged(query) }
        bar.onNext = { [weak self] in self?.step(1) }
        bar.onPrevious = { [weak self] in self?.step(-1) }
        bar.onClose = { [weak self] in self?.close(returningFocus: true) }
        host.addSubview(bar, positioned: .above, relativeTo: nil)
        let f = Quire.Layout.FindBar.self
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: header?.bottomAnchor ?? host.topAnchor, constant: f.top),
            bar.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -f.trailing),
            bar.widthAnchor.constraint(equalToConstant: f.width),
            bar.heightAnchor.constraint(equalToConstant: f.height),
        ])
        self.bar = bar
        slot = currentSlot()
        conversation = selectedConversation()
        result = nil
        bar.show()
        if !lastQuery.isEmpty {
            bar.query = lastQuery
            send(ConversationFind.findScript(lastQuery))
        }
        apply()
        bar.focus()
    }

    /// Opens the bar searching for `query`, as if typed: the debug snapshots' sample (`--snapshot-state=find`).
    func open(query: String) {
        open()
        guard let bar else { return }
        bar.query = query
        queryChanged(query)
    }

    /// Closes the bar: the marks go, and what the find opened stays open. `returningFocus` hands the keyboard to the
    /// page when the bar had it, as Esc and Close do; a conversation changing under the bar leaves focus alone.
    func close(returningFocus: Bool) {
        guard let bar else { return }
        let window = bar.window
        let hadFocus = (window?.firstResponder as? NSView).map { $0.isDescendant(of: bar) } == true || bar.isEditing
        self.bar = nil
        reset()
        if let slot, slot.isReady {
            slot.webView.evaluateJavaScript(ConversationFind.clearScript) { _, _ in }
        }
        slot = nil
        conversation = nil
        result = nil
        if hadFocus { window?.makeFirstResponder(nil) }
        bar.hide { bar.removeFromSuperview() }
        if hadFocus, returningFocus { focusReader() }
    }

    /// The page on screen changed: the selected conversation's render landed, another slot holds it, or `restarted`,
    /// its shell started over after its content process ended. A slot no longer searched gives up its marks, and the
    /// search is made again in the new one; calls for a slot whose render was still landing go now.
    func slotDidChange(restarted: Bool = false) {
        guard let bar else { return }
        let current = currentSlot()
        guard current !== slot || restarted else {
            pump()
            return
        }
        if let previous = slot, previous !== current, previous.isReady {
            previous.webView.evaluateJavaScript(ConversationFind.clearScript) { _, _ in }
        }
        slot = current
        reset()
        result = nil
        apply()
        if current != nil, ConversationFind.isSearchable(bar.query) { send(ConversationFind.findScript(bar.query)) }
    }

    // MARK: Finding

    /// ⌘G (1) and ⇧⌘G (-1), and ↩ and ⇧↩ in the field. With the bar closed the kept query is found again, starting
    /// at the first match in view; nothing to find, or nothing found, beeps.
    func step(_ delta: Int) {
        guard let bar else {
            guard canStep else { NSSound.beep(); return }
            open()
            return
        }
        guard ConversationFind.isSearchable(bar.query), result?.hasMatches != false else {
            NSSound.beep()
            return
        }
        send(ConversationFind.stepScript(delta))
    }

    /// The shell reported. Only reports for the bar's own query from the page it searches are shown.
    func received(_ report: ConversationFind.Result, from reporting: PooledConversationView) {
        guard let bar, reporting === slot, report.query == bar.query else { return }
        result = report
        apply()
    }

    private func queryChanged(_ query: String) {
        if ConversationFind.isSearchable(query) { lastQuery = query }
        result = nil
        // Steps queued for the words before are about matches that are gone.
        queue.removeAll()
        send(ConversationFind.findScript(query))
        apply()
    }

    private func apply() {
        guard let bar else { return }
        let shown = result.flatMap { $0.query == bar.query ? $0 : nil }
        bar.announcement = shown?.announcement
        bar.countText = shown?.countText
        bar.hasMatches = shown?.hasMatches ?? false
    }

    /// Queues `script`; while no slot shows the selected conversation it waits there, and `slotDidChange` finds the
    /// bar's query again once one does.
    private func send(_ script: String) {
        if slot == nil { slot = currentSlot() }
        queue.append(script)
        pump()
    }

    private func pump() {
        guard !inFlight, let slot, slot.isReady, !queue.isEmpty else { return }
        let script = queue.removeFirst()
        inFlight = true
        let generation = self.generation
        slot.webView.evaluateJavaScript(script) { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self, generation == self.generation else { return }
                self.inFlight = false
                self.pump()
            }
        }
    }

    /// Starts the shell traffic over: a call still in flight belongs to a bar or a page that is gone.
    private func reset() {
        generation += 1
        queue.removeAll()
        inFlight = false
    }
}
