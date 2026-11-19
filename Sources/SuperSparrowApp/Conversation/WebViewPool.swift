import AppKit
import SSCore
import SSDesign
import WebKit

/// Three warm web views sharing one configuration, on the app's one WebKit process pool.
///
/// Every view loads the shell once; a conversation is then one `ss.render` call. Slots remember which
/// conversation they hold so `show` of a pre-rendered id is a view swap. The slot on screen is never
/// handed out; among the rest the least recently used one is evicted first.
@MainActor
final class WebViewPool: NSObject, WKScriptMessageHandler {
    /// One configuration for every view of the pool, a copy of `template` (each view still runs in a WebContent process
    /// of its own).
    let configuration: WKWebViewConfiguration
    private(set) var slots: [PooledConversationView] = []
    /// Rendered conversation to slot, so showing a pre-rendered id is one lookup and a view swap.
    private var slotsByID: [ConversationID: PooledConversationView] = [:]
    /// The slot whose web view is on screen. Owned by the view controller; the pool only refuses to reuse it.
    var current: PooledConversationView?

    var onMessage: ((PooledConversationView, ConversationScriptMessage) -> Void)?
    var onReady: ((PooledConversationView) -> Void)?
    /// Edit › Copy and ⌘C in a slot's page while its keyboard focus is on an address in a sheet header (spec §5.14):
    /// copies it, or beeps.
    var onCopyFocusedAddress: ((PooledConversationView) -> Void)?
    /// Called after a content-process crash replaced the slot's web view, so the owner can re-render.
    var onViewRecreated: ((PooledConversationView) -> Void)?
    /// Called each time a render or an update lands in a slot's page, after its own completion.
    var onRenderLanded: ((PooledConversationView) -> Void)?

    private let navigation = ConversationNavigationPolicy()
    private var tick: UInt64 = 0
    /// The shell with the reader symbols rasterised into it once for the pool (spec §4.11), in the theme the pool was made
    /// in, so a new reader window's shell paints its first frame in it. A view made later (after a crash) may load it in
    /// an older theme; `markReady` tells it the current one before anything renders. Internal so tests can read it.
    let document: String
    /// The script that mirrors the display modes onto a shell, kept so a slot that becomes ready gets it too.
    private var modesScript = ""
    /// The theme the shells draw in (spec §4.16), and the script that tells a shell, kept for the slots that become ready.
    private var theme: QuireTheme
    private var themeScript: String
    /// For tests: every ready shell has restyled itself in the theme. Nil in the app.
    var onThemed: ((QuireTheme) -> Void)?
    /// The last preferences told to the shells (Font, colours notice). A slot still loading its shell misses the
    /// broadcast and later replays a payload built before it, so `markReady` sends this after that replay.
    private var preferencesScript = ""
    /// Full Keyboard Access is a keyboard setting, not a display option, so QuireEnvironment never reports it.
    private var fullKeyboardAccessObservation: NSKeyValueObservation?
    /// The app's appearance (Settings › Appearance, or macOS under Automatic), which AppKit tells no view outside a window.
    private var appearanceObservation: NSKeyValueObservation?

    init(client: MailClient, size: Int = 3) {
        let theme = QuireEnvironment.theme
        let shellTheme = ShellTheme(theme)
        let document = ConversationShellAssets.document(symbolCSS: ReaderSymbolSheet.css, theme: shellTheme)
        self.document = document
        self.theme = theme
        themeScript = shellTheme.script
        let configuration = Self.newConfiguration()
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
        // The next turn, once the windows have taken the new appearance the views outside them are to share.
        appearanceObservation = NSApp.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.pinWindowless(to: self.windowAppearance)
                }
            }
        }
    }

    /// The configuration every pool's is copied from, for the WebKit process pool a copy shares with it. WebKit sends each
    /// new WebContent process the fonts the user installed, and reads them from the font server (every font's properties,
    /// over a synchronous XPC call) once per process pool, on the main thread, in the first load of a view on a pool it
    /// has not read them for. A configuration made afresh has a pool of its own, so every reader window paid that read
    /// again, about 15 ms of its ⌘O (§5.49), where the main window's three views pay it once between them. On this one
    /// pool the app pays it once.
    private static let template: WKWebViewConfiguration = {
        let configuration = WKWebViewConfiguration()
        // WebKit makes a configuration's process pool with the first view made from it; copies made after that share it.
        _ = WKWebView(frame: .zero, configuration: configuration)
        return configuration
    }()

    /// A configuration of the pool's own on the app's process pool. A copy shares its source's user content controller and
    /// preferences as well, so it is given its own: the handlers answer this pool's views alone, and Full Keyboard Access
    /// is switched pool by pool, as when each pool made its configuration afresh.
    private static func newConfiguration() -> WKWebViewConfiguration {
        let configuration = template.copy() as! WKWebViewConfiguration
        configuration.userContentController = WKUserContentController()
        configuration.preferences = WKPreferences()
        configuration.defaultWebpagePreferences = WKWebpagePreferences()
        return configuration
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
        themeMayHaveChanged()
        // Increase Contrast and the theme change `canvas` without changing the appearance.
        for slot in slots { (slot.webView as? ReaderWebView)?.updateUnderPageColour() }
        updateTabFocusesLinks()
    }

    /// A theme switch replaces one style element in every ready shell and its bodies: no reload, nothing measured. The
    /// interval (the theme budget in docs/ARCHITECTURE.md) ends with the last shell's reply, which follows its `themed`,
    /// posted once style is resolved in every document.
    private func themeMayHaveChanged() {
        let theme = QuireEnvironment.theme
        guard theme != self.theme else { return }
        self.theme = theme
        themeScript = ShellTheme(theme).script
        let interval = ConversationSignposts.begin(ConversationSignposts.theme)
        broadcast(themeScript) { [weak self] in
            ConversationSignposts.end(ConversationSignposts.theme, interval)
            self?.onThemed?(theme)
        }
    }

    /// Tells every ready shell the reader's preferences and keeps them for the shells that become ready later.
    /// `ran`, when given, runs once every ready shell has run them.
    func broadcastPreferences(_ script: String, ran: (() -> Void)? = nil) {
        preferencesScript = script
        broadcast(script, ran: ran)
    }

    /// Runs `script` in every shell that is ready; slots that become ready later get the modes and the
    /// preferences on `markReady`. `ran`, when given, runs once the last of them has run it (or failed to), at once
    /// when none is ready.
    func broadcast(_ script: String, ran: (() -> Void)? = nil) {
        let ready = slots.filter(\.isReady)
        let left = Countdown(ready.count, then: ran)
        for slot in ready {
            slot.webView.evaluateJavaScript(script) { _, error in
                if let error {
                    ConversationSignposts.log.error("shell broadcast failed: \(String(describing: error), privacy: .public)")
                }
                left.tick()
            }
        }
    }

    /// Runs its closure once `tick()` has been called `count` times; at once for none.
    private final class Countdown {
        private var count: Int
        private var then: (() -> Void)?

        init(_ count: Int, then: (() -> Void)?) {
            self.count = count
            self.then = then
            if count == 0 { fire() }
        }

        func tick() {
            count -= 1
            if count == 0 { fire() }
        }

        private func fire() {
            let then = then
            self.then = nil
            then?()
        }
    }

    // MARK: Appearance

    /// The appearance the reader's window draws in: the shown view's, else the app's.
    private var windowAppearance: NSAppearance {
        if let webView = current?.webView, webView.window != nil { return webView.effectiveAppearance }
        return NSApp.effectiveAppearance
    }

    /// AppKit tells a view of a new appearance only while it is in a window, and WebKit turns `prefers-color-scheme` for
    /// a page only when AppKit tells its view. The slots outside the window (pre-rendered neighbours, a slot taken off
    /// screen) would keep the old appearance until shown, then restyle in front of the reader, a styled message gaining
    /// or losing its white page and refitting on its first frames. So each takes the window's appearance as its own, and
    /// restyles out of sight.
    func pinWindowless(to appearance: NSAppearance) {
        for slot in slots where slot.webView.window == nil && slot.webView.appearance?.name != appearance.name {
            slot.webView.appearance = appearance
        }
    }

    /// Takes `slot`'s view out of the window it is shown in, keeping the appearance it drew in there, so it is not
    /// restyled on the way out and again on the way back.
    func park(_ slot: PooledConversationView) {
        let webView = slot.webView
        webView.appearance = webView.effectiveAppearance
        webView.removeFromSuperview()
    }

    /// `slot`'s view is in the window now: it follows the window again, and the views outside take its appearance.
    func unpark(_ slot: PooledConversationView) {
        let webView = slot.webView
        webView.appearance = nil
        if webView.window != nil { pinWindowless(to: webView.effectiveAppearance) }
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
        slot.webView.evaluateJavaScript("\(function)(\(json))") { [weak self] _, error in
            ConversationSignposts.end(ConversationSignposts.render, state)
            if let error {
                ConversationSignposts.log.error("render failed: \(String(describing: error), privacy: .public)")
            }
            slot.renderDidFinish(generation: generation, succeeded: error == nil, completion: completion)
            if error == nil { self?.onRenderLanded?(slot) }
        }
    }

    func clear(_ slot: PooledConversationView) {
        assign(nil, to: slot)
        slot.renderedInputs = nil
        slot.pendingRender = nil
        slot.originalColorsShown = []
        let waiters = slot.tracker.reset()
        if slot.isReady {
            slot.webView.evaluateJavaScript("window.ss.clear()") { _, _ in }
        }
        for waiter in waiters { waiter(false) }
    }

    // MARK: Web views

    private func makeWebView() -> WKWebView {
        let webView = ReaderWebView(frame: .zero, configuration: configuration)
        webView.onWindowAppearanceChange = { [weak self] appearance in self?.pinWindowless(to: appearance) }
        webView.hasFocusedAddress = { [weak self, weak webView] in
            guard let self, let webView else { return false }
            return self.slot(for: webView)?.focusedAddress != nil
        }
        webView.copyFocusedAddress = { [weak self, weak webView] in
            guard let self, let webView, let slot = self.slot(for: webView) else { return }
            self.onCopyFocusedAddress?(slot)
        }
        webView.navigationDelegate = navigation
        webView.uiDelegate = navigation
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsMagnification = true
        // The desk behind the sheets (spec §4.1), also what shows while a render lands or the page overscrolls.
        webView.updateUnderPageColour()
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
        if slot.webView.window == nil { slot.webView.appearance = windowAppearance }
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
    /// in the order they are sent, so the preferences after the replay win over the queued payload's, and the theme,
    /// sent before the replay, is the one the first render paints in (a shell loaded in an older theme included).
    private func markReady(_ slot: PooledConversationView) {
        guard !slot.isReady else { return }
        slot.isReady = true
        slot.webView.evaluateJavaScript(modesScript) { _, _ in }
        slot.webView.evaluateJavaScript(themeScript) { _, _ in }
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
