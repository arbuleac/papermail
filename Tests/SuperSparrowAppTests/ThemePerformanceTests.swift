import AppKit
import SSCore
import SSDesign
import WebKit
import XCTest
@testable import SuperSparrowApp

/// The Theme and Dark Mode rows of the budgets in docs/ARCHITECTURE.md (spec §4.16), on Text size's fixture: the
/// synthetic mailbox in a real SQLite file, the conversation open and its two pre-rendered neighbours 30 messages each,
/// every sheet expanded, plain and styled bodies mixed (the styled ones declare their colours). A theme change in
/// Settings redraws the list within 50 ms (`list.theme`, which takes in the redraw sweep, measured here to the window
/// drawn) and restyles every pooled reader shell within 100 ms (`conversation.theme`, to the last shell's `themed`), with
/// nothing measured; a change of the Dark Mode default switches the affected bodies within 100 ms. Each theme is chosen
/// in turn, in Light and in Dark. Loading the mailbox takes a while, so it only runs with `SS_PERF=1`:
///
///     SS_PERF=1 swift test -c release --filter ThemePerformanceTests
///
/// `SS_LIST_PERF_MESSAGES` overrides the mailbox size (100,000 messages by default).
@MainActor
final class ThemePerformanceTests: XCTestCase {
    private typealias Support = ListTestSupport
    private var overridesBefore = QuireEnvironment.Overrides()
    private var appearanceBefore: NSAppearance?

    override func setUp() {
        super.setUp()
        MainActor.assumeIsolated {
            overridesBefore = QuireEnvironment.shared.overrides
            appearanceBefore = NSApplication.shared.appearance
        }
    }

    override func tearDown() {
        MainActor.assumeIsolated {
            QuireEnvironment.shared.setTheme(.study)
            QuireEnvironment.shared.setOverrides(overridesBefore)
            NSApplication.shared.appearance = appearanceBefore
        }
        super.tearDown()
    }

    func testAThemeSwitchAndTheDarkModeDefaultStayWithinBudget() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["SS_PERF"] == "1" else {
            throw XCTSkip("set SS_PERF=1 to run the theme benchmark")
        }
        let messageCount = Int(environment["SS_LIST_PERF_MESSAGES"] ?? "") ?? 100_000
        let harness = try MainWindowHarness(threads: 1)
        defer { harness.close() }
        let store = harness.environment.store
        // Two threads of one to three messages per hour: about a year and a half of mail for 100,000 messages.
        let messages = Support.messages(threads: messageCount / 2, now: Date(), spacing: 1_800)
        var index = 0
        while index < messages.count {
            let end = min(index + 2_000, messages.count)
            try store.upsertMessages(Array(messages[index..<end]))
            index = end
        }
        for thread in 0..<3 {
            try lengthen(thread: thread, to: 30, in: store)
        }
        Support.spin(until: { harness.list.conversations.count >= 3 && harness.list.conversations[2].id.providerID == "thread-2" }, timeout: 30)
        let window = try XCTUnwrap(harness.controller.window)
        window.setContentSize(NSSize(width: 1_280, height: 800))
        window.appearance = NSAppearance(named: .aqua)
        window.layoutIfNeeded()

        XCTAssertEqual(harness.list.conversations.prefix(3).map(\.id.providerID), ["thread-0", "thread-1", "thread-2"])
        let middle = harness.list.conversations[1].id
        harness.list.selectedConversationID = middle
        harness.list.onSelectionChange?(middle)
        var landed: WKWebView??
        harness.controller.whenReaderSettles(timeout: 20) { landed = .some($0) }
        Support.spin(until: { landed != nil }, timeout: 20)
        XCTAssertGreaterThanOrEqual(harness.reader.currentMessages.count, 30)
        let reader = harness.reader
        let pool = reader.pool
        Support.spin(until: { pool.slots.filter { $0.isReady && $0.renderedID != nil }.count == 3 }, timeout: 10)
        for slot in pool.slots where slot.isReady {
            slot.webView.evaluateJavaScript("window.ss && window.ss.expandAll()") { _, _ in }
        }
        Support.spin(for: 2)
        let frames = framedCards(in: reader)
        print("SS_PERF theme body frames across the shells: \(frames)")
        XCTAssertGreaterThanOrEqual(frames, 60, "every sheet open, in the open conversation and its neighbours")

        var themed: [QuireTheme] = []
        pool.onThemed = { themed.append($0) }
        defer { pool.onThemed = nil }

        var lists: [String: [Double]] = [:]
        var readers: [String: [Double]] = [:]
        let cycle = Array(QuireTheme.allCases.dropFirst()) + [.study]
        for (name, look) in [("Light", NSAppearance.Name.aqua), ("Dark", .darkAqua)] {
            // The app's appearance, as Settings › Appearance sets it, so the pre-rendered shells outside the window follow.
            NSApplication.shared.appearance = NSAppearance(named: look)
            window.appearance = NSAppearance(named: look)
            window.displayIfNeeded()
            // The shells take the new appearance through prefers-color-scheme, the pre-rendered ones outside the window
            // too; let them settle before timing. An appearance may change a shell's height (the notices of adapted mail),
            // a theme never does.
            let dark = name == "Dark"
            XCTAssertTrue(Support.spin(until: { pool.slots.filter(\.isReady).allSatisfy { self.isDark($0.webView) == dark } }, timeout: 5),
                          "\(name): every ready shell takes the appearance, outside the window too")
            Support.spin(for: 1)
            let heights = scrollHeights(in: pool)
            for round in 0..<(cycle.count * 2) {
                let theme = cycle[round % cycle.count]
                let start = DispatchTime.now()
                harness.settings.theme = theme
                window.displayIfNeeded()
                lists[name, default: []].append(milliseconds(since: start))
                XCTAssertTrue(Support.spin(until: { themed.last == theme }, timeout: 5), "\(name), \(theme): every shell restyled")
                readers[name, default: []].append(milliseconds(since: start))
                // A second choice comes no sooner than a click after the first.
                Support.spin(for: 0.1)
            }
            XCTAssertEqual(scrollHeights(in: pool), heights, "\(name): nothing was measured, every shell is as tall as before")
        }
        XCTAssertEqual(harness.settings.theme, .study)

        // The Dark Mode default, in Dark: the styled bodies that declare colours (15 of each 30) switch between adapted
        // and as sent, by class, with no frame built again; done when every ready shell has said what it shows.
        var defaults: [Double] = []
        let declaring = try declaringMessages(in: pool, store: store)
        XCTAssertTrue(pool.slots.filter(\.isReady).allSatisfy { self.isDark($0.webView) }, "every ready shell is dark")
        print("SS_PERF theme dark shells for the Dark Mode default: \(declaring.count)")
        XCTAssertEqual(declaring.count, 3, "the open conversation and its two neighbours")
        XCTAssertTrue(declaring.values.allSatisfy { $0.count >= 15 }, "15 styled bodies in each shell")
        for round in 0..<12 {
            let adapts = round % 2 == 1
            let start = DispatchTime.now()
            harness.settings.adaptsMailColours = adapts
            let switched = Support.spin(until: {
                pool.slots.filter(\.isReady).allSatisfy { slot in
                    slot.originalColorsShown == (adapts ? [] : declaring[ObjectIdentifier(slot)] ?? [])
                }
            }, timeout: 5)
            XCTAssertTrue(switched, "round \(round): every shell switched its bodies")
            defaults.append(milliseconds(since: start))
            Support.spin(for: 0.1)
        }
        XCTAssertTrue(harness.settings.adaptsMailColours)

        for name in ["Light", "Dark"] {
            report("list redrawn, \(name), median", percentile(lists[name] ?? [], 0.5))
            report("list redrawn, \(name), max", lists[name]?.max() ?? 0)
            report("every shell restyled, \(name), median", percentile(readers[name] ?? [], 0.5))
            report("every shell restyled, \(name), max", readers[name]?.max() ?? 0)
        }
        report("Dark Mode default, every shell switched, median", percentile(defaults, 0.5))
        report("Dark Mode default, every shell switched, max", defaults.max() ?? 0)
        let allLists = lists.values.flatMap { $0 }
        let allReaders = readers.values.flatMap { $0 }
        XCTAssertLessThan(percentile(allLists, 0.5), 50, "theme budget: the list")
        XCTAssertLessThan(percentile(allReaders, 0.5), 100, "theme budget: every pooled reader shell")
        XCTAssertLessThan(percentile(defaults, 0.5), 100, "Dark Mode default budget")
    }

    /// `thread`'s conversation (as `ListTestSupport.messages` numbers them) holds `count` messages, every other body
    /// plain and the rest styled HTML that declares its colours, each a few paragraphs long: Text size's fixture.
    private func lengthen(thread: Int, to count: Int, in store: MailStoring) throws {
        let account = thread % 2 == 0 ? Support.accountA : Support.accountB
        let conversation = ConversationID(accountID: account.id, providerID: "thread-\(thread)")
        let now = Date()
        var added: [MessageMetadata] = []
        for part in 0..<count {
            added.append(MessageMetadata(
                id: MessageID(accountID: account.id, providerID: "long-\(thread)-\(part)"),
                conversationID: conversation,
                subject: "Project update \(thread) and the quarterly planning document",
                snippet: "Just following up on the thread from last week.",
                from: Support.senders[(thread + part) % Support.senders.count],
                to: [EmailAddress(name: account.displayName, address: account.email)],
                date: now.addingTimeInterval(-Double(count - part) * 60 + Double(thread) * -7_200 + 3_600),
                roles: [.inbox], isRead: true, isStarred: false, hasAttachments: false
            ))
        }
        try store.upsertMessages(added)
        let paragraph = "Just following up on the thread from last week: the review moved, the numbers are in the sheet, and "
            + "the draft needs one more pass before Tuesday. Let me know which of the two times works for you."
        for (part, message) in added.enumerated() {
            let plain = part % 2 == 0
            let html = (0..<4).map { _ in plain ? "<p>\(paragraph)</p>" : "<p style=\"font-size:13px;color:#333\">\(paragraph)</p>" }.joined()
            try store.saveBody(StoredBody(body: MessageBody(html: html, text: paragraph), renderedHTML: html, plainText: paragraph,
                                          hasQuotedContent: false, blockedRemoteImageCount: 0,
                                          typesetting: plain ? .unstyled : .styled, declaresColors: !plain, coveredByNewYork: true),
                               for: message.id)
        }
    }

    /// Per ready shell, the messages it shows whose bodies declare their colours: what it shows as sent with Adapt off.
    private func declaringMessages(in pool: WebViewPool, store: MailStoring) throws -> [ObjectIdentifier: Set<MessageID>] {
        var out: [ObjectIdentifier: Set<MessageID>] = [:]
        for slot in pool.slots where slot.isReady {
            guard let id = slot.renderedID else { continue }
            var ids: Set<MessageID> = []
            for message in try store.messages(in: id) where try store.body(for: message.id)?.declaresColors == true {
                ids.insert(message.id)
            }
            out[ObjectIdentifier(slot)] = ids
        }
        return out
    }

    private func isDark(_ webView: WKWebView) -> Bool {
        var answer: Bool?
        webView.evaluateJavaScript("matchMedia('(prefers-color-scheme: dark)').matches") { value, _ in answer = (value as? Bool) ?? false }
        Support.spin(until: { answer != nil }, timeout: 5)
        return answer ?? false
    }

    /// Body frames across every ready shell.
    private func framedCards(in reader: ConversationViewController) -> Int {
        var total = 0
        var answered = 0
        let ready = reader.pool.slots.filter(\.isReady)
        for slot in ready {
            slot.webView.evaluateJavaScript("document.querySelectorAll('.ss-card iframe').length") { value, _ in
                total += (value as? Int) ?? 0
                answered += 1
            }
        }
        Support.spin(until: { answered == ready.count }, timeout: 5)
        return total
    }

    /// Every ready shell's document height, in pool order.
    private func scrollHeights(in pool: WebViewPool) -> [Int] {
        let ready = pool.slots.filter(\.isReady)
        var heights = [Int?](repeating: nil, count: ready.count)
        for (index, slot) in ready.enumerated() {
            slot.webView.evaluateJavaScript("document.documentElement.scrollHeight") { value, _ in heights[index] = (value as? Int) ?? -1 }
        }
        Support.spin(until: { heights.allSatisfy { $0 != nil } }, timeout: 5)
        return heights.map { $0 ?? -1 }
    }

    private func milliseconds(since start: DispatchTime) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e6
    }

    private func percentile(_ values: [Double], _ p: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * p).rounded()))]
    }

    private func report(_ label: String, _ value: Double) {
        print("SS_PERF theme \(label): \(String(format: "%.2f", value)) ms")
    }
}
