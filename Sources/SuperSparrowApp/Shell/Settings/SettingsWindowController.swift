import AppKit
import Combine
import SSCore
import SSDesign
import SwiftUI

/// The Settings window (spec §5.40): a system window with the toolbar tab style (Accounts, OAuth, General, Appearance, AI,
/// Experimental), 560 pt wide on `canvas`, as tall as the current tab's content. Everything inside a tab is Quire-drawn
/// SwiftUI; the toolbar and its tabs are the system's. A theme switch reaches all of it in place: each tab redraws under
/// its `QuireThemeRoot`, and the environment's redraw sweep assigns the window's `canvas` again.
@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    let model: SettingsModel
    /// General's Mail links row.
    let defaultMailApp: DefaultMailAppModel
    /// General's At login row.
    let launchAtLogin: LaunchAtLoginModel
    /// General's line under Notifications while macOS keeps them, and the Dock badge, from SuperSparrow.
    let notificationPermission: NotificationPermissionModel
    /// The size beside General's Keep mail on this Mac.
    let mailboxSize: MailboxSizeModel
    /// Settings › AI: Help Me Write's provider, key or CLI, model and permission.
    let ai: AISettingsModel
    /// What every tab reads and writes; the snapshots hold Settings › Experimental's values on through it, in memory.
    let settings: AppSettings
    private let environment: AppEnvironment
    private let tabs: SettingsTabViewController
    private var statusObservation: StoreObservation?
    private var storageObservation: StoreObservation?
    private var senderRuleObservation: StoreObservation?

    /// `mailtoHandler` answers and changes which app opens mail links, `loginItem` whether SuperSparrow opens at login,
    /// and `notifications` what macOS lets it show: macOS in the app, fakes in tests (nil `notifications` is macOS's, which
    /// outside an app bundle answers that there is nothing to ask). `measureMailbox` reads the mailbox's size on disk (on
    /// a background task); by default, the environment's files.
    init(environment: AppEnvironment, settings: AppSettings, mailtoHandler: MailtoDefaultHandling, loginItem: LoginItemHandling,
         notifications: NotificationPermissionHandling? = nil, measureMailbox: (@Sendable () -> Int64)? = nil) {
        self.environment = environment
        self.settings = settings
        model = SettingsModel(isDemo: environment.isDemo, oauthFileURL: environment.clientConfigurations.fileURL)
        defaultMailApp = DefaultMailAppModel(handler: mailtoHandler)
        launchAtLogin = LaunchAtLoginModel(handler: loginItem)
        notificationPermission = NotificationPermissionModel(handler: notifications ?? SystemNotificationPermission())
        let databasePath = environment.databasePath
        let attachments = environment.attachmentDirectory
        mailboxSize = MailboxSizeModel(measure: measureMailbox ?? {
            AppEnvironment.footprint(databasePath: databasePath, attachmentDirectory: attachments)
        })
        ai = AISettingsModel(settings: settings, center: environment.helpMeWrite)
        tabs = SettingsTabViewController(model: model, settings: settings, defaultMailApp: defaultMailApp, mailboxSize: mailboxSize,
                                         launchAtLogin: launchAtLogin, notificationPermission: notificationPermission, ai: ai)
        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.toolbarStyle = .preference
        window.backgroundColor = .qCanvas
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        super.init(window: window)
        window.delegate = self
        // Settings › AI's privacy sheet goes on this window, as the provider is chosen (§5.40).
        ai.window = { [weak window] in window }
        tabs.fitWindow(animate: false)
        window.center()
        // The saved frame brings back the position; the size always follows the content.
        window.setFrameAutosaveName("Settings")
        refreshAccounts()
        tabs.fitWindow(animate: false)
        NotificationCenter.default.addObserver(self, selector: #selector(appDidBecomeActive(_:)),
                                               name: NSApplication.didBecomeActiveNotification, object: nil)
        statusObservation = environment.engine.observeStatus { [weak self] statuses in
            MainActor.assumeIsolated {
                guard let self else { return }
                let fresh = Dictionary(statuses.map { ($0.accountID, $0) }, uniquingKeysWith: { first, _ in first })
                // A check the user asked for ends when its account settles (a reconnected account is still
                // marked as needing sign-in until its syncer wakes, so that does not end it).
                for (id, status) in fresh where status.phase == .idle || status.phase == .error { self.model.userChecks.remove(id) }
                if fresh != self.model.statuses { self.model.statuses = fresh }
                self.refreshAccounts()
            }
        }
        storageObservation = environment.engine.observeStorageChanges { [weak self] in
            MainActor.assumeIsolated { self?.mailboxMayHaveChanged() }
        }
        // Rules are set from the main window's menus while the Senders sheet may be open, and the engine writes what it
        // reads from the server.
        senderRuleObservation = environment.store.observeSenderRules { [weak self] rules in
            MainActor.assumeIsolated { self?.model.setSenderRules(rules) }
        }
        let engine = environment.engine
        model.refreshServerRules = { account in engine.refreshServerRules(accountID: account.id) }
    }

    /// The engine swept or trimmed, which changes the size by more than mail arriving: measured again only while the
    /// window shows, since opening it measures anyway.
    func mailboxMayHaveChanged() {
        guard window?.isVisible == true else { return }
        mailboxSize.refresh()
    }

    required init?(coder: NSCoder) {
        nil
    }

    func tearDown() {
        NotificationCenter.default.removeObserver(self, name: NSApplication.didBecomeActiveNotification, object: nil)
        statusObservation?.cancel()
        statusObservation = nil
        storageObservation?.cancel()
        storageObservation = nil
        senderRuleObservation?.cancel()
        senderRuleObservation = nil
        model.isWindowOpen = false
        model.stopRetryClock()
        window?.orderOut(nil)
    }

    func refreshAccounts() {
        model.setAccounts(((try? environment.store.accounts()) ?? []).sorted { $0.addedAt < $1.addedAt })
    }

    func show(tab: SettingsModel.Tab? = nil) {
        if let tab { model.tab = tab }
        if model.tab == .oauth { model.reloadOAuth() }
        let wasVisible = window?.isVisible == true
        model.isWindowOpen = true
        // Reopened on General, the tab's view does not appear again; the default mail app, the login item, the
        // notification permission and the mailbox's size may have changed meanwhile.
        if !wasVisible, model.tab == .general {
            defaultMailApp.refresh()
            launchAtLogin.refresh()
            notificationPermission.refresh()
            mailboxSize.refresh()
        }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
        if !wasVisible { tabs.clearInitialFocus() }
    }

    /// Back from another app, where the user may have chosen another mail app, or approved the login item or allowed
    /// notifications in System Settings: General asks again while it shows.
    @objc private func appDidBecomeActive(_ note: Notification) {
        guard window?.isVisible == true, model.tab == .general else { return }
        defaultMailApp.refresh()
        launchAtLogin.refresh()
        notificationPermission.refresh()
    }

    /// Ends editing in the window, so a field that saves when editing ends (the signature) saves now: before quitting
    /// closes the store, and before a composer opened from here reads the accounts.
    func endEditing() {
        window?.makeFirstResponder(nil)
    }

    /// Closing keeps the controller and its model for the next show; their retry clock stops until then.
    func windowWillClose(_ notification: Notification) {
        model.isWindowOpen = false
    }

    /// The window the user is looking at for Settings alerts (remove, reconnect, add from +).
    var visibleWindow: NSWindow? {
        guard let window, window.isVisible else { return nil }
        return window
    }
}

/// The toolbar tabs. Each tab is a hosting controller that reports its SwiftUI content's height; the window
/// follows the selected tab's height, keeping its top edge where it is, as system Settings windows do.
@MainActor
final class SettingsTabViewController: NSTabViewController {
    private let model: SettingsModel
    private var tabObservation: AnyCancellable?
    private var isSyncingSelection = false

    init(model: SettingsModel, settings: AppSettings, defaultMailApp: DefaultMailAppModel, mailboxSize: MailboxSizeModel,
         launchAtLogin: LaunchAtLoginModel, notificationPermission: NotificationPermissionModel, ai: AISettingsModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
        tabStyle = .toolbar
        // The window resize is ours (`fitWindow`); the tab view's own cross-fade would fight it.
        transitionOptions = []
        canPropagateSelectedChildViewControllerTitle = true
        addTab(AccountsSettingsView(model: model, settings: settings), title: "Accounts", symbol: Quire.Icon.accountsTab)
        addTab(OAuthSettingsView(model: model), title: "OAuth", symbol: Quire.Icon.oauthTab)
        addTab(GeneralSettingsView(settings: settings, defaultMailApp: defaultMailApp, mailboxSize: mailboxSize, launchAtLogin: launchAtLogin,
                                   notificationPermission: notificationPermission),
               title: "General", symbol: Quire.Icon.generalTab)
        // Appended, so no tab a user knows moves.
        addTab(AppearanceSettingsView(settings: settings), title: "Appearance", symbol: Quire.Icon.appearanceTab)
        addTab(AISettingsView(model: ai), title: "AI", symbol: Quire.Icon.aiTab)
        addTab(ExperimentalSettingsView(settings: settings), title: "Experimental", symbol: Quire.Icon.experimentalTab)
        selectedTabViewItemIndex = Self.index(of: model.tab)
        tabObservation = model.$tab.removeDuplicates().sink { [weak self] tab in
            MainActor.assumeIsolated { self?.select(tab) }
        }
    }

    required init?(coder: NSCoder) {
        nil
    }

    /// Each tab is hosted in a `QuireThemeRoot`, so a theme, Graphite or Increase Contrast switch redraws it in place,
    /// keeping focus and every field's state (spec §4.16).
    private func addTab<Content: View>(_ content: Content, title: String, symbol: String) {
        let hosting = NSHostingController(rootView: QuireThemeRoot(content).modifier(SnapshotDisplayScale()))
        hosting.sizingOptions = [.preferredContentSize]
        hosting.title = title
        let item = NSTabViewItem(viewController: hosting)
        item.label = title
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        addTabViewItem(item)
    }

    private static func index(of tab: SettingsModel.Tab) -> Int {
        switch tab {
        case .accounts: return 0
        case .oauth: return 1
        case .general: return 2
        case .appearance: return 3
        case .ai: return 4
        case .experimental: return 5
        }
    }

    private static func tab(at index: Int) -> SettingsModel.Tab {
        switch index {
        case 1: return .oauth
        case 2: return .general
        case 3: return .appearance
        case 4: return .ai
        case 5: return .experimental
        default: return .accounts
        }
    }

    private func select(_ tab: SettingsModel.Tab) {
        let index = Self.index(of: tab)
        guard selectedTabViewItemIndex != index else { return }
        isSyncingSelection = true
        selectedTabViewItemIndex = index
        isSyncingSelection = false
    }

    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        if !isSyncingSelection {
            let tab = Self.tab(at: selectedTabViewItemIndex)
            if model.tab != tab { model.tab = tab }
            if tab == .oauth { model.reloadOAuth() }
        }
        fitWindow(animate: view.window?.isVisible == true)
        clearInitialFocus()
    }

    /// SwiftUI hands focus to a tab's first field when it appears, selecting a client ID the user did not ask to
    /// edit. Settings opens with nothing focused, as system Settings windows do; Tab enters the first control.
    func clearInitialFocus() {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let window = self?.view.window else { return }
                window.makeFirstResponder(nil)
            }
        }
    }

    override func preferredContentSizeDidChange(for viewController: NSViewController) {
        super.preferredContentSizeDidChange(for: viewController)
        guard let selected = tabViewItems[safe: selectedTabViewItemIndex]?.viewController, selected === viewController else { return }
        fitWindow(animate: false)
    }

    /// Sizes the window to the selected tab: 560 pt wide, its content's height, never taller than the screen's
    /// visible frame, keeping the top edge in place.
    func fitWindow(animate: Bool) {
        guard let window = view.window, let selected = tabViewItems[safe: selectedTabViewItemIndex]?.viewController else { return }
        var size = selected.preferredContentSize
        if size.height <= 0 { size = selected.view.fittingSize }
        size.width = Quire.Layout.Settings.width
        if let visible = window.screen?.visibleFrame {
            let chrome = window.frame.height - window.contentRect(forFrameRect: window.frame).height
            size.height = min(size.height, visible.height - chrome)
        }
        let content = window.contentRect(forFrameRect: window.frame)
        guard abs(content.height - size.height) > 0.5 || abs(content.width - size.width) > 0.5 else { return }
        let target = window.frameRect(forContentRect: NSRect(x: content.minX, y: content.maxY - size.height, width: size.width, height: size.height))
        guard animate else {
            window.setFrame(target, display: true)
            return
        }
        // A height change, so it simply happens under Reduce Motion (§4.10).
        Quire.Motion.run(Quire.Motion.standard, .settle, reduced: .instant, animations: { _ in
            window.animator().setFrame(target, display: true)
        })
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
