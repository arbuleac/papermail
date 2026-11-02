import AppKit
import Combine
import SSCore
import SSDesign
import SwiftUI

/// The Settings window (spec §5.40): a system window with the toolbar tab style (Accounts, OAuth, General),
/// 560 pt wide on `canvas`, as tall as the current tab's content. Everything inside a tab is Quire-drawn
/// SwiftUI; the toolbar and its tabs are the system's.
@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    let model: SettingsModel
    private let environment: AppEnvironment
    private let tabs: SettingsTabViewController
    private var statusObservation: StoreObservation?

    init(environment: AppEnvironment, settings: AppSettings) {
        self.environment = environment
        model = SettingsModel(isDemo: environment.isDemo, oauthFileURL: environment.clientConfigurations.fileURL)
        tabs = SettingsTabViewController(model: model, settings: settings)
        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.toolbarStyle = .preference
        window.backgroundColor = .qCanvas
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        super.init(window: window)
        window.delegate = self
        tabs.fitWindow(animate: false)
        window.center()
        // The saved frame brings back the position; the size always follows the content.
        window.setFrameAutosaveName("Settings")
        refreshAccounts()
        tabs.fitWindow(animate: false)
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
    }

    required init?(coder: NSCoder) {
        nil
    }

    func tearDown() {
        statusObservation?.cancel()
        statusObservation = nil
        window?.orderOut(nil)
    }

    func refreshAccounts() {
        model.setAccounts(((try? environment.store.accounts()) ?? []).sorted { $0.addedAt < $1.addedAt })
    }

    func show(tab: SettingsModel.Tab? = nil) {
        if let tab { model.tab = tab }
        if model.tab == .oauth { model.reloadOAuth() }
        let wasVisible = window?.isVisible == true
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
        if !wasVisible { tabs.clearInitialFocus() }
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

    init(model: SettingsModel, settings: AppSettings) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
        tabStyle = .toolbar
        // The window resize is ours (`fitWindow`); the tab view's own cross-fade would fight it.
        transitionOptions = []
        canPropagateSelectedChildViewControllerTitle = true
        addTab(AccountsSettingsView(model: model, settings: settings), title: "Accounts", symbol: Quire.Icon.accountsTab)
        addTab(OAuthSettingsView(model: model), title: "OAuth", symbol: Quire.Icon.oauthTab)
        addTab(GeneralSettingsView(settings: settings), title: "General", symbol: Quire.Icon.generalTab)
        selectedTabViewItemIndex = Self.index(of: model.tab)
        tabObservation = model.$tab.removeDuplicates().sink { [weak self] tab in
            MainActor.assumeIsolated { self?.select(tab) }
        }
    }

    required init?(coder: NSCoder) {
        nil
    }

    private func addTab<Content: View>(_ content: Content, title: String, symbol: String) {
        let hosting = NSHostingController(rootView: content)
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
        }
    }

    private static func tab(at index: Int) -> SettingsModel.Tab {
        switch index {
        case 1: return .oauth
        case 2: return .general
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
