import AppKit
import PaperCore
import PaperDesign
import WebKit

/// Prints a conversation's print document (spec §5.48) through the system print panel, whose PDF menu saves it.
///
/// The document goes into a web view of its own rather than one of the reader's pool: the pooled views are sized for the
/// screen, may be dark, may be in a theme, and are busy pre-rendering, while this one is Aqua, as the paper is light
/// whatever the app shows, and lives only for one print. A printout is paper in Study's light values whatever the theme
/// (spec §5.48): the print document carries the Quire head alone, never the reader's `<style id="ss-theme">`. It serves inline images through the reader's own scheme handler, so they print as the
/// reader shows them, and navigates nowhere but its document. JavaScript is on for the document's own script, the one
/// its policy lets run (`PrintDocumentAssets.scriptPolicy`). The print operation runs as a sheet on the window, the one
/// way WebKit's printing view lays out its pages (run synchronously it keeps asking for pages it has not measured).
@MainActor
final class ConversationPrinter: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    /// Where a print goes: the panel, or straight to a PDF file with no panel, for the tests and the print renders.
    enum Destination: Equatable {
        case panel
        case file(URL)
    }

    /// One print on its way: the web view stays alive until the operation has run.
    @MainActor
    private final class Job {
        let webView: WKWebView
        let title: String
        weak var window: NSWindow?
        let destination: Destination
        var fallback: Timer?
        var printing = false

        init(webView: WKWebView, title: String, window: NSWindow, destination: Destination) {
            self.webView = webView
            self.title = title
            self.window = window
            self.destination = destination
        }
    }

    var destination: Destination = .panel
    /// Block trackers (spec §5.60), set by the reader before each print: while on, the print view carries the content
    /// blocker, as the reader's views do, and its document holds marked trackers back itself.
    var blocksTrackers = false
    /// Where the content blocker comes from: the app's, or a test's; reached only for a print while Block trackers is on.
    lazy var trackerRules = TrackerContentRules.shared
    /// The content blocker in the configuration now, if any.
    private var installedTrackerRules: WKContentRuleList?
    /// Told when a print ends, whether it ran (false when it was cancelled, failed, or its window went away).
    var onFinish: ((Bool) -> Void)?
    private let configuration: WKWebViewConfiguration
    private var job: Job?
    /// The paper chosen in the panel, kept for the next print while the app runs: its size, orientation and scale only,
    /// never where the last job went (Save as PDF leaves a file destination behind) or how many copies it made.
    private var paperChoice: (size: NSSize, orientation: NSPrintInfo.PaperOrientation, scale: Any?)?

    /// A printout is being prepared or its panel is up; Print… waits for it.
    var isBusy: Bool { job != nil }
    /// The print operation has begun: the document said it was ready, or never did in time, and what it shows now is
    /// what prints.
    var isPrinting: Bool { job?.printing == true }

    /// `schemeHandlers` are the tests' stand-ins for the network: a scheme of their own that counts what a printout fetches,
    /// or one in place of the inline images' (`ss-cid`), to answer them as slowly as a download would.
    init(client: MailClient, schemeHandlers: [String: WKURLSchemeHandler] = [:]) {
        let configuration = WKWebViewConfiguration()
        if schemeHandlers[RenderURLScheme.inlineImage] == nil {
            configuration.setURLSchemeHandler(InlineImageSchemeHandler(client: client), forURLScheme: RenderURLScheme.inlineImage)
        }
        for (scheme, handler) in schemeHandlers { configuration.setURLSchemeHandler(handler, forURLScheme: scheme) }
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.preferences.shouldPrintBackgrounds = true
        // Incremental rendering stays on: suppressed, WebKit paints nothing until the page's load has ended, which an
        // image that never comes holds off, and the page would print blank once its wait was over.
        self.configuration = configuration
        super.init()
        configuration.userContentController.add(WeakScriptMessageHandler(target: self), name: PrintDocumentBuilder.readyHandlerName)
    }

    /// Loads `document` and, once its bodies are attached and their images in (or the wait is over), runs the print
    /// operation as a sheet on `window`. Returns false, starting nothing, while another print is on its way.
    @discardableResult
    func print(_ document: String, title: String, imageWait: TimeInterval, on window: NSWindow) -> Bool {
        guard job == nil else { return false }
        let page = paper()
        let width = page.paperSize.width - page.leftMargin - page.rightMargin
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: max(320, width), height: page.paperSize.height), configuration: configuration)
        // WebKit lays a page out for print in a light appearance whatever its view's; Aqua makes the layout before
        // printing, which decides what loads, the same one.
        webView.appearance = NSAppearance(named: .aqua)
        webView.navigationDelegate = self
        let job = Job(webView: webView, title: title, window: window, destination: destination)
        self.job = job
        withTrackerRules { [weak self, weak job] in
            guard let self, let job, self.job === job else { return }
            // The document says when it is ready, after two image waits at most (`PrintDocumentAssets.script`); this is for
            // a page that never does (its script failed, its process ended).
            job.fallback = Timer.scheduledTimer(withTimeInterval: 2 * imageWait + 2, repeats: false) { [weak self, weak job] _ in
                MainActor.assumeIsolated {
                    guard let self, let job, self.job === job else { return }
                    self.runOperation(for: job)
                }
            }
            webView.loadHTMLString(document, baseURL: nil)
        }
        return true
    }

    /// Puts the content blocker in the configuration while Block trackers is on, and takes it out while it is off, before
    /// `then` loads the document. The list is almost always compiled already (the reader asked for it when the setting
    /// came on); when it cannot be had the document still holds the marked trackers back.
    private func withTrackerRules(_ then: @escaping () -> Void) {
        let controller = configuration.userContentController
        guard blocksTrackers else {
            if let installed = installedTrackerRules { controller.remove(installed) }
            installedTrackerRules = nil
            return then()
        }
        guard installedTrackerRules == nil else { return then() }
        trackerRules.list { [weak self] list in
            if let self, let list, self.installedTrackerRules == nil {
                controller.add(list)
                self.installedTrackerRules = list
            }
            then()
        }
    }

    // MARK: Printing

    /// The print info a print starts from: the app's, on the paper last chosen, with the printout's margins
    /// (`layout.print.pageMargin`).
    private func paper() -> NSPrintInfo {
        let info = NSPrintInfo.shared.copy() as? NSPrintInfo ?? NSPrintInfo()
        if let choice = paperChoice {
            info.paperSize = choice.size
            info.orientation = choice.orientation
            if let scale = choice.scale { info.dictionary()[NSPrintInfo.AttributeKey.scalingFactor] = scale }
        }
        let margin = Quire.Layout.Print.pageMargin
        info.topMargin = margin
        info.bottomMargin = margin
        info.leftMargin = margin
        info.rightMargin = margin
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        return info
    }

    private func runOperation(for job: Job) {
        guard !job.printing else { return }
        job.fallback?.invalidate()
        job.fallback = nil
        guard let window = job.window, window.isVisible || job.destination != .panel else {
            finish(job, ran: false)
            return
        }
        job.printing = true
        let info = paper()
        if case .file(let url) = job.destination {
            info.jobDisposition = .save
            info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url
        }
        let operation = job.webView.printOperation(with: info)
        operation.jobTitle = job.title
        operation.showsPrintPanel = job.destination == .panel
        operation.showsProgressPanel = job.destination == .panel
        operation.printPanel.options.formUnion([.showsPaperSize, .showsOrientation, .showsScaling, .showsPreview])
        // WebKit's printing view sizes itself from the print info, but only once it has a frame to start from.
        operation.view?.frame = job.webView.bounds
        operation.runModal(for: window, delegate: self, didRun: #selector(printOperationDidRun(_:success:contextInfo:)), contextInfo: nil)
    }

    @objc private func printOperationDidRun(_ operation: NSPrintOperation, success: Bool, contextInfo: UnsafeMutableRawPointer?) {
        guard let job else { return }
        if success, job.destination == .panel {
            let chosen = operation.printInfo
            paperChoice = (chosen.paperSize, chosen.orientation, chosen.dictionary()[NSPrintInfo.AttributeKey.scalingFactor])
        }
        finish(job, ran: success)
    }

    private func finish(_ job: Job, ran: Bool) {
        guard self.job === job else { return }
        job.fallback?.invalidate()
        job.webView.navigationDelegate = nil
        job.webView.stopLoading()
        self.job = nil
        onFinish?(ran)
    }

    // MARK: WKScriptMessageHandler

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let job, message.webView === job.webView, message.name == PrintDocumentBuilder.readyHandlerName else { return }
        runOperation(for: job)
    }

    // MARK: WKNavigationDelegate

    /// The document is the only page this view shows; a body cannot navigate (no script of its own runs), and nothing
    /// else may.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let initial = navigationAction.navigationType == .other && navigationAction.targetFrame?.isMainFrame == true
            && navigationAction.request.url?.scheme?.lowercased() == "about"
        decisionHandler(initial ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard let job, job.webView === webView, !job.printing else { return }
        finish(job, ran: false)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard let job, job.webView === webView, !job.printing else { return }
        finish(job, ran: false)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard let job, job.webView === webView, !job.printing else { return }
        finish(job, ran: false)
    }
}
