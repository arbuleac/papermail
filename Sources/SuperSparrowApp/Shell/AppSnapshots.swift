import AppKit
import SSCore
import SSDesign

/// The debug snapshots of the app-level surfaces (`--snapshot-welcome-states`, `--snapshot-settings`,
/// `--snapshot-settings-states`, `--snapshot-alerts`): each state is applied, given a moment to lay out (and
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
            // AI (§5.56), held for the render: Off; Claude Code found and signed in; Codex not found; OpenAI without a key;
            // Claude checking.
            { notificationPermission.showForSnapshot(.allowed); ai.showForSnapshot(provider: nil, status: .none); model.tab = .ai },
            { ai.showForSnapshot(provider: .claudeCode, status: .ready("Claude Code 2.1.322 \u{00b7} signed in with claude.ai"),
                                 hasConsent: true, cliPath: home + "/.local/bin/claude") },
            { ai.showForSnapshot(provider: .codex,
                                 status: .needsSetup(AIHealth.notFoundWords(for: .codex))) },
            { ai.showForSnapshot(provider: .openAIAPI, status: .needsSetup("Add your API key")) },
            { ai.showForSnapshot(provider: .claudeAPI, status: .checking, hasKey: true) },
        ]
        render(controller, steps: steps) { bitmap in
            model.oauth = original
            completion(bitmap)
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
