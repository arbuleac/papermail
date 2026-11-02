import AppKit
import SSCore
import WebKit
import os

/// Application lifecycle: builds the environment for the launch mode, owns the main and settings windows,
/// runs sign-in, and keeps the app alive with no windows open, as mail clients do.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let log = Logger(subsystem: "io.supersparrow.mac", category: "shell")

    private let options: LaunchOptions
    private let settings = AppSettings.shared
    private var environment: AppEnvironment?
    private var mainWindow: MainWindowController?
    private var settingsWindow: SettingsWindowController?
    private var galleryWindow: DesignGalleryWindowController?
    /// Snapshots still to write before a `--snapshot-gallery/-welcome/-settings` launch quits.
    private var pendingQuittingSnapshots = 0
    private var signInTask: Task<Void, Never>?
    /// Tells a sign-in's completion whether it is still the current one; a replaced or cancelled sign-in must
    /// not clear the progress line of the one that took its place.
    private var signInGeneration = 0
    private var isTerminating = false

    init(options: LaunchOptions) {
        self.options = options
        super.init()
    }

    // MARK: NSApplicationDelegate

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.build(appDelegate: self)
        switch options.appearance {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: break
        }
        if options.resetDemo { AppEnvironment.wipeDemoData() }
        if options.needsMailEnvironment {
            start(mode: options.demo ? .demo : .real)
        }
        NSApp.activate()
        if options.snapshotPath != nil || options.composeSnapshotPath != nil {
            runSnapshots(main: options.snapshotPath, compose: options.composeSnapshotPath)
        }
        runQuittingSnapshots()
        #if DEBUG
        if options.gallery { showDesignGallery(nil) }
        #endif
    }

    // MARK: Snapshots (debug aid)

    /// In demo mode: waits for the inbox, opens its first conversation, waits for the reader's render to
    /// land, then writes the window (reader composited in) and, when asked, a reply composer. Outside demo
    /// mode the window is written as it is after a few seconds.
    private func runSnapshots(main: String?, compose: String?) {
        guard options.demo else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, let main else { return }
                    self.writeWindowSnapshot(to: main, reader: nil)
                }
            }
            return
        }
        waitForInbox(deadline: Date().addingTimeInterval(20)) { [weak self] in
            guard let self, let window = self.mainWindow else { return }
            window.selectFirstConversation()
            window.whenReaderSettles(timeout: 10) { webView in
                // Frames size themselves and inline images load after the render lands.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    MainActor.assumeIsolated {
                        self.captureReader(webView) { image in
                            if let main { self.writeWindowSnapshot(to: main, reader: image.map { ($0, webView) }) }
                            if let compose { self.writeComposeSnapshot(to: compose) }
                        }
                    }
                }
            }
        }
    }

    private func waitForInbox(deadline: Date, then: @escaping () -> Void) {
        if mainWindow?.hasConversations == true || Date() > deadline {
            then()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            MainActor.assumeIsolated { self?.waitForInbox(deadline: deadline, then: then) }
        }
    }

    private func captureReader(_ webView: WKWebView?, completion: @escaping (NSImage?) -> Void) {
        guard let webView else {
            Self.log.error("snapshot: the reader never rendered; writing the window without it")
            completion(nil)
            return
        }
        webView.takeSnapshot(with: nil) { image, error in
            if let error { Self.log.error("snapshot: web view capture failed: \(error.localizedDescription, privacy: .public)") }
            completion(image)
        }
    }

    /// `cacheDisplay` cannot draw WKWebView content, so the reader's own snapshot is drawn over its frame.
    private func writeWindowSnapshot(to path: String, reader: (image: NSImage, webView: WKWebView?)?) {
        guard let view = mainWindow?.window?.contentView?.superview ?? mainWindow?.window?.contentView,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        if let reader, let webView = reader.webView, webView.window === view.window,
           let context = NSGraphicsContext(bitmapImageRep: bitmap) {
            var frame = webView.convert(webView.bounds, to: view)
            if view.isFlipped { frame.origin.y = view.bounds.height - frame.maxY }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            reader.image.draw(in: frame, from: .zero, operation: .sourceOver, fraction: 1)
            NSGraphicsContext.restoreGraphicsState()
        }
        writePNG(bitmap, to: path)
    }

    private func writeComposeSnapshot(to path: String) {
        guard mainWindow?.openReplyComposer() == true else {
            Self.log.error("snapshot: no conversation to reply to")
            return
        }
        // Let the composer lay out and load the quoted original.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            MainActor.assumeIsolated {
                guard let window = ComposeWindowRegistry.shared.openControllers.first?.window,
                      let view = window.contentView?.superview ?? window.contentView,
                      let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                    Self.log.error("snapshot: no composer window")
                    return
                }
                view.cacheDisplay(in: view.bounds, to: bitmap)
                self.writePNG(bitmap, to: path)
            }
        }
    }

    private func writePNG(_ bitmap: NSBitmapImageRep, to path: String) {
        SnapshotRenderer.writePNG(bitmap, to: path)
    }

    // MARK: Snapshots that quit (debug aid)

    /// `--snapshot-gallery`, `--snapshot-welcome` and `--snapshot-settings` each write one PNG; once all of
    /// them have, the app quits, unless `--snapshot` or `--snapshot-compose` (which never quit) are running too.
    private func runQuittingSnapshots() {
        var jobs: [(String?, (String) -> Void)] = []
        #if DEBUG
        // The design gallery is a debug-build tool (Debug › Design Gallery).
        jobs.append((options.gallerySnapshotPath, writeGallerySnapshot))
        #endif
        jobs.append((options.welcomeSnapshotPath, writeWelcomeSnapshot))
        jobs.append((options.settingsSnapshotPath, writeSettingsSnapshot))
        let requested = jobs.compactMap { path, job in path.map { (path: $0, job: job) } }
        // Counted before any starts, so an early finisher cannot quit while the others are still queued.
        pendingQuittingSnapshots = requested.count
        for (path, job) in requested { job(path) }
    }

    private func quittingSnapshotFinished() {
        pendingQuittingSnapshots -= 1
        guard pendingQuittingSnapshots == 0, options.snapshotPath == nil, options.composeSnapshotPath == nil else { return }
        // Not from inside a main-queue callout: with an environment open, terminate waits (terminateLater) in a
        // nested run loop for a main-actor task to reply, and a nested loop cannot drain the queue it was
        // entered from, so terminating from a dispatch block would hang. A run-loop block can.
        RunLoop.main.perform {
            MainActor.assumeIsolated { NSApp.terminate(nil) }
        }
    }

    /// The whole design gallery page, in the forced appearance.
    private func writeGallerySnapshot(to path: String) {
        DesignGalleryWindowController.renderSnapshot(appearance: NSApp.appearance) { [weak self] bitmap in
            if let bitmap { SnapshotRenderer.writePNG(bitmap, to: path) }
            self?.quittingSnapshotFinished()
        }
    }

    /// The main window's welcome screen, over a throwaway empty store in a temporary directory: the user's
    /// mail database, Keychain and saved window frame are never touched.
    private func writeWelcomeSnapshot(to path: String) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SuperSparrow-welcome-\(UUID().uuidString)", isDirectory: true)
        let scratch: AppEnvironment
        do {
            scratch = try AppEnvironment.makeScratch(in: directory)
        } catch {
            Self.log.error("snapshot: no scratch store: \(error.localizedDescription, privacy: .public)")
            try? FileManager.default.removeItem(at: directory)
            quittingSnapshotFinished()
            return
        }
        let controller = MainWindowController(environment: scratch, settings: settings)
        // Detach from the real main window's saved frame before sizing, so the snapshot is always the default
        // size and never rewrites the user's frame.
        controller.window?.setFrameAutosaveName("")
        controller.window?.setContentSize(MainWindowController.defaultSize)
        controller.showWindow(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            MainActor.assumeIsolated {
                if let window = controller.window, let bitmap = SnapshotRenderer.render(window: window) {
                    SnapshotRenderer.writePNG(bitmap, to: path)
                } else {
                    Self.log.error("snapshot: the welcome window did not render")
                }
                controller.tearDown()
                controller.close()
                Task { @MainActor in
                    await scratch.shutdown()
                    try? FileManager.default.removeItem(at: directory)
                    self?.quittingSnapshotFinished()
                }
            }
        }
    }

    /// Every Settings tab in demo mode, one under the other. Waits for the demo inbox so the Accounts tab
    /// shows rows, not the empty state.
    private func writeSettingsSnapshot(to path: String) {
        waitForInbox(deadline: Date().addingTimeInterval(20)) { [weak self] in
            guard let self else { return }
            self.openSettings()
            guard let controller = self.settingsWindow else {
                Self.log.error("snapshot: no settings window")
                self.quittingSnapshotFinished()
                return
            }
            let tabs: [SettingsModel.Tab] = [.accounts, .oauth, .general]
            var bitmaps: [NSBitmapImageRep] = []
            @MainActor func capture(_ index: Int) {
                guard index < tabs.count else {
                    let appearance = controller.window?.effectiveAppearance ?? NSApp.effectiveAppearance
                    if let sheet = SnapshotRenderer.stack(bitmaps, appearance: appearance) {
                        SnapshotRenderer.writePNG(sheet, to: path)
                    }
                    self.quittingSnapshotFinished()
                    return
                }
                controller.model.tab = tabs[index]
                // Let SwiftUI swap the tab and lay it out before drawing it.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    MainActor.assumeIsolated {
                        if let window = controller.window, let bitmap = SnapshotRenderer.render(window: window) {
                            bitmaps.append(bitmap)
                        }
                        capture(index + 1)
                    }
                }
            }
            // Statuses settle a moment after the inbox fills.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                MainActor.assumeIsolated { capture(0) }
            }
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        environment?.engine.syncNow(accountID: nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { mainWindow?.showWindow(nil) }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let environment, !isTerminating else { return .terminateNow }
        isTerminating = true
        // Let in-flight writes finish so the next launch resumes from a consistent store, but never hang quitting.
        var replied = false
        let reply = {
            guard !replied else { return }
            replied = true
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        Task {
            await environment.shutdown()
            reply()
        }
        Task {
            try? await Task.sleep(for: .seconds(2))
            reply()
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        environment?.engine.stop()
    }

    // MARK: Environment

    private func start(mode: AppEnvironment.Mode) {
        let environment: AppEnvironment
        do {
            environment = try AppEnvironment.make(mode: mode, settings: settings)
        } catch {
            Self.log.fault("could not open the mail database: \(String(describing: error), privacy: .public)")
            let alert = NSAlert()
            alert.messageText = "SuperSparrow couldn't open its mail database"
            alert.informativeText = "\(error.localizedDescription)\n\nThe database lives in ~/Library/Application Support/SuperSparrow."
            alert.addButton(withTitle: "Quit")
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        self.environment = environment
        environment.start()

        let window = MainWindowController(environment: environment, settings: settings)
        window.onAddAccount = { [weak self] kind in self?.addAccount(kind) }
        window.onReconnect = { [weak self] account in self?.addAccount(account.kind, reconnecting: account) }
        window.onOpenSettings = { [weak self] in self?.openSettings() }
        window.onOpenAccountsSettings = { [weak self] in self?.openSettings(tab: .accounts) }
        window.onTryDemo = { [weak self] in self?.switchToDemo() }
        window.onCancelSignIn = { [weak self] in self?.cancelSignIn() }
        window.onLeaveDemo = { [weak self] in self?.leaveDemo() }
        mainWindow = window
        window.showWindow(nil)
        if environment.isDemo {
            // Demo accounts arrive through addAccount like real ones; ask now so notifications work in the demo too.
            window.notifier.requestAuthorizationIfNeeded()
        }
    }

    /// "Try the demo" from the welcome screen: swap the whole graph in place instead of relaunching.
    private func switchToDemo() {
        guard let old = environment, !old.isDemo else { return }
        signInTask?.cancel()
        mainWindow?.tearDown()
        mainWindow = nil
        settingsWindow?.tearDown()
        settingsWindow = nil
        environment = nil
        Task {
            await old.shutdown()
            self.start(mode: .demo)
        }
    }

    /// Leave Demo (§5.43), confirmed by the main window's sheet: the demo store is wiped and the welcome
    /// screen returns over the real store.
    private func leaveDemo() {
        guard let old = environment, old.isDemo else { return }
        signInTask?.cancel()
        mainWindow?.tearDown()
        mainWindow = nil
        settingsWindow?.tearDown()
        settingsWindow = nil
        environment = nil
        Task {
            await old.shutdown()
            AppEnvironment.wipeDemoData()
            self.start(mode: .real)
        }
    }

    // MARK: Accounts

    /// Starts a browser sign-in. With no kind given, asks which service first.
    func addAccount(_ kind: ProviderKind?, reconnecting: Account? = nil) {
        guard let environment else { return }
        guard let kind = kind ?? chooseProvider() else { return }
        if !environment.isDemo {
            do {
                _ = try environment.clientConfigurations.configuration(for: kind)
            } catch AuthError.missingClientConfiguration {
                let name = kind == .gmail ? "Google" : "Microsoft"
                openSettings(tab: .oauth, notice: "To add a \(kind == .gmail ? "Gmail" : "Microsoft") account, SuperSparrow needs your own \(name) OAuth client ID. Enter it below and click Save, then try again. docs/OAUTH-SETUP.md walks through creating one.")
                return
            } catch {
                showError(error, context: "Your OAuth settings could not be read")
                openSettings(tab: .oauth, notice: Self.message(for: error))
                return
            }
        }
        signInTask?.cancel()
        signInGeneration += 1
        let generation = signInGeneration
        let message = environment.isDemo ? "Adding demo account…" : "Finish signing in in your browser…"
        setSignInBusy(message)
        let knownIDs = Set(((try? environment.engine.accounts()) ?? []).map(\.id))
        signInTask = Task { [weak self] in
            do {
                let account: Account
                if let reconnecting {
                    account = try await environment.engine.reconnect(reconnecting)
                } else {
                    account = try await environment.engine.addAccount(kind: kind)
                }
                guard let self else { return }
                Self.log.info("account ready: \(account.id.rawValue, privacy: .public)")
                if reconnecting == nil, knownIDs.contains(account.id) {
                    // The browser signed in to a mailbox that is already here (often its own session):
                    // say so, or the add looks like it did nothing.
                    self.showNotice(
                        "\(account.email) is already in SuperSparrow",
                        detail: "Its sign-in was renewed. To add another account, pick it in the browser's account chooser, or sign out of \(account.email) there first."
                    )
                }
                if self.signInGeneration == generation { self.setSignInBusy(nil) }
                self.mainWindow?.notifier.requestAuthorizationIfNeeded()
                self.mainWindow?.refreshAccounts()
                self.settingsWindow?.refreshAccounts()
                if reconnecting == nil { self.mainWindow?.showWindow(nil) }
            } catch {
                guard let self else { return }
                if self.signInGeneration == generation { self.setSignInBusy(nil) }
                if Self.isCancellation(error) { return }
                self.showError(error, context: reconnecting == nil ? "Couldn't add the account" : "Couldn't reconnect \(reconnecting?.email ?? "the account")")
            }
        }
    }

    /// The welcome screen's Cancel: stops waiting for the browser. OAuthFlow turns the cancellation into
    /// `userCancelled`, which the sign-in task treats as a quiet end.
    private func cancelSignIn() {
        signInTask?.cancel()
        signInTask = nil
        signInGeneration += 1
        setSignInBusy(nil)
    }

    private func setSignInBusy(_ message: String?) {
        mainWindow?.setSignInInProgress(message)
        settingsWindow?.model.busyMessage = message
    }

    private func chooseProvider() -> ProviderKind? {
        let alert = NSAlert()
        alert.messageText = "Add an account"
        alert.informativeText = "Which kind of account? You'll sign in in your browser; SuperSparrow never sees your password."
        alert.addButton(withTitle: "Gmail")
        alert.addButton(withTitle: "Microsoft")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .gmail
        case .alertSecondButtonReturn: return .microsoft
        default: return nil
        }
    }

    private func removeAccount(_ account: Account) {
        guard let environment else { return }
        let alert = NSAlert()
        alert.messageText = "Remove \(account.email)?"
        alert.informativeText = "Its mail is deleted from this Mac and its sign-in is removed from the Keychain. Nothing is deleted on the server."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task { [weak self] in
            do {
                try await environment.engine.removeAccount(account.id)
            } catch {
                self?.showError(error, context: "Couldn't remove the account")
            }
            self?.mainWindow?.refreshAccounts()
            self?.settingsWindow?.refreshAccounts()
        }
    }

    // MARK: Errors

    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if case AuthError.userCancelled = error { return true }
        if case ProviderError.cancelled = error { return true }
        return false
    }

    static func message(for error: Error) -> String {
        switch error {
        case AuthError.missingClientConfiguration(let kind):
            return "No \(kind == .gmail ? "Google" : "Microsoft") OAuth client is configured. Add one in Settings → OAuth."
        case AuthError.invalidResponse(let detail):
            return "The sign-in response wasn't what SuperSparrow expected. \(detail)"
        case AuthError.tokenExchangeFailed(let detail):
            return "The provider refused the sign-in. Check the client ID (and secret for Google) in Settings → OAuth.\n\n\(detail)"
        case AuthError.refreshFailed(let detail):
            return "Your sign-in expired and couldn't be renewed. \(detail)"
        case AuthError.keychain(let status):
            return "The Keychain refused to store the sign-in (status \(status))."
        case AuthError.wrongAccount(let expected, let actual):
            return "You signed in as \(actual), but this account is \(expected). Nothing was changed; reconnect again and choose \(expected)."
        case ProviderError.unauthorized:
            return "The account refused access. Make sure you granted mail permissions when signing in."
        case ProviderError.network(let detail):
            return "Couldn't reach the mail server. Check your internet connection.\n\n\(detail)"
        case ProviderError.throttled:
            return "The mail service is rate limiting requests. Try again in a minute."
        case ProviderError.server(let status, let message):
            return "The mail service returned an error (\(status)). \(message)"
        case let urlError as URLError:
            return "Couldn't reach the server: \(urlError.localizedDescription)"
        default:
            return error.localizedDescription
        }
    }

    private func showNotice(_ message: String, detail: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.addButton(withTitle: "OK")
        if let window = mainWindow?.window, window.isVisible {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    private func showError(_ error: Error, context: String) {
        Self.log.error("\(context, privacy: .public): \(String(describing: error), privacy: .public)")
        let alert = NSAlert()
        alert.messageText = context
        alert.informativeText = Self.message(for: error)
        alert.addButton(withTitle: "OK")
        if let window = mainWindow?.window, window.isVisible {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    // MARK: Settings

    private func openSettings(tab: SettingsModel.Tab? = nil, notice: String? = nil) {
        guard let environment else { return }
        if settingsWindow == nil {
            let controller = SettingsWindowController(environment: environment, settings: settings)
            controller.model.addAccount = { [weak self] kind in self?.addAccount(kind) }
            controller.model.removeAccount = { [weak self] account in self?.removeAccount(account) }
            controller.model.reconnect = { [weak self] account in self?.addAccount(account.kind, reconnecting: account) }
            settingsWindow = controller
        }
        settingsWindow?.show(tab: tab, notice: notice)
    }

    // MARK: Menu actions

    @objc func showSettings(_ sender: Any?) {
        openSettings()
    }

    @objc func newMessage(_ sender: Any?) {
        mainWindow?.composeNew()
    }

    @objc func addAccountFromMenu(_ sender: Any?) {
        addAccount(nil)
    }

    @objc func showKeyboardHelp(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Keyboard Shortcuts"
        alert.informativeText = """
        j / k or ↓ / ↑   next / previous conversation
        Return   open the conversation
        e   archive          s   star          u   read / unread
        #  or ⌘⌫   trash     ⇧I  or ⇧⌘I   move to inbox
        z  or ⌘Z   undo the last action
        r   reply     a   reply all     f   forward     c   compose
        /  or ⌘F   search     Esc   clear search (also from the list)
        g i  inbox     g s  starred     g t  sent     g a  all mail
        ⌘0   all inboxes     ⌘1…⌘9   one account     ⌘\\   focused inbox
        """
        alert.runModal()
    }

    @objc func showOAuthHelp(_ sender: Any?) {
        openSettings(tab: .oauth, notice: nil)
    }

    /// Debug › Design Gallery (and `--gallery`): every SSDesign component in every state. Each opening starts
    /// fresh: the controller forgets itself when its window closes, so the bar and the drawing never disagree.
    @objc func showDesignGallery(_ sender: Any?) {
        if galleryWindow == nil {
            let controller = DesignGalleryWindowController()
            controller.onClose = { [weak self] in self?.galleryWindow = nil }
            galleryWindow = controller
        }
        galleryWindow?.show()
    }
}
