import AppKit
import SSCore
import SSDesign
import SwiftUI

/// The debug snapshots of the app-level surfaces (`--snapshot-welcome-states`, `--snapshot-settings`,
/// `--snapshot-settings-states`, `--snapshot-senders`, `--snapshot-alerts`): each state is applied, given a moment to lay out (and
/// for delayed spinners to appear), drawn by the app itself, and the drawings are stacked into one PNG.
@MainActor
enum AppSnapshots {
    /// The welcome states are drawn in a window this size: the specimen's crop, a little roomier.
    static let welcomeStatesSize = NSSize(width: 820, height: 600)

    /// How long each state settles: SwiftUI swaps and lays out, a delayed spinner reveals (150 ms) and fades in.
    private static let settle: TimeInterval = 0.8

    /// Applies each step in turn and renders `render()` after it settles; calls `completion` with every drawing.
    private static func sequence(_ steps: [() -> Void], render: @escaping () -> NSBitmapImageRep?,
                                 completion: @escaping ([NSBitmapImageRep]) -> Void) {
        var bitmaps: [NSBitmapImageRep] = []
        func run(_ index: Int) {
            guard index < steps.count else { return completion(bitmaps) }
            steps[index]()
            DispatchQueue.main.asyncAfter(deadline: .now() + settle) {
                MainActor.assumeIsolated {
                    if let bitmap = render() { bitmaps.append(bitmap) }
                    run(index + 1)
                }
            }
        }
        run(0)
    }

    // MARK: Welcome

    static func renderWelcomeStates(in window: NSWindow, completion: @escaping (NSBitmapImageRep?) -> Void) {
        guard let welcome = window.contentViewController as? WelcomeViewController else { return completion(nil) }
        let steps: [() -> Void] = [
            { welcome.setActivity(.idle); welcome.showBanner(nil) },
            { welcome.setActivity(.waiting(.gmail)) },
            { welcome.setActivity(.preparingDemo) },
            { welcome.setActivity(.idle); welcome.showBanner(.demoFailed) },
            { welcome.showBanner(.signInError(reason: "Google refused the sign-in. Check the client ID in Settings › OAuth.")) },
            { welcome.showBanner(.missingClient(.gmail)) },
        ]
        sequence(steps, render: { SnapshotRenderer.render(window: window) }) { bitmaps in
            completion(SnapshotRenderer.stack(bitmaps, appearance: window.effectiveAppearance))
        }
    }

    // MARK: Settings

    /// The mailbox size Settings › General shows in a snapshot, so the render never depends on the Mac's mail.
    static let mailboxSize: @Sendable () -> Int64 = { 292_000_000 }

    /// Accounts, OAuth, General, Appearance and AI, one under the other. AI shows Claude with a key and the permission
    /// given, held for the render without writing the user's settings or reading their Keychain.
    static func renderSettingsTabs(_ controller: SettingsWindowController, completion: @escaping (NSBitmapImageRep?) -> Void) {
        let model = controller.model
        let ai = controller.ai
        let steps: [() -> Void] = [
            { model.tab = .accounts }, { model.tab = .oauth }, { model.tab = .general }, { model.tab = .appearance },
            {
                ai.showForSnapshot(provider: .claudeAPI, status: .ready("Ready \u{00b7} Claude Opus 5.5"), hasKey: true, hasConsent: true)
                model.tab = .ai
            },
        ]
        render(controller, steps: steps, completion: completion)
    }


    /// The Accounts, OAuth, General and AI states of §5.40 that demo mode can show. The OAuth fields are put back before
    /// the window closes; nothing here saves, Mail links neither asks nor changes which app opens mail links, At login
    /// neither asks nor changes the Mac's login items, and Notifications' line neither asks nor opens System Settings.
    static func renderSettingsStates(_ controller: SettingsWindowController, completion: @escaping (NSBitmapImageRep?) -> Void) {
        let model = controller.model
        let defaultMailApp = controller.defaultMailApp
        let launchAtLogin = controller.launchAtLogin
        let notificationPermission = controller.notificationPermission
        let ai = controller.ai
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let accounts = model.accounts
        let original = model.oauth
        let steps: [() -> Void] = [
            { model.tab = .accounts; model.pendingSignIn = .gmail },
            { model.pendingSignIn = nil; model.accountsNotice = .addFailed(kind: .gmail, reason: "Google refused the sign-in. Check the client ID.") },
            { model.accountsNotice = nil; model.reconnecting = accounts.last?.id },
            { model.reconnecting = nil; model.setAccounts([]) },
            // The face picker open over the first account (Quire §5.55), then the second wearing its monogram, the field
            // beside its face: the model's copy only, never the store.
            { model.setAccounts(accounts); model.selection = accounts.first?.id.rawValue; model.showsFacePicker = true },
            {
                var monogram = accounts
                if monogram.count > 1 { monogram[1].face = .monogram }
                model.setAccounts(monogram)
                model.selection = monogram.last?.id.rawValue
                model.showsFacePicker = true
            },
            { model.showsFacePicker = false; model.setAccounts(accounts); model.tab = .oauth; model.oauthNotice = .needsClient(.gmail) },
            { model.oauthNotice = .unreadable(reason: "The file isn't valid JSON.") },
            { model.oauthNotice = .saveFailed(reason: "The disk is full.") },
            // A validation line under its field, with Save enabled by the edit.
            { model.oauthNotice = nil; model.oauth.googleClientID = "1084-ab3f9kq2" },
            // “Saved” beside Save.
            { model.oauth = original; model.showSavedForSnapshot() },
            // Mail links: SuperSparrow is the default, then the button's failure.
            { model.tab = .general; defaultMailApp.showForSnapshot(.isDefault) },
            { defaultMailApp.showForSnapshot(.failed) },
            // At login: waiting for approval in System Settings, unavailable, then a change that did not take.
            { defaultMailApp.showForSnapshot(.isDefault); launchAtLogin.showForSnapshot(.needsApproval) },
            { launchAtLogin.showForSnapshot(.unavailable) },
            { launchAtLogin.showForSnapshot(.off, failed: .turnOn) },
            // Notifications: off for SuperSparrow in System Settings, then only the Dock badge off there.
            { launchAtLogin.showForSnapshot(.off); notificationPermission.showForSnapshot(.denied) },
            { notificationPermission.showForSnapshot(.allowedWithoutBadge) },
            // AI (§5.56), held for the render: Off; Claude Code as the tab opens (found, from this Mac) and after Check;
            // Codex not found; OpenAI without a key; Claude checking; Claude chosen before 1.12 and never turned on.
            { notificationPermission.showForSnapshot(.allowed); ai.showForSnapshot(provider: nil, status: .none); model.tab = .ai },
            { ai.showForSnapshot(provider: .claudeCode, status: .ready("Claude Code 2.1.322 found"), cliPath: home + "/.local/bin/claude") },
            { ai.showForSnapshot(provider: .claudeCode, status: .ready("Claude Code 2.1.322 \u{00b7} signed in with claude.ai"),
                                 cliPath: home + "/.local/bin/claude") },
            { ai.showForSnapshot(provider: .codex, status: .needsSetup(AIHealth.notFoundWords(for: .codex))) },
            { ai.showForSnapshot(provider: .openAIAPI, status: .needsSetup("Add your API key")) },
            { ai.showForSnapshot(provider: .claudeAPI, status: .checking, hasKey: true) },
            { ai.showForSnapshot(provider: .claudeAPI, status: .needsSetup(AISettingsModel.notTurnedOnWords), hasKey: true,
                                 hasConsent: false) },
        ]
        render(controller, steps: steps) { bitmap in
            model.oauth = original
            completion(bitmap)
        }
    }

    /// Settings › Accounts › Senders… (§5.52), a sheet no Settings snapshot holds, each state in a window of its own off
    /// screen on the sheet's `canvas`: first the demo's Gmail account as the sheet shows it (the seeded rule, the made-up
    /// server's other filters, no web link), then the states a real Gmail account goes through, drawn from content built
    /// here (neither the store nor the model is touched): saved and pending rows with the foot, the permission not given,
    /// its sign-in waiting for the browser, a failure, the first read; then an Outlook account.
    static func renderSenders(_ controller: SettingsWindowController, completion: @escaping (NSBitmapImageRep?) -> Void) {
        let model = controller.model
        let demo = model.accounts.first { $0.kind == .gmail } ?? model.accounts.first
        let gmail = Account(id: AccountID("snapshot-gmail"), kind: .gmail, email: "alex@contoso.test", displayName: "Alex Morgan",
                            addedAt: Date())
        let outlook = Account(id: AccountID("snapshot-outlook"), kind: .microsoft, email: "alex@fabrikam.test", displayName: "Alex Morgan",
                              addedAt: Date())
        let now = Date()
        func rule(_ account: Account, _ address: String, _ action: SenderRule.Action, _ sync: SenderRule.Sync) -> SenderRule {
            SenderRule(accountID: account.id, address: address, action: action, createdAt: now, serverIDs: sync == .creating ? [] : ["f"],
                       sync: sync)
        }
        func rules(_ account: Account) -> [SenderRule] {
            [rule(account, "deals@shop.example", .trash, .saved), rule(account, "news@letter.example", .archive, .creating),
             rule(account, "offers@deals.example", .trash, .deleting), rule(account, "updates@service.example", .archive, .replacing)]
        }
        func status(_ account: Account, _ rules: RulesSyncState) -> AccountSyncStatus {
            AccountSyncStatus(accountID: account.id, phase: .idle, lastSuccessfulSyncAt: now, rules: rules)
        }
        var contents: [SendersSheetContent] = []
        if let demo { contents.append(model.sendersContent(for: demo)) }
        contents += [
            SendersSheetContent(account: gmail, rules: rules(gmail), status: status(gmail, .upToDate(otherCount: 12, readAt: now)),
                                isReconnecting: false, isDemo: false),
            SendersSheetContent(account: gmail, rules: [rule(gmail, "news@letter.example", .archive, .creating)],
                                status: status(gmail, .notConnected), isReconnecting: false, isDemo: false),
            SendersSheetContent(account: gmail, rules: [rule(gmail, "news@letter.example", .archive, .creating)],
                                status: status(gmail, .notConnected), isReconnecting: true, isDemo: false),
            SendersSheetContent(account: gmail, rules: [rule(gmail, "deals@shop.example", .trash, .saved)],
                                status: status(gmail, .failed(.limitReached, otherCount: 12)), isReconnecting: false, isDemo: false),
            SendersSheetContent(account: gmail, rules: [], status: status(gmail, .unknown), isReconnecting: false, isDemo: false),
            SendersSheetContent(account: outlook, rules: rules(outlook), status: status(outlook, .upToDate(otherCount: 1, readAt: now)),
                                isReconnecting: false, isDemo: false),
        ]
        let appearance = NSApp.appearance ?? NSApp.effectiveAppearance
        let host = NSHostingView(rootView: AnyView(EmptyView()))
        let window = NSWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: Quire.Layout.Settings.sendersWidth, height: 400),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = appearance
        window.backgroundColor = .qCanvas
        window.contentView = host
        window.orderBack(nil)
        let steps: [() -> Void] = contents.map { content in
            {
                host.rootView = AnyView(QuireThemeRoot(SendersSheetBody(content: content, onRemove: { _ in }, onAllow: {}, onCancelSignIn: {},
                                                                        onOpenSettings: {}, onDone: {}))
                    .modifier(SnapshotDisplayScale()))
                let size = host.fittingSize
                window.setFrame(NSRect(origin: NSPoint(x: -30_000, y: -30_000), size: size), display: true)
            }
        }
        sequence(steps, render: {
            host.layoutSubtreeIfNeeded()
            return SnapshotRenderer.render(host)
        }) { bitmaps in
            window.orderOut(nil)
            completion(SnapshotRenderer.stack(bitmaps, background: .qRaised, appearance: appearance))
        }
    }

    private static func render(_ controller: SettingsWindowController, steps: [() -> Void],
                               completion: @escaping (NSBitmapImageRep?) -> Void) {
        guard let window = controller.window else { return completion(nil) }
        sequence(steps, render: { SnapshotRenderer.render(window: window) }) { bitmaps in
            completion(SnapshotRenderer.stack(bitmaps, appearance: window.effectiveAppearance))
        }
    }

    // MARK: Alerts

    /// Every alert of the inventory, three columns, each as NSAlert lays it out. Each is made key in turn, off
    /// screen, before it is drawn: the default button shows its emphasis only in the key window (§5.33).
    static func renderAlerts(completion: @escaping (NSBitmapImageRep?) -> Void) {
        let appearance = NSApp.appearance ?? NSApp.effectiveAppearance
        let alerts = AppAlert.specimens.map { spec -> NSAlert in
            let alert = spec.makeAlert()
            alert.window.appearance = appearance
            alert.layout()
            return alert
        }
        renderAlert(at: 0, of: alerts, into: [], appearance: appearance, completion: completion)
    }

    private static func renderAlert(at index: Int, of alerts: [NSAlert], into bitmaps: [NSBitmapImageRep], appearance: NSAppearance,
                                    completion: @escaping (NSBitmapImageRep?) -> Void) {
        guard alerts.indices.contains(index) else {
            completion(grid(bitmaps, columns: 3, appearance: appearance))
            return
        }
        let alert = alerts[index]
        let window = alert.window
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.makeKeyAndOrderFront(nil)
        // A turn of the run loop for the text fields to settle their heights and the key state to reach the buttons.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            MainActor.assumeIsolated {
                alert.layout()
                var bitmaps = bitmaps
                if let view = window.contentView?.superview ?? window.contentView, let bitmap = SnapshotRenderer.render(view) {
                    bitmaps.append(bitmap)
                }
                window.orderOut(nil)
                renderAlert(at: index + 1, of: alerts, into: bitmaps, appearance: appearance, completion: completion)
            }
        }
    }

    /// Bitmaps in rows of `columns`, top-aligned, 24 pt apart.
    private static func grid(_ bitmaps: [NSBitmapImageRep], columns: Int, appearance: NSAppearance) -> NSBitmapImageRep? {
        let rows = stride(from: 0, to: bitmaps.count, by: columns).map { Array(bitmaps[$0..<min($0 + columns, bitmaps.count)]) }
        let rowImages = rows.compactMap { row -> NSBitmapImageRep? in side(row, appearance: appearance) }
        return SnapshotRenderer.stack(rowImages, appearance: appearance)
    }

    private static func side(_ bitmaps: [NSBitmapImageRep], gap: CGFloat = 24, appearance: NSAppearance) -> NSBitmapImageRep? {
        guard let first = bitmaps.first else { return nil }
        let scale = CGFloat(first.pixelsWide) / max(1, first.size.width)
        let width = bitmaps.map(\.size.width).reduce(0, +) + gap * CGFloat(bitmaps.count - 1)
        let height = bitmaps.map(\.size.height).max() ?? 0
        guard let canvas = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int((width * scale).rounded(.up)),
                                            pixelsHigh: Int((height * scale).rounded(.up)), bitsPerSample: 8, samplesPerPixel: 4,
                                            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return nil }
        // The size in points before the context is made: the context takes its scale from it, so at
        // `--snapshot-scale=2` each point is two pixels rather than the images landing at half size in a corner.
        canvas.size = NSSize(width: width, height: height)
        guard let context = NSGraphicsContext(bitmapImageRep: canvas) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        appearance.performAsCurrentDrawingAppearance {
            NSColor.qCanvas.setFill()
            NSRect(x: 0, y: 0, width: width, height: height).fill()
        }
        var x: CGFloat = 0
        for bitmap in bitmaps {
            bitmap.draw(in: NSRect(x: x, y: height - bitmap.size.height, width: bitmap.size.width, height: bitmap.size.height),
                        from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)
            x += bitmap.size.width + gap
        }
        NSGraphicsContext.restoreGraphicsState()
        return canvas
    }
}
