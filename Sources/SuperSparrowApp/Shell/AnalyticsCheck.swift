#if DEBUG
import AppKit
import os
import SSCore

/// `--analytics-check` (debug builds, demo mode): a fixed round of the app's own steps, so what analytics sends can be
/// read end to end against a local listener (`--telemetry-url`, docs/ANALYTICS-AND-REPORTS.md, "Check it end to end").
/// It takes every step through the path a user's would take (the window's keys, its menu actions, Settings' model), waits
/// for the SDK to send, turns Analytics and reports off as Settings does, takes the same steps again, waits, and quits.
/// Nothing in the second round may reach the listener.
@MainActor
final class AnalyticsCheck {
    private let settings: AppSettings
    private let mainWindow: () -> MainWindowController?
    private let openSettings: () -> Void
    private var steps: [(delay: TimeInterval, name: String, run: () -> Void)] = []

    private static let log = Logger(subsystem: "io.supersparrow.mac", category: "analytics")

    init(settings: AppSettings, mainWindow: @escaping () -> MainWindowController?, openSettings: @escaping () -> Void) {
        self.settings = settings
        self.mainWindow = mainWindow
        self.openSettings = openSettings
    }

    /// Waits for the demo's inbox, then takes the steps one after another.
    func run() {
        round()
        // The SDK sends every 5 s against a local listener: give it two chances before turning off.
        step(11, "turn off") { [settings] in
            // As Settings' switch does, but for crash reports' folder: the bare binary shares it with the installed app,
            // which may be running (`CrashReporting.cacheDirectory`), and this run started no crash reporter to stop.
            settings.onAnalyticsAndReportsChanged = { Analytics.setEnabled($0) }
            settings.sendsAnalyticsAndReports = false
        }
        round()
        // Not from inside this main-queue callout, as `quittingSnapshotFinished` says: terminate waits for a main-actor task.
        step(12, "quit") {
            RunLoop.main.perform { MainActor.assumeIsolated { NSApp.terminate(nil) } }
        }
        waitForInbox(deadline: Date().addingTimeInterval(30))
    }

    private func round() {
        step(1, "open Settings") { [openSettings] in openSettings() }
        step(1, "compact rows") { [settings] in settings.listDensity = .compact }
        step(1, "standard rows") { [settings] in settings.listDensity = .standard }
        step(1, "close Settings") {
            NSApp.windows.first { $0.windowController is SettingsWindowController }?.close()
        }
        window(1, "select") { _ = $0.selectFirstConversation() }
        window(1, "star") { window in Analytics.from(.key) { _ = window.perform(.toggleStar) } }
        window(1, "unstar") { window in Analytics.from(.key) { _ = window.perform(.toggleStar) } }
        window(1, "archive") { window in Analytics.from(.key) { _ = window.perform(.archive) } }
        window(1, "undo") { window in Analytics.from(.key) { window.performUndo(window.zTarget) } }
        window(1, "search") { $0.listPane.runSearch("is:unread lisbon") }
        window(3, "search the server") { $0.searchServer(nil) }
        window(3, "leave search") { window in Analytics.from(.key) { _ = window.perform(.clearSearch) } }
        window(1, "reader window") { window in
            guard let id = window.selectFirstConversation() else { return }
            Analytics.from(.click) { _ = window.openInNewWindow(id) }
        }
        window(2, "close reader window") { $0.readerWindows.last?.close() }
        window(1, "hide day") { window in Analytics.from(.key) { _ = window.perform(.toggleDayColumn) } }
        window(1, "show day") { window in Analytics.from(.key) { _ = window.perform(.toggleDayColumn) } }
        window(1, "week") { window in Analytics.from(.key) { _ = window.perform(.toggleWeek) } }
        window(1, "leave week") { window in Analytics.from(.key) { _ = window.perform(.toggleWeek) } }
        window(1, "new message") { $0.composeNew() }
        step(1, "close composer") { ComposeWindowRegistry.shared.openControllers.last?.closeWithoutSaving() }
    }

    private func step(_ delay: TimeInterval, _ name: String, _ run: @escaping () -> Void) {
        steps.append((delay, name, run))
    }

    private func window(_ delay: TimeInterval, _ name: String, _ run: @escaping (MainWindowController) -> Void) {
        step(delay, name) { [mainWindow] in
            if let window = mainWindow() { run(window) }
        }
    }

    private func waitForInbox(deadline: Date) {
        if mainWindow()?.hasConversations == true || Date() > deadline {
            next()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [self] in
            MainActor.assumeIsolated { waitForInbox(deadline: deadline) }
        }
    }

    private func next() {
        guard !steps.isEmpty else { return }
        let step = steps.removeFirst()
        DispatchQueue.main.asyncAfter(deadline: .now() + step.delay) { [self] in
            MainActor.assumeIsolated {
                step.run()
                // On standard error too, with the time, so a listener's records can be matched to the steps.
                let line = String(format: "analytics-check %.3f %@ analytics=%@\n", Date().timeIntervalSince1970, step.name,
                                  Analytics.isRunning ? "on" : "off")
                FileHandle.standardError.write(Data(line.utf8))
                Self.log.info("analytics check: \(step.name, privacy: .public)")
                next()
            }
        }
    }
}
#endif
