import AppKit
import SSCore
import XCTest
@testable import SuperSparrowApp

/// A main window over a throwaway store in a temporary directory, seeded with `ListTestSupport`'s two
/// accounts and threads. The engine never starts: actions are applied to the store and queued, as they are
/// before the network answers, and nothing reaches the Keychain, the network or the user's mail.
@MainActor
final class MainWindowHarness {
    let directory: URL
    let environment: AppEnvironment
    let settings: AppSettings
    let controller: MainWindowController

    /// With `accounts` false the store starts empty and the window shows the welcome screen. `settings` defaults
    /// to a throwaway domain of its own; `demo` builds the window as the demo's; `remembersScope` false is a
    /// snapshot's window.
    init(threads: Int = 8, spacing: TimeInterval = 600, accounts: Bool = true, settings: AppSettings? = nil, demo: Bool = false,
         remembersScope: Bool = true) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("SuperSparrowAppTests-\(UUID().uuidString)")
        environment = try AppEnvironment.makeScratch(in: directory, mode: demo ? .demo : .real)
        if accounts { try Self.seed(environment.store, threads: threads, spacing: spacing) }
        let settings = settings ?? ListTestSupport.settings()
        self.settings = settings
        controller = MainWindowController(environment: environment, settings: settings, remembersScope: remembersScope)
        controller.window?.setFrameAutosaveName("")
        controller.window?.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        // Showing a window moves it onto a screen: reader windows open, and this one comes forward, off screen and unshown.
        controller.bringForward = { _ in }
        if accounts { ListTestSupport.spin(until: { !self.list.conversations.isEmpty }, timeout: 5) }
    }

    static func seed(_ store: MailStoring, threads: Int = 8, spacing: TimeInterval = 600) throws {
        try store.upsertAccount(ListTestSupport.accountA)
        try store.upsertAccount(ListTestSupport.accountB)
        try store.upsertMessages(ListTestSupport.messages(threads: threads, spacing: spacing))
    }

    var list: MessageListViewController { controller.list }
    var reader: ConversationViewController { controller.conversation }
    var toasts: ToastPresenter { controller.listPane.toasts }
    var toastMessage: String? { controller.listPane.toastView.slip?.message }

    /// Selects the first `count` conversations as ⇧J would.
    func selectFirst(_ count: Int) {
        list.selectedConversationID = list.conversations[0].id
        list.onSelectionChange?(list.conversations[0].id)
        for _ in 1..<max(1, count) { _ = controller.perform(.extendNext) }
    }

    func spin(until condition: () -> Bool) {
        ListTestSupport.spin(until: condition, timeout: 3)
    }

    /// Synchronous on purpose: tests spin the main run loop for store observations, which an async test
    /// method's main-queue job would hold back.
    func close() {
        controller.tearDown()
        controller.close()
        var finished = false
        let environment = environment
        Task { @MainActor in
            await environment.shutdown()
            finished = true
        }
        ListTestSupport.spin(until: { finished }, timeout: 5)
        try? FileManager.default.removeItem(at: directory)
    }
}

extension MainWindowHarness {
    /// Every run of a composer's body in its writing font on its exact lines. Plain text handed to the editor without
    /// them falls back to Helvetica 12, so one message would show two fonts, and a kept draft would keep both.
    static func assertWritingStyle(_ body: NSAttributedString, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertGreaterThan(body.length, 0, file: file, line: line)
        let whole = NSRange(location: 0, length: body.length)
        body.enumerateAttribute(.font, in: whole) { font, range, _ in
            XCTAssertEqual(font as? NSFont, ComposeTextView.bodyFont, "the font at \(range)", file: file, line: line)
        }
        body.enumerateAttribute(.paragraphStyle, in: whole) { style, range, _ in
            XCTAssertEqual((style as? NSParagraphStyle)?.minimumLineHeight, ComposeTextView.bodyRole.lineHeight,
                           "the line height at \(range)", file: file, line: line)
        }
    }

    /// A client over a throwaway store, for windows that need one but no main window.
    static func scratchClient(in folder: URL) throws -> MailClient {
        try AppEnvironment.makeScratch(in: folder.appendingPathComponent("client-\(UUID().uuidString)")).engine
    }
}
