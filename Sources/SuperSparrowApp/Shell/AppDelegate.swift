import AppKit
import SSCore
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
        if options.resetDemo { AppEnvironment.wipeDemoData() }
        start(mode: options.demo ? .demo : .real)
        NSApp.activate()
        if let path = options.snapshotPath {
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
                MainActor.assumeIsolated { self?.writeSnapshot(to: path) }
            }
        }
    }

    private func writeSnapshot(to path: String) {
        guard let view = mainWindow?.window?.contentView?.superview ?? mainWindow?.window?.contentView,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { return }
        do {
            try data.write(to: URL(fileURLWithPath: path))
            Self.log.info("snapshot written")
        } catch {
            Self.log.error("snapshot failed: \(error.localizedDescription, privacy: .public)")
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
        window.onTryDemo = { [weak self] in self?.switchToDemo() }
        window.onCancelSignIn = { [weak self] in self?.cancelSignIn() }
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
}
