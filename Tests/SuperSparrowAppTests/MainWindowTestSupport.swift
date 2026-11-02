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
    let controller: MainWindowController

    /// With `accounts` false the store starts empty and the window shows the welcome screen.
    init(threads: Int = 8, spacing: TimeInterval = 600, accounts: Bool = true) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("SuperSparrowAppTests-\(UUID().uuidString)")
        environment = try AppEnvironment.makeScratch(in: directory)
        if accounts { try Self.seed(environment.store, threads: threads, spacing: spacing) }
        controller = MainWindowController(environment: environment, settings: ListTestSupport.settings())
        controller.window?.setFrameAutosaveName("")
        controller.window?.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
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
