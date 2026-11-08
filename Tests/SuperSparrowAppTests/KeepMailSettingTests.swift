import AppKit
@testable import SSCore
import SSDesign
import SwiftUI
import XCTest
@testable import SuperSparrowApp

/// Settings › General › Keep mail on this Mac (spec §5.40, roadmap Q1.6): three choices saved like the other General
/// settings, the engine following them, the mailbox's size beside the popup in plain words, measured when the tab
/// shows and after a clean-up, never on a timer, and `PRAGMA optimize` as quitting closes the store. Settings live in
/// throwaway defaults suites and stores in temporary folders.
@MainActor
final class KeepMailSettingTests: XCTestCase {
    private var suites: [String] = []
    private var directories: [URL] = []

    override func tearDown() {
        MainActor.assumeIsolated {
            for suite in suites { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
            for directory in directories { try? FileManager.default.removeItem(at: directory) }
            suites = []
            directories = []
        }
        super.tearDown()
    }

    private func defaults() throws -> UserDefaults {
        let suite = "SuperSparrowAppTests.KeepMail.\(UUID().uuidString)"
        suites.append(suite)
        return try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    private func scratchEnvironment() throws -> AppEnvironment {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("KeepMailSettingTests-\(UUID().uuidString)")
        directories.append(directory)
        return try AppEnvironment.makeScratch(in: directory)
    }

    // MARK: The setting

    func testTheThreeChoicesAreSavedAndEverythingIsTheDefault() throws {
        let defaults = try defaults()
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.keepMail, .everything, "today's behaviour by default")
        XCTAssertEqual(AppSettings.keepMailChoices, [.everything, .oneYear, .threeMonths], "in the popup's order")
        XCTAssertEqual(AppSettings.keepMailChoices.map(AppSettings.title(for:)), ["Everything", "1 year", "3 months"])

        for choice in AppSettings.keepMailChoices.reversed() {
            settings.keepMail = choice
            XCTAssertEqual(AppSettings(defaults: defaults).keepMail, choice, "saved across launches")
        }
        defaults.set("forever", forKey: "keepMail")
        XCTAssertEqual(AppSettings(defaults: defaults).keepMail, .everything, "an unknown value keeps everything")
    }

    func testTheEngineFollowsTheSetting() throws {
        let settings = AppSettings(defaults: try defaults())
        settings.keepMail = .oneYear
        let environment = try scratchEnvironment()
        XCTAssertEqual(environment.engine.mailRetention, .everything)
        environment.follow(settings)
        XCTAssertEqual(environment.engine.mailRetention, .oneYear, "it starts from the saved choice")
        settings.keepMail = .threeMonths
        XCTAssertEqual(environment.engine.mailRetention, .threeMonths)
        settings.keepMail = .everything
        XCTAssertEqual(environment.engine.mailRetention, .everything)
    }

    // MARK: The size

    func testTheSizeIsShownInPlainWords() {
        XCTAssertEqual(MailboxSizeModel.words(for: 292_000_000), "292 MB")
        XCTAssertEqual(MailboxSizeModel.words(for: 2_000_000_000), "2 GB")
        XCTAssertEqual(MailboxSizeModel.words(for: 40_000), "40 KB")

        let model = MailboxSizeModel(measure: { 292_000_000 })
        XCTAssertNil(model.label, "nothing stands in for the number before it is measured")
        model.refresh()
        XCTAssertTrue(ListTestSupport.spin(until: { model.label != nil }, timeout: 3))
        XCTAssertEqual(model.label, "292 MB")
    }

    /// A slow measurement answering after a newer one never shows.
    func testAnOlderMeasurementNeverOverwritesANewerOne() {
        let source = SizeSource([500_000_000, 292_000_000])
        source.delays = [0.3, 0]
        let model = MailboxSizeModel(measure: { source.next() })
        model.refresh()
        ListTestSupport.spin(for: 0.05)
        model.refresh()
        ListTestSupport.spin(for: 0.5)
        XCTAssertEqual(model.label, "292 MB")
    }

    /// The real measurement: the database with its WAL and shared-memory files, plus the attachment cache.
    func testTheFootprintCountsTheDatabaseAndTheAttachmentCache() throws {
        let environment = try scratchEnvironment()
        let databaseOnly = AppEnvironment.footprint(databasePath: environment.databasePath, attachmentDirectory: environment.attachmentDirectory)
        XCTAssertGreaterThan(databaseOnly, 0)
        let file = environment.attachmentDirectory.appendingPathComponent("acct/m1/a1")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 7, count: 100_000).write(to: file)
        let withAttachment = AppEnvironment.footprint(databasePath: environment.databasePath, attachmentDirectory: environment.attachmentDirectory)
        XCTAssertGreaterThanOrEqual(withAttachment - databaseOnly, 100_000)
    }

    /// Measured when General shows and after a clean-up while the window is open; nothing while it is closed, and
    /// nothing in between: there is no timer.
    func testTheSizeIsMeasuredWhenGeneralShowsAndAfterACleanUpNeverOnATimer() throws {
        _ = NSApplication.shared
        let environment = try scratchEnvironment()
        let source = SizeSource([292_000_000])
        let controller = SettingsWindowController(environment: environment, settings: ListTestSupport.settings(),
                                                  mailtoHandler: FakeMailtoHandler(), measureMailbox: { source.next() })
        defer { controller.tearDown() }
        let window = try XCTUnwrap(controller.window)
        window.setFrameAutosaveName("")
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        XCTAssertEqual(source.calls, 0, "nothing is measured before Settings shows")

        controller.show(tab: .general)
        XCTAssertTrue(ListTestSupport.spin(until: { controller.mailboxSize.label == "292 MB" }, timeout: 3))
        let shown = source.calls
        XCTAssertGreaterThanOrEqual(shown, 1)
        ListTestSupport.spin(for: 0.5)
        XCTAssertEqual(source.calls, shown, "no timer measures it again")

        controller.mailboxMayHaveChanged()
        XCTAssertTrue(ListTestSupport.spin(until: { source.calls == shown + 1 }, timeout: 3), "a clean-up measures it again")

        window.performClose(nil)
        controller.mailboxMayHaveChanged()
        ListTestSupport.spin(for: 0.2)
        XCTAssertEqual(source.calls, shown + 1, "not while the window is closed")

        controller.show(tab: .general)
        XCTAssertTrue(ListTestSupport.spin(until: { source.calls > shown + 1 }, timeout: 3), "reopening on General measures it")
        window.performClose(nil)
    }

    /// The control as General hosts it: the popup alone until the size is measured, then the size after it, the gap
    /// `settings.mailboxSizeGap` away. The General tab measures as it appears.
    func testTheSizeAppearsBesideThePopupOnceMeasured() throws {
        let settings = AppSettings(defaults: try defaults())
        let size = MailboxSizeModel(measure: { 292_000_000 })
        let popupOnly = NSHostingView(rootView: KeepMailControl(settings: settings, mailboxSize: MailboxSizeModel(measure: { 0 })))
        let control = NSHostingView(rootView: KeepMailControl(settings: settings, mailboxSize: size))
        XCTAssertEqual(control.fittingSize.width, popupOnly.fittingSize.width, accuracy: 0.5, "nothing beside the popup before the answer")

        let general = NSHostingView(rootView: GeneralSettingsView(settings: settings, defaultMailApp: DefaultMailAppModel(handler: FakeMailtoHandler()),
                                                                  mailboxSize: size))
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 560, height: 700), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = general
        window.orderFrontRegardless()
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        XCTAssertTrue(ListTestSupport.spin(until: { size.label != nil }, timeout: 3), "the tab measures the size as it appears")
        XCTAssertEqual(size.label, "292 MB")

        ListTestSupport.spin(for: 0.05)
        let words = ("292 MB" as NSString).size(withAttributes: [.font: QuireFont.font(.meta)]).width
        XCTAssertEqual(control.fittingSize.width - popupOnly.fittingSize.width, Quire.Layout.Settings.mailboxSizeGap + words, accuracy: 2,
                       "the size follows the popup at the gap")
    }

    // MARK: The reader

    /// A clean-up never takes the body of a conversation on screen: the reader keeps what it renders whole for the run,
    /// so its attachment chips, Save Attachments… and Quick Look still find the files, while a conversation not shown
    /// loses its body as usual.
    func testAConversationOnScreenKeepsItsBodyThroughAClean_up() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let store = harness.environment.store
        let conversations = harness.list.conversations
        let shown = try XCTUnwrap(conversations.first { $0.hasAttachments })
        // Far from the selection, so no pre-render of the neighbours reaches it.
        let other = try XCTUnwrap(conversations.last)
        XCTAssertNotEqual(other.id, shown.id)
        let file = AttachmentInfo(id: "a1", filename: "plan.pdf", mimeType: "application/pdf", sizeBytes: 2_048, isInline: false)
        for message in try store.messages(in: shown.id) + store.messages(in: other.id) {
            try store.saveBody(StoredBody(body: MessageBody(html: "<p>Plan</p>", text: "Plan", attachments: [file]),
                                          renderedHTML: "<p>Plan</p>", plainText: "Plan"), for: message.id)
        }
        harness.list.selectedConversationID = shown.id
        harness.list.onSelectionChange?(shown.id)
        let save = NSMenuItem(title: "", action: #selector(MainWindowController.saveAttachments(_:)), keyEquivalent: "")
        harness.spin { harness.controller.validateMenuItem(save) }
        XCTAssertTrue(harness.controller.validateMenuItem(save), "the shown message's files are offered")

        // A clean-up as the engine's sweeper runs one, batch by batch, with a cutoff every message is older than.
        var evicted = 0
        while true {
            let batch = try store.evictBodies(receivedBefore: .distantFuture, excluding: harness.environment.engine.keptBodies, limit: 50)
            guard batch > 0 else { break }
            evicted += batch
        }
        XCTAssertGreaterThan(evicted, 0, "the clean-up ran")
        for message in try store.messages(in: other.id) {
            XCTAssertNil(try store.body(for: message.id), "a conversation not shown loses its body")
        }
        for message in try store.messages(in: shown.id) {
            XCTAssertNotNil(try store.body(for: message.id), "the one on screen keeps it")
        }
        XCTAssertTrue(harness.controller.validateMenuItem(save), "and Save Attachments… still finds its files")
    }

    /// The reader marks what it renders before it reads a body, but a page may still read a body in the instant before a
    /// clean-up's write commits. Its chips, Save Attachments… and Quick Look read the attachment list apart from the
    /// body, and an eviction keeps the list, so they still find the files.
    func testAConversationWhoseBodyWasEvictedAsItRenderedStillFindsItsFiles() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let store = harness.environment.store
        let shown = try XCTUnwrap(harness.list.conversations.first { $0.hasAttachments })
        let file = AttachmentInfo(id: "a1", filename: "plan.pdf", mimeType: "application/pdf", sizeBytes: 2_048, isInline: false)
        for message in try store.messages(in: shown.id) {
            try store.saveBody(StoredBody(body: MessageBody(html: "<p>Plan</p>", text: "Plan", attachments: [file]),
                                          renderedHTML: "<p>Plan</p>", plainText: "Plan"), for: message.id)
        }
        harness.list.selectedConversationID = shown.id
        harness.list.onSelectionChange?(shown.id)
        let save = NSMenuItem(title: "", action: #selector(MainWindowController.saveAttachments(_:)), keyEquivalent: "")
        harness.spin { harness.controller.validateMenuItem(save) }
        XCTAssertTrue(harness.controller.validateMenuItem(save))

        // The batch that read its marks just before the reader made them.
        while try store.evictBodies(receivedBefore: .distantFuture, excluding: [], limit: 50) > 0 {}
        for message in try store.messages(in: shown.id) { XCTAssertNil(try store.body(for: message.id)) }
        XCTAssertTrue(harness.controller.validateMenuItem(save), "Save Attachments… still finds the files")
    }

    /// A message that joins the open conversation without a body (an older one the backfill lists) is marked kept, so a
    /// backfill fetching it stores it whole for the next refresh, and it is fetched at once, as opening it would.
    func testAMessageJoiningTheOpenConversationWithoutABodyIsKeptAndFetchedAtOnce() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let store = harness.environment.store
        let shown = harness.list.conversations[0]
        let messages = try store.messages(in: shown.id)
        for message in messages {
            try store.saveBody(StoredBody(body: MessageBody(html: "<p>Hi</p>", text: "Hi"), renderedHTML: "<p>Hi</p>", plainText: "Hi"),
                               for: message.id)
        }
        harness.list.selectedConversationID = shown.id
        harness.list.onSelectionChange?(shown.id)
        harness.spin { harness.reader.currentMessages.count == messages.count }
        XCTAssertEqual(harness.reader.currentMessages.count, messages.count)
        XCTAssertTrue(Set(messages.map(\.id)).isSubset(of: harness.environment.engine.keptBodies))

        var older = try XCTUnwrap(messages.first)
        older.id = MessageID(accountID: shown.id.accountID, providerID: "joined-older")
        older.date = older.date.addingTimeInterval(-86_400 * 400)
        try store.upsertMessages([older])
        harness.spin { harness.reader.bodyState(of: older.id) != nil }
        XCTAssertTrue(harness.reader.currentMessages.contains { $0.id == older.id })
        XCTAssertNotNil(harness.reader.bodyState(of: older.id), "its body was asked for at once")
        XCTAssertTrue(harness.environment.engine.keptBodies.contains(older.id), "and a backfill fetching it stores it whole")
    }

    // MARK: Quitting

    /// Quitting closes the store after `PRAGMA optimize`, which runs while the store is still open.
    func testQuittingRunsPragmaOptimizeBeforeTheStoreCloses() throws {
        let environment = try scratchEnvironment()
        let real = try XCTUnwrap(environment.store as? MailStoreMaintenance)
        let spy = OptimizeSpy(forwardingTo: real)
        environment.storeMaintenance = spy
        var finished = false
        Task { @MainActor in
            await AppDelegate.prepareToQuit(settings: nil, environments: [environment])
            finished = true
        }
        XCTAssertTrue(ListTestSupport.spin(until: { finished }, timeout: 5))
        XCTAssertEqual(spy.results.count, 1, "once")
        XCTAssertEqual(spy.results.first, true, "and it ran on an open store")
        XCTAssertThrowsError(try environment.store.accounts(), "then the store closed")
    }
}

/// Hands out sizes in turn (the last one again once they run out), counting calls; a delay holds an answer back.
private final class SizeSource: @unchecked Sendable {
    private let lock = NSLock()
    private var sizes: [Int64]
    private var count = 0
    var delays: [TimeInterval] = []

    init(_ sizes: [Int64]) {
        self.sizes = sizes
    }

    var calls: Int { lock.withLock { count } }

    func next() -> Int64 {
        let (size, delay): (Int64, TimeInterval) = lock.withLock {
            let index = count
            count += 1
            return (sizes[min(index, sizes.count - 1)], index < delays.count ? delays[index] : 0)
        }
        if delay > 0 { Thread.sleep(forTimeInterval: delay) }
        return size
    }
}

/// Forwards `optimize` to the real store and records whether it succeeded, which it cannot once the store is closed.
private final class OptimizeSpy: MailStoreMaintenance, @unchecked Sendable {
    private let lock = NSLock()
    private let real: MailStoreMaintenance
    private var outcomes: [Bool] = []

    init(forwardingTo real: MailStoreMaintenance) {
        self.real = real
    }

    var results: [Bool] { lock.withLock { outcomes } }

    func optimize() throws {
        do {
            try real.optimize()
            lock.withLock { outcomes.append(true) }
        } catch {
            lock.withLock { outcomes.append(false) }
            throw error
        }
    }

    func mergeFullTextIndex(pages: Int, startingOver: Bool) throws -> Bool {
        try real.mergeFullTextIndex(pages: pages, startingOver: startingOver)
    }

    func reclaimFreePages(upTo pages: Int) throws -> Int? {
        try real.reclaimFreePages(upTo: pages)
    }
}
