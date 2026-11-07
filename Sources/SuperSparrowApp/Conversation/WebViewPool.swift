import AppKit
import SSCore
import SSDesign
import WebKit

/// Three warm web views sharing one process pool and configuration.
///
/// Every view loads the shell once; a conversation is then one `ss.render` call. Slots remember which
/// conversation they hold so `show` of a pre-rendered id is a view swap. The slot on screen is never
/// handed out; among the rest the least recently used one is evicted first.
@MainActor
final class WebViewPool: NSObject, WKScriptMessageHandler {
    /// One configuration for every view. WebKit gives views built from the same configuration one process
    /// pool, which is how the three share a content process without naming the deprecated `WKProcessPool`.
    let configuration: WKWebViewConfiguration
    private(set) var slots: [PooledConversationView] = []
    /// Rendered conversation to slot, so showing a pre-rendered id is one lookup and a view swap.
    private var slotsByID: [ConversationID: PooledConversationView] = [:]
    /// The slot whose web view is on screen. Owned by the view controller; the pool only refuses to reuse it.
    var current: PooledConversationView?

    var onMessage: ((PooledConversationView, ConversationScriptMessage) -> Void)?
    var onReady: ((PooledConversationView) -> Void)?
    /// Called after a content-process crash replaced the slot's web view, so the owner can re-render.
    var onViewRecreated: ((PooledConversationView) -> Void)?

    private let navigation = ConversationNavigationPolicy()
    private var tick: UInt64 = 0
    /// The shell with the reader symbols rasterised into it once for the pool (spec §4.11).
    private let document: String
    /// The script that mirrors the display modes onto a shell, kept so a slot that becomes ready gets it too.
    private var modesScript = ""
    /// The last preferences told to the shells (Font, colours notice). A slot still loading its shell misses the
    /// broadcast and later replays a payload built before it, so `markReady` sends this after that replay.
    private var preferencesScript = ""
    /// Full Keyboard Access is a keyboard setting, not a display option, so QuireEnvironment never reports it.
    private var fullKeyboardAccessObservation: NSKeyValueObservation?

    init(client: MailClient, size: Int = 3) {
        let document = ConversationShellAssets.document(symbolCSS: ReaderSymbolSheet.css)
        self.document = document
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(ShellSchemeHandler(document: document), forURLScheme: ConversationShellAssets.scheme)
        configuration.setURLSchemeHandler(InlineImageSchemeHandler(client: client), forURLScheme: RenderURLScheme.inlineImage)
        configuration.setURLSchemeHandler(AttachmentSchemeHandler(client: client), forURLScheme: RenderURLScheme.attachment)
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.suppressesIncrementalRendering = true
        // Links in a body join the Tab order only with Full Keyboard Access, as in Safari (spec §5.14).
        configuration.preferences.tabFocusesLinks = NSApp.isFullKeyboardAccessEnabled
        #if DEBUG
        configuration.preferences.setValue(true, forKey: "developerExtrasEnabled")
        #endif
        self.configuration = configuration
        super.init()
        configuration.userContentController.add(WeakScriptMessageHandler(target: self), name: ConversationShellAssets.readyHandlerName)
        configuration.userContentController.add(WeakScriptMessageHandler(target: self), name: ConversationShellAssets.messageHandlerName)
        navigation.onProcessTerminated = { [weak self] webView in self?.recreate(webView) }
        for _ in 0..<max(1, size) {
            slots.append(PooledConversationView(webView: makeWebView()))
        }
        modesScript = Self.modesScript()
        NotificationCenter.default.addObserver(self, selector: #selector(environmentDidChange(_:)),
                                               name: QuireEnvironment.didChangeNotification, object: nil)
        fullKeyboardAccessObservation = NSApp.observe(\.isFullKeyboardAccessEnabled, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.updateTabFocusesLinks() }
            }
        }
    }

    /// Links in a body join the Tab order exactly while Full Keyboard Access is on (spec §5.14), switched in
    /// every live web view, not only in the configuration future ones are made from.
    private func updateTabFocusesLinks() {
        let enabled = NSApp.isFullKeyboardAccessEnabled
        guard configuration.preferences.tabFocusesLinks != enabled else { return }
        configuration.preferences.tabFocusesLinks = enabled
        for slot in slots { slot.webView.configuration.preferences.tabFocusesLinks = enabled }
        broadcast(modesScript)
    }

    // MARK: Display modes

    /// `ss-ic`, `ss-rm`, `ss-rt` and `ss-graphite` on every shell’s `<html>`, because WebKit does not reliably
    /// track those media queries (spec §3.3). Increase Contrast is read through QuireEnvironment: on macOS 27
    /// `bestMatch` alone does not report it.
    private static func modesScript() -> String {
        let s = QuireEnvironment.shared.snapshot
        return "window.ss && window.ss.setModes({ic: \(s.increaseContrast), rm: \(s.reduceMotion), rt: \(s.reduceTransparency), graphite: \(s.isGraphite)})"
    }

    @objc private func environmentDidChange(_ note: Notification) {
        modesScript = Self.modesScript()
        broadcast(modesScript)
        updateTabFocusesLinks()
    }

    /// Tells every ready shell the reader's preferences and keeps them for the shells that become ready later.
    func broadcastPreferences(_ script: String) {
        preferencesScript = script
        broadcast(script)
    }

    /// Runs `script` in every shell that is ready; slots that become ready later get the modes and the
    /// preferences on `markReady`.
    func broadcast(_ script: String) {
        for slot in slots where slot.isReady {
            slot.webView.evaluateJavaScript(script) { _, error in
                if let error {
                    ConversationSignposts.log.error("shell broadcast failed: \(String(describing: error), privacy: .public)")
                }
            }
        }
    }

    // MARK: Lookup

    func slot(rendering id: ConversationID) -> PooledConversationView? {
        slotsByID[id]
    }

    /// Keeps the id map and the slot's own record in step; a slot ever holds one id and an id one slot.
    private func assign(_ id: ConversationID?, to slot: PooledConversationView) {
        if let previous = slot.renderedID, slotsByID[previous] === slot { slotsByID[previous] = nil }
        slot.renderedID = id
        if let id { slotsByID[id] = slot }
    }

    func slot(for webView: WKWebView) -> PooledConversationView? {
        slots.first { $0.webView === webView }
    }

    /// A slot that may be rendered into: never the one on screen, never one in `excluding`; blank slots
    /// first, then least recently used.
    func acquire(excluding: [PooledConversationView] = []) -> PooledConversationView? {
        let candidates = slots.filter { slot in
            slot !== current && !excluding.contains { $0 === slot }
        }
        if let blank = candidates.first(where: { $0.renderedID == nil }) { return blank }
        return candidates.min { $0.lastUsed < $1.lastUsed }
    }

    func touch(_ slot: PooledConversationView) {
        tick &+= 1
        slot.lastUsed = tick
    }

    // MARK: Rendering

    /// Renders into `slot`, queuing until the shell is ready. `completion(true)` means the DOM now holds
    /// `payload`; false means the render failed or was superseded by a newer request for the slot.
    func render(
        _ payload: RenderPayload,
        inputs: RenderInputs,
        id: ConversationID,
        into slot: PooledConversationView,
        completion: @escaping (Bool) -> Void = { _ in }
    ) {
        touch(slot)
        assign(id, to: slot)
        slot.renderedInputs = inputs
        let generation = slot.tracker.begin()
        guard slot.isReady else {
            slot.pendingRender = PooledConversationView.PendingRender(id: id, payload: payload, inputs: inputs, completion: completion)
            return
        }
        evaluate("window.ss.render", payload, in: slot, generation: generation, completion: completion)
    }

    /// Brings a slot that already holds `id` up to date in place, so what the reader is looking at
    /// (expansion, scroll position, loaded images) survives a store change. Anything else is a full render.
    func refresh(
        _ payload: RenderPayload,
        inputs: RenderInputs,
        id: ConversationID,
        into slot: PooledConversationView,
        completion: @escaping (Bool) -> Void = { _ in }
    ) {
        guard slot.isReady, slot.pendingRender == nil, slot.renderedID == id else {
            render(payload, inputs: inputs, id: id, into: slot, completion: completion)
            return
        }
        touch(slot)
        slot.renderedInputs = inputs
        let generation = slot.tracker.begin()
        evaluate("window.ss.update", payload, in: slot, generation: generation, completion: completion)
    }

    /// Applies read and star changes to a slot that holds `id` and is otherwise current: a handful of
    /// header patches instead of a payload carrying every body. Falls back to nothing when the slot is
    /// busy; the caller then refreshes with a payload.
    func patchFlags(_ patches: [RenderPayload.FlagPatch], inputs: RenderInputs, id: ConversationID, in slot: PooledConversationView) -> Bool {
        guard slot.isReady, slot.pendingRender == nil, !slot.renderInFlight, slot.renderedID == id else { return false }
        slot.renderedInputs = inputs
        guard !patches.isEmpty, let data = try? JSONEncoder().encode(patches) else { return true }
        slot.webView.evaluateJavaScript("window.ss.flags(\(String(decoding: data, as: UTF8.self)))") { _, error in
            if let error {
                ConversationSignposts.log.error("flag patch failed: \(String(describing: error), privacy: .public)")
            }
        }
        return true
    }

    /// Clears every slot but the one on screen, so nothing pre-rendered under an old preference is swapped in.
    func clearAll(except keep: PooledConversationView?) {
        for slot in slots where slot !== keep {
            clear(slot)
        }
    }

    /// Runs `completion` once the render in flight for `slot` lands, whoever started it, with true when
    /// the DOM holds the slot's conversation; at once with true when the slot is idle.
    func whenRenderLands(in slot: PooledConversationView, _ completion: @escaping (Bool) -> Void) {
        guard slot.renderInFlight else {
            completion(true)
            return
        }
        slot.tracker.wait(completion)
    }

    private func evaluate(
        _ function: String,
        _ payload: RenderPayload,
        in slot: PooledConversationView,
        generation: UInt64,
        completion: @escaping (Bool) -> Void
    ) {
        let json: String
        do {
            json = try payload.jsonString()
        } catch {
            ConversationSignposts.log.error("payload encoding failed: \(String(describing: error), privacy: .public)")
            slot.renderDidFinish(generation: generation, succeeded: false, completion: completion)
            return
        }
        let state = ConversationSignposts.begin(ConversationSignposts.render)
        slot.webView.evaluateJavaScript("\(function)(\(json))") { _, error in
            ConversationSignposts.end(ConversationSignposts.render, state)
            if let error {
                ConversationSignposts.log.error("render failed: \(String(describing: error), privacy: .public)")
            }
            slot.renderDidFinish(generation: generation, succeeded: error == nil, completion: completion)
        }
    }

    func clear(_ slot: PooledConversationView) {
        assign(nil, to: slot)
        slot.renderedInputs = nil
        slot.pendingRender = nil
        let waiters = slot.tracker.reset()
        if slot.isReady {
            slot.webView.evaluateJavaScript("window.ss.clear()") { _, _ in }
        }
        for waiter in waiters { waiter(false) }
    }

    // MARK: Web views

    private func makeWebView() -> WKWebView {
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = navigation
        webView.uiDelegate = navigation
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsMagnification = true
        // The desk behind the sheets (spec §4.1), also what shows while a render lands or the page overscrolls.
        webView.underPageBackgroundColor = .qCanvas
        webView.loadHTMLString(document, baseURL: ConversationShellAssets.baseURL)
        return webView
    }

    /// A crashed content process leaves a blank view; replacing it (and re-rendering through
    /// `onViewRecreated`) is invisible to the user apart from a repaint.
    private func recreate(_ webView: WKWebView) {
        guard let slot = slot(for: webView) else { return }
        ConversationSignposts.log.notice("web content process terminated; recreating view")
        assign(nil, to: slot)
        slot.replaceWebView(with: makeWebView())
        onViewRecreated?(slot)
    }

    // MARK: WKScriptMessageHandler

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let webView = message.webView, let slot = slot(for: webView) else { return }
        guard let parsed = ConversationScriptMessage(body: message.body) else { return }
        if message.name == ConversationShellAssets.readyHandlerName || parsed == .ready {
            markReady(slot)
            return
        }
        onMessage?(slot, parsed)
    }

    /// The shell announces readiness on both handlers; the second arrival must not replay a render. Scripts run
    /// in the order they are sent, so the preferences after the replay win over the queued payload's.
    private func markReady(_ slot: PooledConversationView) {
        guard !slot.isReady else { return }
        slot.isReady = true
        slot.webView.evaluateJavaScript(modesScript) { _, _ in }
        if let pending = slot.pendingRender {
            slot.pendingRender = nil
            render(pending.payload, inputs: pending.inputs, id: pending.id, into: slot, completion: pending.completion)
        }
        if !preferencesScript.isEmpty {
            slot.webView.evaluateJavaScript(preferencesScript) { _, _ in }
        }
        onReady?(slot)
    }
}
