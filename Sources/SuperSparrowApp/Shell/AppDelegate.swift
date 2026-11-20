import AppKit
import SSCore
import SSDesign
import WebKit
import os

/// Application lifecycle: builds the environment for the launch mode, owns the main and settings windows,
/// runs sign-in, and keeps the app alive with no windows open, as mail clients do.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private static let log = Logger(subsystem: "io.supersparrow.mac", category: "shell")

    /// Where an action started: its alerts go on that window (spec §5.33), and the welcome screen answers
    /// with banners instead because it has no rail or sync line (§5.39).
    enum Origin {
        case welcome
        case main
        case settings
    }

    /// The one browser sign-in that may run at a time (§5.44).
    private struct SignIn {
        let generation: Int
        let kind: ProviderKind
        let reconnecting: Account?
        let origin: Origin
        let task: Task<Void, Never>
        /// A real environment built to replace the demo, kept apart until the sign-in succeeds (§5.43).
        let replacement: AppEnvironment?
        /// The day column's Connect (§5.54): told whether the account granted its calendar, or gave up.
        var connected: (@MainActor (Bool) -> Void)?
    }

    private let options: LaunchOptions
    private let settings = AppSettings.shared
    private var environment: AppEnvironment?
    private var mainWindow: MainWindowController?
    private var settingsWindow: SettingsWindowController?
    #if DEBUG
    private var galleryWindow: DesignGalleryWindowController?
    #endif
    /// Snapshots still to write before a quitting `--snapshot-…` launch quits.
    private var pendingQuittingSnapshots = 0
    private var signIn: SignIn?
    /// Tells a sign-in's completion whether it is still the current one; a replaced or cancelled sign-in must
    /// not touch the state of the one that took its place.
    private var signInGeneration = 0
    private var isPreparingDemo = false
    private var isTerminating = false
    private var notifierObservation: StoreObservation?
    /// Activation, deactivation and waking from sleep, passed on to the engine.
    private var wakeups: AppWakeups?
    /// Mail links from other apps, held until there is a main window (internal so the app's tests can deliver them).
    let mailLinks = MailLinkInbox()
    /// Clicks and actions on new-mail notifications, held until there is a main window (internal for the same reason).
    let notificationResponses = NewMailNotificationResponder()
    /// The Services menu's New Message with Selection and Send with SuperSparrow, held until there is a main window
    /// (internal for the same reason).
    let services = MailServicesProvider()
    /// The app's life as crash-report breadcrumbs (`CrashReporting`).
    private let crashBreadcrumbs = CrashBreadcrumbs()
    /// The launch was sent to analytics (the first main window only; a demo swapped in later is no launch).
    private var launchReported = false
    #if DEBUG
    /// `--analytics-check`'s round of steps, kept while it runs.
    private var analyticsCheck: AnalyticsCheck?
    #endif

    init(options: LaunchOptions) {
        self.options = options
        super.init()
    }

    // MARK: NSApplicationDelegate

    func applicationWillFinishLaunching(_ notification: Notification) {
        // An action that launches the app reaches only a center delegate set before launch ends; it waits in the
        // responder until `install` has a main window to apply it.
        if let center = NewMailNotifier.systemCenter { notificationResponses.connect(to: center) }
        // Before launch ends, so a service that launches the app finds its provider; the request waits there until
        // `install` has a main window to open it in.
        NSApp.servicesProvider = services
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Before the first window or menu image is drawn: the Font setting decides every New York role (§4.4).
        // `--font` (debug) wins for this process without being saved.
        QuireEnvironment.shared.setTypeface(options.typeface ?? settings.typeface)
        // Text size too (§4.15): the list's first rows are measured at it. `--text-size` (debug) wins, unsaved.
        QuireEnvironment.shared.setTextSize(options.textSize ?? settings.textSize)
        // And the theme (§4.16), so the first window draws in it. `--theme` (debug) wins, unsaved.
        QuireEnvironment.shared.setTheme(options.theme ?? settings.theme)
        NSApp.mainMenu = MainMenu.build(appDelegate: self)
        crashBreadcrumbs.start()
        CrashReporting.breadcrumb(.app, "launched")
        #if DEBUG
        SnapshotRenderer.scale = options.snapshotScale
        if let crashTest = options.crashTest { CrashTest.run(crashTest) }
        #endif
        // Settings › Appearance › Appearance; `--appearance` (debug) wins for this process.
        switch options.appearance {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: settings.applyAppearance()
        }
        if options.resetDemo { AppEnvironment.wipeDemoData() }
        wakeups = AppWakeups(setActive: { [weak self] in self?.reportAppActive($0) },
                             checkAll: { [weak self] in self?.environment?.engine.checkForMail() })
        if options.needsMailEnvironment {
            start(mode: options.demo ? .demo : .real)
        }
        NSApp.activate()
        if options.snapshotPath != nil || options.composeSnapshotPath != nil || options.readerWindowSnapshotPath != nil {
            runSnapshots(main: options.snapshotPath, compose: options.composeSnapshotPath, readerWindow: options.readerWindowSnapshotPath)
        }
        runQuittingSnapshots()
        #if DEBUG
        if options.gallery { showDesignGallery(nil) }
        if options.analyticsCheck {
            let check = AnalyticsCheck(settings: settings, mainWindow: { [weak self] in self?.mainWindow },
                                       openSettings: { [weak self] in self?.openSettings() })
            analyticsCheck = check
            check.run()
        }
        if let report = options.liveWriteCheckPath, options.demo { runLiveWriteCheck(report: report) }
        #endif
    }

    #if DEBUG
    /// `--live-write-check` (debug, demo only): one Help Me Write reply on the first inbox conversation's quick reply,
    /// reported to `report`, then the app quits.
    private func runLiveWriteCheck(report: String) {
        waitForInbox(deadline: Date().addingTimeInterval(20)) { [weak self] in
            guard let self, let window = self.mainWindow, let environment = self.environment, environment.isDemo else { return }
            window.selectFirstConversation()
            LiveWriteCheck.run(in: window, center: environment.helpMeWrite, settings: self.settings, report: report) {
                // As the quitting snapshots do: from a run-loop block, never a main-queue callout.
                RunLoop.main.perform { MainActor.assumeIsolated { NSApp.terminate(nil) } }
            }
        }
    }
    #endif

    // MARK: Snapshots (debug aid)

    /// In demo mode: waits for the inbox, opens its first conversation, waits for the reader's render to
    /// land, then writes the window (reader composited in) and, when asked, a reply composer and the conversation in a
    /// reader window. Outside demo mode the window is written as it is after a few seconds.
    private func runSnapshots(main: String?, compose: String?, readerWindow: String?) {
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
                            if let readerWindow { self.writeReaderWindowSnapshot(to: readerWindow) }
                            #if DEBUG
                            // The Later menu and Pick a Date… are the system's own windows, which no window snapshot
                            // holds: they are opened on screen afterwards, for a screen capture.
                            if let main { self.mainWindow?.openDebugLaterSurfaces(besides: main) }
                            #endif
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
        writeSnapshot(of: mainWindow?.window, to: path, reader: reader)
    }

    /// The selected conversation (the first, as `--snapshot` opens it) in a reader window, once its own render has landed.
    private func writeReaderWindowSnapshot(to path: String) {
        guard let main = mainWindow, let id = main.list.selectedConversationID, let reader = main.openInNewWindow(id) else {
            Self.log.error("snapshot: no conversation to open in a reader window")
            return
        }
        reader.conversation.whenShownRenderLands(timeout: 10) { webView in
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                MainActor.assumeIsolated {
                    self.captureReader(webView) { image in
                        self.writeSnapshot(of: reader.window, to: path, reader: image.map { ($0, webView) })
                    }
                }
            }
        }
    }

    private func writeSnapshot(of window: NSWindow?, to path: String, reader: (image: NSImage, webView: WKWebView?)?) {
        guard let view = window?.contentView?.superview ?? window?.contentView,
              let bitmap = SnapshotRenderer.bitmap(for: view, in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        if let reader, let webView = reader.webView, webView.window === view.window,
           let context = NSGraphicsContext(bitmapImageRep: bitmap) {
            var frame = webView.convert(webView.bounds, to: view)
            if view.isFlipped { frame.origin.y = view.bounds.height - frame.maxY }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            reader.image.draw(in: frame, from: .zero, operation: .sourceOver, fraction: 1)
            ReaderSnapshotOverlay.draw(over: webView, in: view)
            NSGraphicsContext.restoreGraphicsState()
        }
        SnapshotRenderer.writePNG(bitmap, to: path)
    }

    private func writeComposeSnapshot(to path: String) {
        guard mainWindow?.openReplyComposer() == true else {
            Self.log.error("snapshot: no conversation to reply to")
            return
        }
        // A line and a picture in the body, so the snapshot shows how a pasted picture sits in the text (§5.20).
        ComposeWindowRegistry.shared.openControllers.first?.writeDemoSample()
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
                SnapshotRenderer.writePNG(bitmap, to: path)
            }
        }
    }

    // MARK: Snapshots that quit (debug aid)

    /// Each quitting `--snapshot-…` option writes one PNG; once all of them have, the app quits, unless
    /// `--snapshot` or `--snapshot-compose` (which never quit) are running too.
    private func runQuittingSnapshots() {
        var jobs: [(String?, (String) -> Void)] = []
        #if DEBUG
        // The design gallery is a debug-build tool (Debug › Design Gallery).
        jobs.append((options.gallerySnapshotPath, writeGallerySnapshot))
        #endif
        jobs.append((options.welcomeSnapshotPath, { [unowned self] in self.writeWelcomeSnapshot(to: $0, states: false) }))
        jobs.append((options.welcomeStatesSnapshotPath, { [unowned self] in self.writeWelcomeSnapshot(to: $0, states: true) }))
        jobs.append((options.settingsSnapshotPath, { [unowned self] in self.writeSettingsSnapshot(to: $0, states: false) }))
        jobs.append((options.settingsStatesSnapshotPath, { [unowned self] in self.writeSettingsSnapshot(to: $0, states: true) }))
        jobs.append((options.cheatSheetSnapshotPath, writeCheatSheetSnapshot))
        jobs.append((options.hudSnapshotPath, writeHUDSnapshot))
        jobs.append((options.alertsSnapshotPath, writeAlertsSnapshot))
        let requested = jobs.compactMap { path, job in path.map { (path: $0, job: job) } }
        // Counted before any starts, so an early finisher cannot quit while the others are still queued.
        pendingQuittingSnapshots = requested.count
        for (path, job) in requested { job(path) }
    }

    private func quittingSnapshotFinished() {
        pendingQuittingSnapshots -= 1
        guard pendingQuittingSnapshots == 0, options.snapshotPath == nil, options.composeSnapshotPath == nil,
              options.readerWindowSnapshotPath == nil else { return }
        // Not from inside a main-queue callout: with an environment open, terminate waits (terminateLater) in a
        // nested run loop for a main-actor task to reply, and a nested loop cannot drain the queue it was
        // entered from, so terminating from a dispatch block would hang. A run-loop block can.
        RunLoop.main.perform {
            MainActor.assumeIsolated { NSApp.terminate(nil) }
        }
    }

    #if DEBUG
    /// The whole design gallery page, in the forced appearance.
    private func writeGallerySnapshot(to path: String) {
        DesignGalleryWindowController.renderSnapshot(appearance: NSApp.appearance) { [weak self] bitmap in
            if let bitmap { SnapshotRenderer.writePNG(bitmap, to: path) }
            self?.quittingSnapshotFinished()
        }
    }
    #endif

    /// The main window's welcome screen, over a throwaway empty store in a temporary directory: the user's
    /// mail database, Keychain and saved window frame are never touched. With `states`, every state of
    /// §5.39 one under the other, in a smaller window.
    private func writeWelcomeSnapshot(to path: String, states: Bool) {
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
        // A scratch store's (empty) accounts say nothing about the user's, so the saved scope is left alone.
        let controller = MainWindowController(environment: scratch, settings: settings, remembersScope: false)
        // Detach from the real main window's saved frame before sizing, so the snapshot is always the default
        // size and never rewrites the user's frame.
        controller.window?.setFrameAutosaveName("")
        controller.window?.setContentSize(states ? AppSnapshots.welcomeStatesSize : MainWindowController.defaultSize)
        controller.showWindow(nil)
        let finish: @MainActor () -> Void = { [weak self] in
            controller.tearDown()
            controller.close()
            Task { @MainActor in
                await scratch.shutdown()
                try? FileManager.default.removeItem(at: directory)
                self?.quittingSnapshotFinished()
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            MainActor.assumeIsolated {
                guard let window = controller.window else { return finish() }
                if states {
                    AppSnapshots.renderWelcomeStates(in: window) { bitmap in
                        if let bitmap { SnapshotRenderer.writePNG(bitmap, to: path) }
                        finish()
                    }
                    return
                }
                if let bitmap = SnapshotRenderer.render(window: window) {
                    SnapshotRenderer.writePNG(bitmap, to: path)
                } else {
                    Self.log.error("snapshot: the welcome window did not render")
                }
                finish()
            }
        }
    }

    /// Every Settings tab in demo mode, one under the other, or (`states`) the Accounts and OAuth states of
    /// §5.40. Waits for the demo inbox so the Accounts tab shows rows, not the empty state.
    private func writeSettingsSnapshot(to path: String, states: Bool) {
        waitForInbox(deadline: Date().addingTimeInterval(20)) { [weak self] in
            guard let self else { return }
            self.openSettings()
            guard let controller = self.settingsWindow else {
                Self.log.error("snapshot: no settings window")
                self.quittingSnapshotFinished()
                return
            }
            // Statuses settle a moment after the inbox fills.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                MainActor.assumeIsolated {
                    let render = states ? AppSnapshots.renderSettingsStates : AppSnapshots.renderSettingsTabs
                    render(controller) { bitmap in
                        if let bitmap { SnapshotRenderer.writePNG(bitmap, to: path) }
                        self.quittingSnapshotFinished()
                    }
                }
            }
        }
    }

    /// The main window in demo mode with the keyboard cheat sheet open (§5.32).
    private func writeCheatSheetSnapshot(to path: String) {
        waitForInbox(deadline: Date().addingTimeInterval(20)) { [weak self] in
            guard let self, let window = self.mainWindow?.window else {
                self?.quittingSnapshotFinished()
                return
            }
            window.makeKeyAndOrderFront(nil)
            CheatSheetController.shared.present(in: window, animated: false)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                MainActor.assumeIsolated {
                    if let bitmap = SnapshotRenderer.render(window: window) { SnapshotRenderer.writePNG(bitmap, to: path) }
                    CheatSheetController.shared.dismiss(animated: false)
                    self.quittingSnapshotFinished()
                }
            }
        }
    }

    /// The main window in demo mode with the g-sequence HUD showing (§5.32).
    private func writeHUDSnapshot(to path: String) {
        waitForInbox(deadline: Date().addingTimeInterval(20)) { [weak self] in
            guard let self, let window = self.mainWindow?.window else {
                self?.quittingSnapshotFinished()
                return
            }
            window.makeKeyAndOrderFront(nil)
            KeyboardRouter.active?.showSequenceHUDNow()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                MainActor.assumeIsolated {
                    if let bitmap = SnapshotRenderer.render(window: window) { SnapshotRenderer.writePNG(bitmap, to: path) }
                    KeyboardRouter.active?.disarmSequence(animated: false)
                    self.quittingSnapshotFinished()
                }
            }
        }
    }

    /// The alert inventory this app shows (§5.33), each as the system draws it.
    private func writeAlertsSnapshot(to path: String) {
        AppSnapshots.renderAlerts { [weak self] bitmap in
            if let bitmap { SnapshotRenderer.writePNG(bitmap, to: path) }
            self?.quittingSnapshotFinished()
        }
    }

    // MARK: Lifecycle

    /// For `AppWakeups`: the live lane checks every 5 s while the app is frontmost and every 30 s otherwise. A real
    /// environment built beside the demo for a sign-in is told too: it polls the account being added until it is
    /// swapped in.
    private func reportAppActive(_ isActive: Bool) {
        environment?.engine.setAppActive(isActive)
        signIn?.replacement?.engine.setAppActive(isActive)
    }

    /// Mail links (`mailto:`, `CFBundleURLTypes` in Info.plist) from Safari, Contacts and every other app. A link
    /// that launches the app can arrive before `applicationDidFinishLaunching` has built the main window, so the
    /// inbox holds it until then.
    func application(_ application: NSApplication, open urls: [URL]) {
        mailLinks.receive(urls)
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
        let environments = [environment, signIn?.replacement].compactMap { $0 }
        let settingsWindow = settingsWindow
        // Let in-flight writes finish so the next launch resumes from a consistent store, but never hang quitting.
        var replied = false
        let reply = {
            guard !replied else { return }
            replied = true
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        Task {
            await Self.prepareToQuit(settings: settingsWindow, environments: environments)
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

    /// Quitting's work before AppKit is told to go on. AppKit posts will-terminate only after that, once the stores are
    /// closed, so a Settings field that saves when editing ends (the signature) ends it first, while they are open.
    static func prepareToQuit(settings: SettingsWindowController?, environments: [AppEnvironment]) async {
        settings?.endEditing()
        for environment in environments { await environment.shutdown() }
    }

    // MARK: Environment

    private func start(mode: AppEnvironment.Mode) {
        let environment: AppEnvironment
        do {
            environment = try AppEnvironment.make(mode: mode, settings: settings)
        } catch {
            Self.log.fault("could not open the mail database: \(String(describing: error), privacy: .public)")
            // No window exists yet: app-modal, nothing behind it, and the app quits when it closes (§5.33).
            AppAlert.databaseUnavailable(reason: "The database file couldn't be opened, or it is damaged.").present(on: nil)
            NSApp.terminate(nil)
            return
        }
        #if DEBUG
        LiveWriteCheck.chooseProvider(options, for: environment)
        #endif
        environment.start()
        install(environment, replacing: nil)
    }

    /// Makes `environment` the app's and shows its main window, cross-fading from `old` when one is being
    /// replaced (`dur.slow`, §5.39, §5.43). The old window's controller is torn down; its environment is the
    /// caller's to shut down.
    private func install(_ environment: AppEnvironment, replacing old: MainWindowController?) {
        self.environment = environment
        // An engine assumes it starts frontmost; one launched in the background, or swapped in, learns otherwise
        // here, and activation reports every change after.
        environment.engine.setAppActive(NSApp.isActive)
        // The window going keeps no more failed sends as drafts from here: through its cross-fade the draft store is
        // already the new mailbox's, where its mailbox's drafts would be lost (the demo's wiped, the user's out of sight),
        // and the next launch of its mailbox keeps them instead (§5.53).
        old?.sendLaterOutbox.stop()
        // Drafts kept on this Mac follow the mailbox on screen, so a cancelled “Replace the demo” sign-in, which
        // built a real environment beside the demo, never sends the demo's drafts to the real folder.
        ComposeDraftStore.shared.useDemoDirectory(environment.isDemo)
        // Crash reports say which mailbox was on screen, so one from the made-up demo reads as such.
        CrashReporting.setMode(demo: environment.isDemo)
        Analytics.setMode(demo: environment.isDemo)
        // File › Leave Demo… exists only in demo mode (§5.35). Set here, not in validation, which skips hidden items.
        let fileItems = NSApp.mainMenu?.items.flatMap { $0.submenu?.items ?? [] } ?? []
        fileItems.first { $0.action == #selector(leaveDemo(_:)) }?.isHidden = !environment.isDemo
        // The cheat sheet belongs to the window being replaced.
        if old != nil { CheatSheetController.shared.dismiss(animated: false) }
        // The old window gives up the saved frame name so the new one restores (and later saves) it.
        let oldFrame = old?.window?.frame
        old?.window?.setFrameAutosaveName("")
        let window = MainWindowController(environment: environment, settings: settings)
        window.onAddAccount = { [weak self] kind in self?.addAccount(kind, origin: self?.originForMainWindow() ?? .main) }
        window.onReconnect = { [weak self] account in self?.reconnect(account, origin: .main) }
        window.onConnectCalendar = { [weak self] account, done in
            guard let self else { return done(false) }
            self.connectCalendar(account, origin: .main, done: done)
        }
        window.onOpenSettings = { [weak self] in self?.openSettings() }
        environment.helpMeWrite.openSettings = { [weak self] in self?.openSettings(tab: .ai) }
        window.onOpenAccountsSettings = { [weak self] in self?.openSettings(tab: .accounts) }
        window.onTryDemo = { [weak self] in self?.switchToDemo() }
        window.onCancelSignIn = { [weak self] in self?.cancelSignIn() }
        window.onLeaveDemo = { [weak self] in self?.confirmLeavingDemo(origin: .main) }
        window.beforeCompose = { [weak self] in self?.saveSettingsEdits() }
        mainWindow = window
        // Last, on either path below: the window is on screen, so a composer for a held link or service, or a
        // notification's Reply, opens in front of it.
        defer {
            openMailLinks(in: window)
            openServiceRequests(in: window)
            answerNotifications(in: window)
            if old == nil { reportLaunch(in: environment) }
        }
        observeForNotifier(environment)
        if let oldFrame { window.window?.setFrame(oldFrame, display: false) }
        guard let old, let oldWindow = old.window, let newWindow = window.window, oldWindow.isVisible else {
            old?.tearDown()
            window.showWindow(nil)
            requestNotificationsIfAccounts(window, in: environment)
            return
        }
        newWindow.alphaValue = 0
        window.showWindow(nil)
        Quire.Motion.run(Quire.Motion.slow, .settle, reduced: .keep, animations: { _ in
            newWindow.animator().alphaValue = 1
            oldWindow.animator().alphaValue = 0
        }, completion: {
            newWindow.alphaValue = 1
            old.tearDown()
            old.close()
            oldWindow.alphaValue = 1
        })
        requestNotificationsIfAccounts(window, in: environment)
    }

    /// The launch, once, as its first main window is on screen: how long since the process started, how many accounts of
    /// each kind, and how the app looks (`Analytics`).
    private func reportLaunch(in environment: AppEnvironment) {
        guard !launchReported else { return }
        launchReported = true
        let accounts = (try? environment.store.accounts()) ?? []
        Analytics.send(.launched(.init(seconds: Analytics.secondsSinceProcessStart() ?? 0,
                                       gmailAccounts: accounts.filter { $0.kind == .gmail }.count,
                                       microsoftAccounts: accounts.filter { $0.kind == .microsoft }.count,
                                       theme: options.theme ?? settings.theme, appearance: settings.appearance,
                                       density: settings.listDensity, textSize: options.textSize ?? settings.textSize,
                                       typeface: options.typeface ?? settings.typeface)))
    }

    /// Mail links open in `window`, the main window `install` just put on screen, which has read its accounts: one that
    /// launched the app (held until now) at once, later ones as they come, until another main window takes over. Taking
    /// the window means no link can be handed over before there is one to open it. Internal so the app's tests can give
    /// the delegate a window over a throwaway store.
    func openMailLinks(in window: MainWindowController) {
        mailLinks.receiver = { [weak window] link in window?.openMailLink(link) }
    }

    /// Services requests open in `window`, as mail links do (`openMailLinks(in:)`): a held one at once, later ones as they
    /// come. Internal so the app's tests can give the delegate a window over a throwaway store.
    func openServiceRequests(in window: MainWindowController) {
        services.receiver = { [weak window] request in window?.openServiceRequest(request) }
    }

    /// Notification clicks and actions are answered by `window`, the main window `install` just put on screen, which
    /// has read its accounts: one that launched the app (held until now) at once, later ones as they come, until
    /// another main window takes over. Internal so the app's tests can give the delegate a window over a throwaway store.
    func answerNotifications(in window: MainWindowController) {
        notificationResponses.receiver = { [weak window] response in window?.answer(response) }
    }

    /// At launch, and as the demo comes or goes, macOS is asked for notifications while there is mail to notify about
    /// and it has no answer yet (`requestAuthorizationIfNeeded`). Demo accounts are seeded into the store, never added,
    /// so they are asked for here too, once seeded.
    private func requestNotificationsIfAccounts(_ window: MainWindowController, in environment: AppEnvironment) {
        guard environment.isDemo || (try? environment.store.accounts().isEmpty) == false else { return }
        window.notifier.requestAuthorizationIfNeeded()
    }

    /// No notification for an account's first sync (§5.41): the notifier learns which accounts are fetching their
    /// first page. Older mail downloading behind it does not count, so new mail notifies meanwhile.
    private func observeForNotifier(_ environment: AppEnvironment) {
        notifierObservation?.cancel()
        notifierObservation = environment.engine.observeStatus { [weak self] statuses in
            MainActor.assumeIsolated {
                self?.mainWindow?.notifier.accountsInFirstSync = NewMailNotifier.accountsInFirstSync(statuses)
            }
        }
    }

    /// “Try the demo” from the welcome screen (§5.39): the welcome shows Preparing the demo while the demo store
    /// is seeded beside the real one, then the window cross-fades to the demo inbox. A failure leaves the real
    /// environment untouched and says so in the banner slot.
    private func switchToDemo() {
        guard let old = environment, !old.isDemo, !isPreparingDemo else { return }
        cancelSignIn()
        isPreparingDemo = true
        welcome?.setActivity(.preparingDemo)
        Task { [weak self] in
            var demo: AppEnvironment?
            do {
                guard let settings = self?.settings else { return }
                let made = try AppEnvironment.make(mode: .demo, settings: settings)
                demo = made
                try await made.startAndSeedDemo()
                guard let self else { return }
                self.isPreparingDemo = false
                self.settingsWindow?.tearDown()
                self.settingsWindow = nil
                let oldWindow = self.mainWindow
                self.install(made, replacing: oldWindow)
                await old.shutdown()
            } catch {
                Self.log.error("demo could not start: \(String(describing: error), privacy: .public)")
                await demo?.shutdown()
                guard let self else { return }
                self.isPreparingDemo = false
                self.welcome?.setActivity(.idle)
                self.welcome?.showBanner(.demoFailed)
            }
        }
    }

    /// Leave Demo (§5.43): the demo store is wiped and the welcome screen returns, cross-fading.
    private func leaveDemoNow() {
        guard let old = environment, old.isDemo else { return }
        cancelSignIn()
        settingsWindow?.tearDown()
        settingsWindow = nil
        let oldWindow = mainWindow
        Task { [weak self] in
            await old.shutdown()
            AppEnvironment.wipeDemoData()
            guard let self else { return }
            do {
                let real = try AppEnvironment.make(mode: .real, settings: self.settings)
                real.start()
                self.install(real, replacing: oldWindow)
            } catch {
                Self.log.fault("could not open the mail database: \(String(describing: error), privacy: .public)")
                AppAlert.databaseUnavailable(reason: "The database file couldn't be opened, or it is damaged.").present(on: nil)
                NSApp.terminate(nil)
            }
        }
    }

    private var welcome: WelcomeViewController? {
        mainWindow?.window?.contentViewController as? WelcomeViewController
    }

    // MARK: Accounts

    var isSigningIn: Bool { signIn != nil }

    /// The accounts in rail order, for the View menu's ⌘1…⌘9 titles.
    var menuAccounts: [Account] {
        ((try? environment?.store.accounts()) ?? []).sorted { $0.addedAt < $1.addedAt }
    }

    /// Whether the View menu lists Later: while the main window's rail shows its tile (§5.2).
    var menuShowsLater: Bool {
        mainWindow?.showsLater ?? false
    }

    /// Whether the View menu lists the Outbox: while the main window's rail shows its tile (§5.2, §5.53).
    var menuShowsOutbox: Bool {
        mainWindow?.showsOutbox ?? false
    }

    private func originForMainWindow() -> Origin {
        welcome != nil ? .welcome : .main
    }

    /// Where a menu command started: Settings when it is the key window, else the main window.
    private func originForMenu() -> Origin {
        if let settings = settingsWindow?.window, settings.isKeyWindow { return .settings }
        return originForMainWindow()
    }

    private func window(for origin: Origin) -> NSWindow? {
        switch origin {
        case .settings: return settingsWindow?.visibleWindow ?? mainWindow?.window
        case .main, .welcome: return mainWindow?.window
        }
    }

    /// Starts a browser sign-in for a new account (§5.44). With no kind (the rail's +), the provider is chosen
    /// in a pull-down menu, never an alert.
    func addAccount(_ kind: ProviderKind?, origin: Origin, type: MicrosoftAccountType? = nil) {
        guard let environment, !isPreparingDemo else { return }
        guard let kind else {
            // The welcome screen's two buttons are its provider choice.
            if origin != .welcome { popUpAddAccountMenu() }
            return
        }
        guard signIn == nil else { return }
        // One address can be a work account and a personal one; Microsoft would pick for the user, so they choose.
        if kind == .microsoft, type == nil {
            AppAlert.microsoftAccountType.present(on: window(for: origin)) { [weak self] choice in
                guard choice < 2 else { return }
                self?.addAccount(kind, origin: origin, type: choice == 0 ? .workOrSchool : .personal)
            }
            return
        }
        if environment.isDemo {
            confirmReplacingDemo(kind, origin: origin, type: type)
            return
        }
        guard clientIsConfigured(kind, in: environment, origin: origin) else { return }
        beginSignIn(kind: kind, reconnecting: nil, origin: origin, in: environment, replacement: nil, type: type)
    }

    /// Runs the browser sign-in again for an account that needs it (§5.44, Reconnecting).
    func reconnect(_ account: Account, origin: Origin) {
        guard let environment, signIn == nil, !isPreparingDemo else { return }
        guard environment.isDemo || clientIsConfigured(account.kind, in: environment, origin: origin) else { return }
        beginSignIn(kind: account.kind, reconnecting: account, origin: origin, in: environment, replacement: nil)
    }

    /// The day column's Connect (§5.54): the reconnect's browser sign-in, asking for the calendar on top of what the
    /// account holds (`MailClient.connectCalendar`), with its alerts. `done` hears whether it was granted.
    func connectCalendar(_ account: Account, origin: Origin, done: @escaping @MainActor (Bool) -> Void) {
        guard let environment, signIn == nil, !isPreparingDemo,
              environment.isDemo || clientIsConfigured(account.kind, in: environment, origin: origin) else { return done(false) }
        beginSignIn(kind: account.kind, reconnecting: account, origin: origin, in: environment, replacement: nil, calendar: true)
        signIn?.connected = done
    }

    /// No client: the welcome screen shows its info banner; elsewhere the alert offers Settings › OAuth with
    /// the incoming notice. An unreadable settings file is not an alert: Settings › OAuth opens with the danger
    /// banner (§5.33).
    private func clientIsConfigured(_ kind: ProviderKind, in environment: AppEnvironment, origin: Origin) -> Bool {
        do {
            _ = try environment.clientConfigurations.configuration(for: kind)
            return true
        } catch AuthError.missingClientConfiguration {
            if origin == .welcome, let welcome {
                welcome.onOpenOAuthSettings = { [weak self] in self?.openSettings(tab: .oauth, oauthNotice: .needsClient(kind)) }
                welcome.showBanner(.missingClient(kind))
            } else {
                AppAlert.missingClient(kind).present(on: window(for: origin)) { [weak self] choice in
                    if choice == 0 { self?.openSettings(tab: .oauth, oauthNotice: .needsClient(kind)) }
                }
            }
            return false
        } catch {
            Self.log.error("OAuth settings unreadable: \(String(describing: error), privacy: .public)")
            openSettings(tab: .oauth, oauthNotice: .unreadable(reason: ErrorText.oauthFile(error)))
            return false
        }
    }

    /// In demo mode a real account replaces the demo (§5.43): asked first, then signed in against a real
    /// environment built beside the demo, which is swapped in only when the sign-in succeeds.
    private func confirmReplacingDemo(_ kind: ProviderKind, origin: Origin, type: MicrosoftAccountType?) {
        AppAlert.replaceDemo.present(on: window(for: origin)) { [weak self] choice in
            guard choice == 0, let self, self.signIn == nil else { return }
            let real: AppEnvironment
            do {
                real = try AppEnvironment.make(mode: .real, settings: self.settings)
            } catch {
                Self.log.error("could not open the real mail database: \(String(describing: error), privacy: .public)")
                AppAlert.addFailed(reason: "The mail database couldn't be opened.").present(on: self.window(for: origin)) { [weak self] choice in
                    if choice == 0 { self?.addAccount(kind, origin: origin, type: type) }
                }
                return
            }
            guard self.clientIsConfigured(kind, in: real, origin: origin) else {
                Task { await real.shutdown() }
                return
            }
            real.start()
            self.beginSignIn(kind: kind, reconnecting: nil, origin: origin, in: real, replacement: real, type: type)
        }
    }

    private func beginSignIn(kind: ProviderKind, reconnecting: Account?, origin: Origin, in environment: AppEnvironment,
                             replacement: AppEnvironment?, type: MicrosoftAccountType? = nil, calendar: Bool = false) {
        let tenant = type.map { $0.tenant(configured: try? environment.clientConfigurations.configuration(for: kind).tenant) }
        signInGeneration += 1
        let generation = signInGeneration
        let knownIDs = Set(((try? environment.engine.accounts()) ?? []).map(\.id))
        let task = Task { [weak self] in
            do {
                let account: Account
                if let reconnecting, calendar {
                    account = try await environment.engine.connectCalendar(reconnecting)
                } else if let reconnecting {
                    account = try await environment.engine.reconnect(reconnecting)
                } else {
                    account = try await environment.engine.addAccount(kind: kind, tenant: tenant)
                }
                self?.signInSucceeded(account, generation: generation, wasKnown: knownIDs.contains(account.id))
            } catch {
                await self?.signInFailed(error, generation: generation)
            }
        }
        signIn = SignIn(generation: generation, kind: kind, reconnecting: reconnecting, origin: origin, task: task, replacement: replacement)
        reflectSignIn()
    }

    /// Shows the running sign-in everywhere it appears: the main window (welcome, rail tile and sync line)
    /// follows `SignInProgress`; Settings' pending or reconnecting row is set here.
    private func reflectSignIn() {
        let current = signIn
        let progress = current.map { signIn in
            SignInProgress(kind: signIn.kind, reconnecting: signIn.reconnecting?.id,
                           subject: signIn.reconnecting.map(AccountLabels.name(for:)) ?? (signIn.kind == .gmail ? "Gmail" : "Microsoft 365"))
        }
        SignInProgress.post(progress)
        if let model = settingsWindow?.model {
            model.pendingSignIn = current?.reconnecting == nil ? current?.kind : nil
            model.reconnecting = current?.reconnecting?.id
            if current != nil { model.accountsNotice = nil }
        }
    }

    private func signInSucceeded(_ account: Account, generation: Int, wasKnown: Bool) {
        guard let current = signIn, current.generation == generation else { return }
        signIn = nil
        Self.log.info("account ready: \(account.id.rawValue, privacy: .public)")
        reflectSignIn()
        if let replacement = current.replacement {
            replaceDemo(with: replacement)
            Analytics.send(.accountAdded(.init(account.kind)))
            return
        }
        if let reconnected = current.reconnecting {
            // The check that follows a reconnect is one the user asked for (§5.11): Settings says so.
            settingsWindow?.model.userChecks.insert(reconnected.id)
            // The sync line checks too, and the main window says “… reconnected.” once the badge leaves.
            mainWindow?.reconnectDidSucceed(reconnected.id)
        } else if wasKnown {
            // The browser signed in to a mailbox that is already here (often its own session): say so, or the
            // add looks like it did nothing.
            AppAlert.alreadyAdded(account).present(on: window(for: current.origin)) { [weak self] choice in
                if choice == 0 { self?.showAccount(account.id, origin: current.origin) }
            }
        } else {
            settings.accountWasAdded(totalAccounts: menuAccounts.count)
            Analytics.send(.accountAdded(.init(account.kind)))
        }
        mainWindow?.notifier.requestAuthorizationIfNeeded()
        mainWindow?.refreshAccounts()
        settingsWindow?.refreshAccounts()
        if current.reconnecting == nil, !wasKnown {
            mainWindow?.showWindow(nil)
            showAccount(account.id, origin: current.origin)
        }
        current.connected?(true)
    }

    private func signInFailed(_ error: Error, generation: Int) async {
        guard let current = signIn, current.generation == generation else { return }
        signIn = nil
        await current.replacement?.shutdown()
        reflectSignIn()
        if error is CancellationError {
            current.connected?(false)
            return
        }
        Self.log.error("sign-in failed: \(String(describing: error), privacy: .public)")
        let reason = ErrorText.signIn(error, kind: current.kind)
        // Try Again asks again as the sign-in did: the calendar's Connect keeps asking for the calendar, and hears the
        // outcome; anything else ends its round.
        let again = { [weak self] (account: Account) in
            guard let self else { return }
            if let connected = current.connected {
                self.connectCalendar(account, origin: current.origin, done: connected)
            } else {
                self.reconnect(account, origin: current.origin)
            }
        }
        if case AuthError.wrongAccount(let expected, let actual) = error, let account = current.reconnecting {
            AppAlert.wrongAccount(expected: expected, actual: actual).present(on: window(for: current.origin)) { choice in
                if choice == 0 { again(account) } else { current.connected?(false) }
            }
            return
        }
        if let account = current.reconnecting {
            AppAlert.reconnectFailed(account, reason: reason).present(on: window(for: current.origin)) { choice in
                if choice == 0 { again(account) } else { current.connected?(false) }
            }
            return
        }
        switch current.origin {
        case .welcome:
            welcome?.showBanner(.signInError(reason: reason))
        case .settings:
            settingsWindow?.model.accountsNotice = .addFailed(kind: current.kind, reason: reason)
        case .main:
            AppAlert.addFailed(reason: reason).present(on: window(for: .main)) { [weak self] choice in
                if choice == 0 { self?.addAccount(current.kind, origin: .main) }
            }
        }
    }

    /// Cancel (welcome, sync line, Settings): the pending tile and row leave at once, with no message.
    /// OAuthFlow turns the cancellation into `userCancelled`, which the replaced generation ignores.
    private func cancelSignIn() {
        guard let current = signIn else { return }
        signIn = nil
        signInGeneration += 1
        current.task.cancel()
        current.connected?(false)
        if let replacement = current.replacement { Task { await replacement.shutdown() } }
        reflectSignIn()
    }

    /// The first real account replaced the demo: the demo store is wiped and the window shows the real inbox.
    private func replaceDemo(with real: AppEnvironment) {
        guard let demo = environment else { return }
        settingsWindow?.tearDown()
        settingsWindow = nil
        install(real, replacing: mainWindow)
        Task {
            await demo.shutdown()
            AppEnvironment.wipeDemoData()
        }
    }

    /// Selects an account where the user will look: its Settings row, or its rail tile (⌘1…⌘9).
    private func showAccount(_ id: AccountID, origin: Origin) {
        if origin == .settings, let model = settingsWindow?.model {
            model.selection = id.rawValue
            settingsWindow?.show()
            return
        }
        guard let index = menuAccounts.firstIndex(where: { $0.id == id }), index < 9, let mainWindow else { return }
        let item = NSMenuItem()
        item.tag = index + 1
        mainWindow.selectAccountShortcut(item)
        mainWindow.showWindow(nil)
    }

    /// The provider pull-down for a + that did not bring its own menu (§5.44). It opens 4 pt below the control
    /// that asked, leading-aligned: the view under the click, or the focused control when a key pressed it
    /// (Full Keyboard Access); only when neither is known does it open at the pointer.
    private func popUpAddAccountMenu() {
        guard let window = NSApp.keyWindow ?? mainWindow?.window, let content = window.contentView else { return }
        if let control = Self.invokingControl(in: window), control !== content {
            AddAccountMenu.popUp(below: control, target: self)
            return
        }
        let menu = AddAccountMenu.make(target: self)
        let point = content.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        menu.popUp(positioning: nil, at: point, in: content)
    }

    /// The control behind the current event: a small view under a mouse click, or the first responder for a key.
    private static func invokingControl(in window: NSWindow) -> NSView? {
        guard let event = NSApp.currentEvent, event.window === window else { return nil }
        switch event.type {
        case .leftMouseDown, .leftMouseUp:
            guard let frame = window.contentView?.superview,
                  let hit = frame.hitTest(frame.convert(event.locationInWindow, from: nil)) else { return nil }
            // A + is a small control; a large view under the pointer means something else asked. The click may
            // land on a part of the control (its glyph), so the outermost small ancestor is the control.
            let limit = 2 * Quire.Layout.Rail.tile
            let isSmall = { (view: NSView) in view.bounds.width <= limit && view.bounds.height <= limit }
            guard isSmall(hit) else { return nil }
            var control = hit
            while let parent = control.superview, isSmall(parent) { control = parent }
            return control
        case .keyDown:
            return window.firstResponder as? NSView
        default:
            return nil
        }
    }

    private func removeAccount(_ account: Account) {
        AppAlert.remove(account).present(on: window(for: .settings)) { [weak self] choice in
            if choice == 1 { self?.performRemove(account) }
        }
    }

    private func performRemove(_ account: Account) {
        guard let environment else { return }
        Task { [weak self] in
            do {
                try await environment.engine.removeAccount(account.id)
                Self.removeDrafts(of: account.id)
                Analytics.send(.accountRemoved(.init(account.kind)))
            } catch {
                Self.log.error("remove failed: \(String(describing: error), privacy: .public)")
                guard let self else { return }
                AppAlert.removeFailed(account, reason: "The account couldn't be removed from the mail database.")
                    .present(on: self.window(for: .settings)) { [weak self] choice in
                        if choice == 0 { self?.performRemove(account) }
                    }
            }
            self?.mainWindow?.refreshAccounts()
            self?.settingsWindow?.refreshAccounts()
        }
    }

    /// Remove takes the account's mail off this Mac (§5.40), and its drafts go with it: its composers close
    /// keeping nothing (closing would otherwise save them again), then its drafts folder is deleted.
    static func removeDrafts(of account: AccountID) {
        for composer in ComposeWindowRegistry.shared.openControllers where composer.accountID == account {
            composer.closeWithoutSaving()
        }
        ComposeDraftStore.shared.removeDrafts(for: account)
    }

    private func confirmLeavingDemo(origin: Origin) {
        guard environment?.isDemo == true else { return }
        AppAlert.leaveDemo.present(on: window(for: origin)) { [weak self] choice in
            if choice == 0 { self?.leaveDemoNow() }
        }
    }

    // MARK: Settings

    private func openSettings(tab: SettingsModel.Tab? = nil, oauthNotice: SettingsModel.OAuthNotice? = nil) {
        guard let environment else { return }
        if settingsWindow == nil {
            // A snapshot neither asks nor changes which app opens mail links, whether it opens at login or what macOS lets
            // it show, and shows a fixed mailbox size, so its render depends only on the build.
            let mailtoHandler: MailtoDefaultHandling = options.isSnapshot ? SnapshotMailtoHandler() : LaunchServicesMailtoHandler()
            let loginItem: LoginItemHandling = options.isSnapshot ? SnapshotLoginItem() : MainAppLoginItem()
            let notifications: NotificationPermissionHandling = options.isSnapshot ? SnapshotNotificationPermission() : SystemNotificationPermission()
            let snapshotSize: (@Sendable () -> Int64)? = options.isSnapshot ? AppSnapshots.mailboxSize : nil
            let controller = SettingsWindowController(environment: environment, settings: settings, mailtoHandler: mailtoHandler,
                                                      loginItem: loginItem, notifications: notifications, measureMailbox: snapshotSize)
            let model = controller.model
            model.addAccount = { [weak self] kind in self?.addAccount(kind, origin: .settings) }
            model.cancelSignIn = { [weak self] in self?.cancelSignIn() }
            model.removeAccount = { [weak self] account in self?.removeAccount(account) }
            model.reconnect = { [weak self] account in self?.reconnect(account, origin: .settings) }
            model.retry = { [weak self] account in
                self?.settingsWindow?.model.userChecks.insert(account.id)
                self?.environment?.engine.syncNow(accountID: account.id)
            }
            model.leaveDemo = { [weak self] in self?.confirmLeavingDemo(origin: .settings) }
            model.setInkSlot = { [weak self] slot, account in self?.edit(account) { try $0.setInkSlot(slot, for: account.id) } }
            model.setMonogram = { [weak self] monogram, account in self?.edit(account) { try $0.setMonogram(monogram, for: account.id) } }
            model.setFace = { [weak self] face, account in self?.edit(account) { try $0.setFace(face, for: account.id) } }
            model.setSignature = { [weak self, weak model] signature, id in
                // A field saving as its account is removed has nothing left to save to.
                guard let account = model?.accounts.first(where: { $0.id == id }) else { return }
                self?.edit(account) { try $0.setSignature(signature, for: id) }
            }
            model.removeSenderRule = { [weak self] rule in self?.removeSenderRule(rule) }
            settingsWindow = controller
            reflectSignIn()
        }
        if settingsWindow?.window?.isVisible != true { Analytics.send(.settingsOpened) }
        settingsWindow?.show(tab: tab)
        if let oauthNotice { settingsWindow?.model.oauthNotice = oauthNotice }
    }

    /// Colour, monogram, face and signature are written to the store directly; both windows re-read their accounts, and
    /// composers opened from then on take the new signature.
    private func edit(_ account: Account, _ change: (MailStoring) throws -> Void) {
        guard let environment else { return }
        do {
            try change(environment.store)
        } catch {
            Self.log.error("account edit failed: \(String(describing: error), privacy: .public)")
            NSSound.beep()
        }
        mainWindow?.refreshAccounts()
        settingsWindow?.refreshAccounts()
    }

    /// The Senders sheet's −: through the engine, as the menus set rules, so its observation reaches both windows.
    private func removeSenderRule(_ rule: SenderRule) {
        guard let environment else { return }
        do {
            try environment.engine.setSenderRule(nil, for: rule.address, accountID: rule.accountID, performing: [])
        } catch {
            Self.log.error("removing a sender rule failed: \(String(describing: error), privacy: .public)")
            NSSound.beep()
        }
    }

    // MARK: Menu actions

    @objc func showSettings(_ sender: Any?) {
        openSettings()
    }

    @objc func newMessage(_ sender: Any?) {
        mainWindow?.composeNew()
    }

    /// A composer opening while Settings is key (⌘N there, a notification's Reply, whose banner leaves Settings key)
    /// reads the accounts before Settings stops being key, so the signature being edited there is saved first. Settings
    /// in the background saved it when it stopped being key.
    private func saveSettingsEdits() {
        if settingsWindow?.window?.isKeyWindow == true { settingsWindow?.endEditing() }
    }

    @objc func addGmailAccount(_ sender: Any?) {
        addAccount(.gmail, origin: originForMenu())
    }

    @objc func addMicrosoftAccount(_ sender: Any?) {
        addAccount(.microsoft, origin: originForMenu())
    }

    @objc func leaveDemo(_ sender: Any?) {
        confirmLeavingDemo(origin: originForMenu())
    }

    /// View › Check for New Mail: a check the user asked for, which Settings and the sync line both show as
    /// Checking for mail… (§5.11). The main window starts the sync and watches it finish.
    @objc func checkForNewMail(_ sender: Any?) {
        guard let environment else { return }
        settingsWindow?.model.userChecks.formUnion(menuAccounts.map(\.id))
        if let mainWindow {
            mainWindow.checkForNewMail()
        } else {
            environment.engine.syncNow(accountID: nil)
        }
    }

    @objc func toggleCompactRows(_ sender: Any?) {
        settings.listDensity = settings.listDensity == .compact ? .standard : .compact
    }

    /// ? and ⌘/ (Help › Keyboard Shortcuts): the in-window cheat sheet over the main window (§5.32).
    @objc func showKeyboardHelp(_ sender: Any?) {
        guard let mainWindow, let window = mainWindow.keyboardWindow else { return }
        if !window.isKeyWindow { window.makeKeyAndOrderFront(nil) }
        CheatSheetController.shared.toggle(in: window)
    }

    /// The welcome screen's “Set up OAuth clients…”.
    @objc func showOAuthHelp(_ sender: Any?) {
        openSettings(tab: .oauth)
    }

    #if DEBUG
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
    #endif

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let hasEnvironment = environment != nil
        switch menuItem.action {
        case #selector(addGmailAccount(_:)), #selector(addMicrosoftAccount(_:)):
            // One sign-in at a time (§5.44).
            return hasEnvironment && signIn == nil && !isPreparingDemo
        case #selector(leaveDemo(_:)):
            return environment?.isDemo == true && signIn == nil
        case #selector(checkForNewMail(_:)):
            return hasEnvironment && !menuAccounts.isEmpty
        case #selector(toggleCompactRows(_:)):
            menuItem.state = settings.listDensity == .compact ? .on : .off
            return true
        case #selector(showKeyboardHelp(_:)):
            return mainWindow?.keyboardWindow != nil
        case #selector(newMessage(_:)), #selector(showSettings(_:)), #selector(showOAuthHelp(_:)):
            return hasEnvironment
        default:
            return true
        }
    }
}
