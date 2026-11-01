import AppKit
import SSCore
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

    init(client: MailClient, size: Int = 3) {
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(ShellSchemeHandler(), forURLScheme: ConversationShellAssets.scheme)
        configuration.setURLSchemeHandler(InlineImageSchemeHandler(client: client), forURLScheme: RenderURLScheme.inlineImage)
        configuration.setURLSchemeHandler(AttachmentSchemeHandler(client: client), forURLScheme: RenderURLScheme.attachment)
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.suppressesIncrementalRendering = true
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
    func render(_ payload: RenderPayload, id: ConversationID, into slot: PooledConversationView, completion: @escaping (Bool) -> Void = { _ in }) {
        touch(slot)
        assign(id, to: slot)
        slot.renderedPayload = payload
        slot.generation &+= 1
        let generation = slot.generation
        guard slot.isReady else {
            slot.pendingRender = PooledConversationView.PendingRender(id: id, payload: payload, completion: completion)
            return
        }
        let json: String
        do {
            json = try payload.jsonString()
        } catch {
            ConversationSignposts.log.error("payload encoding failed: \(String(describing: error), privacy: .public)")
            completion(false)
            return
        }
        slot.renderInFlight = true
        let state = ConversationSignposts.begin(ConversationSignposts.render)
        slot.webView.evaluateJavaScript("window.ss.render(\(json))") { _, error in
            ConversationSignposts.end(ConversationSignposts.render, state)
            if let error {
                ConversationSignposts.log.error("render failed: \(String(describing: error), privacy: .public)")
            }
            guard slot.generation == generation else {
                completion(false)
                return
            }
            slot.renderInFlight = false
            completion(error == nil)
        }
    }

    func clear(_ slot: PooledConversationView) {
        assign(nil, to: slot)
        slot.renderedPayload = nil
        slot.pendingRender = nil
        slot.generation &+= 1
        slot.renderInFlight = false
        guard slot.isReady else { return }
        slot.webView.evaluateJavaScript("window.ss.clear()") { _, _ in }
    }

    // MARK: Web views

    private func makeWebView() -> WKWebView {
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = navigation
        webView.uiDelegate = navigation
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsMagnification = true
        webView.underPageBackgroundColor = .windowBackgroundColor
        webView.loadHTMLString(ConversationShellAssets.html, baseURL: ConversationShellAssets.baseURL)
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

    /// The shell announces readiness on both handlers; the second arrival must not replay a render.
    private func markReady(_ slot: PooledConversationView) {
        guard !slot.isReady else { return }
        slot.isReady = true
        if let pending = slot.pendingRender {
            slot.pendingRender = nil
            render(pending.payload, id: pending.id, into: slot, completion: pending.completion)
        }
        onReady?(slot)
    }
}
