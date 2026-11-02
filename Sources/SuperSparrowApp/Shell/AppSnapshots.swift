import AppKit
import SSCore

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

    /// Accounts, OAuth and General, one under the other.
    static func renderSettingsTabs(_ controller: SettingsWindowController, completion: @escaping (NSBitmapImageRep?) -> Void) {
        let model = controller.model
        let steps: [() -> Void] = [{ model.tab = .accounts }, { model.tab = .oauth }, { model.tab = .general }]
        render(controller, steps: steps, completion: completion)
    }

    /// The Accounts and OAuth states of §5.40 that demo mode can show.
    static func renderSettingsStates(_ controller: SettingsWindowController, completion: @escaping (NSBitmapImageRep?) -> Void) {
        let model = controller.model
        let accounts = model.accounts
        let steps: [() -> Void] = [
            { model.tab = .accounts; model.pendingSignIn = .gmail },
            { model.pendingSignIn = nil; model.accountsNotice = .addFailed(kind: .gmail, reason: "Google refused the sign-in. Check the client ID.") },
            { model.accountsNotice = nil; model.reconnecting = accounts.last?.id },
            { model.reconnecting = nil; model.setAccounts([]) },
            { model.setAccounts(accounts); model.tab = .oauth; model.oauthNotice = .needsClient(.gmail) },
            { model.oauthNotice = .unreadable(reason: "The file isn't valid JSON.") },
            { model.oauthNotice = .saveFailed(reason: "The disk is full.") },
        ]
        render(controller, steps: steps, completion: completion)
    }

    private static func render(_ controller: SettingsWindowController, steps: [() -> Void],
                               completion: @escaping (NSBitmapImageRep?) -> Void) {
        guard let window = controller.window else { return completion(nil) }
        sequence(steps, render: { SnapshotRenderer.render(window: window) }) { bitmaps in
            completion(SnapshotRenderer.stack(bitmaps, appearance: window.effectiveAppearance))
        }
    }

    // MARK: Alerts

    /// Every alert of the inventory, two columns, each as NSAlert lays it out.
    static func renderAlerts(completion: @escaping (NSBitmapImageRep?) -> Void) {
        let appearance = NSApp.appearance ?? NSApp.effectiveAppearance
        var bitmaps: [NSBitmapImageRep] = []
        var alerts: [NSAlert] = []
        for spec in AppAlert.specimens {
            let alert = spec.makeAlert()
            alert.window.appearance = appearance
            alert.layout()
            alerts.append(alert)
        }
        // Lay out once more after a turn of the run loop so text fields settle their heights.
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                for alert in alerts {
                    alert.layout()
                    if let view = alert.window.contentView?.superview ?? alert.window.contentView,
                       let bitmap = SnapshotRenderer.render(view) {
                        bitmaps.append(bitmap)
                    }
                }
                completion(grid(bitmaps, columns: 3, appearance: appearance))
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
                                            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: canvas) else { return nil }
        canvas.size = NSSize(width: width, height: height)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        appearance.performAsCurrentDrawingAppearance {
            NSColor.windowBackgroundColor.setFill()
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
