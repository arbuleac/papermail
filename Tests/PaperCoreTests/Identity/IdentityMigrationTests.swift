import Foundation
import XCTest
@testable import PaperCore

/// The first launch's move from SuperSparrow, on temporary folders and a dictionary standing in for the defaults: no test
/// reaches the user's Library, defaults or Keychain (`IdentityTestIsolationTests` holds that for every test).
final class IdentityMigrationTests: XCTestCase {
    private var root: URL!
    private var locations: IdentityMigration.Locations!
    private var defaults: FakeDefaults!
    private var runningChecks = 0

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "paper-identity-\(UUID().uuidString)", directoryHint: .isDirectory)
        let library = root.appending(path: "Library", directoryHint: .isDirectory)
        locations = IdentityMigration.Locations(
            applicationSupport: library.appending(path: "Application Support", directoryHint: .isDirectory),
            caches: library.appending(path: "Caches", directoryHint: .isDirectory),
            library: library
        )
        for folder in [locations.applicationSupport, locations.caches] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        defaults = FakeDefaults()
        runningChecks = 0
        // Never the user's own: every folder is the test's, under the temporary directory.
        let home = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library").standardizedFileURL.path
        for folder in [locations.applicationSupport, locations.caches, locations.library] {
            XCTAssertTrue(folder.standardizedFileURL.path.hasPrefix(FileManager.default.temporaryDirectory.standardizedFileURL.path))
            XCTAssertFalse(folder.standardizedFileURL.path.hasPrefix(home + "/"))
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: Fixtures

    private var legacySupport: URL { locations.applicationSupport.appending(path: "SuperSparrow") }
    private var newSupport: URL { locations.applicationSupport.appending(path: "app.paperinbox.mac") }
    private var legacyBundleCaches: URL { locations.caches.appending(path: "io.supersparrow.mac") }
    private var legacyAttachmentCaches: URL { locations.caches.appending(path: "SuperSparrow") }
    private var newCaches: URL { locations.caches.appending(path: "app.paperinbox.mac") }

    private func migration(bundle: String? = "app.paperinbox.mac", running: Bool = false,
                           files: IdentityMigration.FileOperations = .system) -> IdentityMigration {
        var migration = IdentityMigration(bundleIdentifier: bundle, locations: locations, defaults: defaults) { [unowned self] in
            runningChecks += 1
            return running
        }
        migration.files = files
        return migration
    }

    private func write(_ text: String, _ path: String) throws {
        let url = root.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    /// The old app's state, all of it: its settings, its folder in Application Support (the mailbox with a write-ahead
    /// log, the demo's, the OAuth clients, drafts, a hidden file), its caches and its per-bundle leftovers.
    private func makeLegacy() throws {
        defaults.domains["io.supersparrow.mac"] = ["theme": "dusk", "keepMail": 90, "NSWindow Frame main": "0 0 900 600"]
        for (path, text) in [
            ("SuperSparrow/mail.sqlite", "mailbox"),
            ("SuperSparrow/mail.sqlite-wal", "mailbox log"),
            ("SuperSparrow/mail.sqlite-shm", "mailbox index"),
            ("SuperSparrow/demo.sqlite", "old demo"),
            ("SuperSparrow/oauth-clients.json", "clients"),
            ("SuperSparrow/Drafts/draft-1.json", "draft"),
            ("SuperSparrow/.hidden", "hidden"),
        ] {
            try write(text, "Library/Application Support/" + path)
        }
        try write("report", "Library/Caches/io.supersparrow.mac/Sentry/envelopes/1.envelope")
        try write("url cache", "Library/Caches/io.supersparrow.mac/Cache.db")
        try write("attachment", "Library/Caches/SuperSparrow/attachments/acct/msg/1")
        try write("web", "Library/WebKit/io.supersparrow.mac/WebsiteData/LocalStorage/x")
        try write("storage", "Library/HTTPStorages/io.supersparrow.mac/httpstorages.sqlite")
        try write("cookies", "Library/HTTPStorages/io.supersparrow.mac.binarycookies")
        try write("state", "Library/Saved Application State/io.supersparrow.mac.savedState/windows.plist")
    }

    /// Every file and folder under the test's root, with each file's text.
    private func tree() -> [String: String] {
        var entries: [String: String] = [:]
        let base = root.standardizedFileURL.path
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey])
        while let url = enumerator?.nextObject() as? URL {
            let path = String(url.standardizedFileURL.path.dropFirst(base.count + 1))
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                entries[path] = "/"
            } else {
                entries[path] = (try? String(contentsOf: url, encoding: .utf8)) ?? "?"
            }
        }
        return entries
    }

    private func text(_ path: String) -> String? {
        try? String(contentsOf: root.appending(path: path), encoding: .utf8)
    }

    private func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: root.appending(path: path).path)
    }

    private func inode(_ url: URL) throws -> Int? {
        try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? Int
    }

    // MARK: When it runs

    func testAFreshInstallFindsNothingAndTouchesNothing() throws {
        let before = tree()
        XCTAssertEqual(migration().run(), .ran)
        XCTAssertEqual(tree(), before, "no folder made, nothing moved")
        XCTAssertTrue(defaults.domains.isEmpty, "no settings written, not even the mark")
        XCTAssertEqual(defaults.writes, 0)
    }

    /// The bare binary (no bundle identifier), a test runner and the old app itself never move anything, and never even
    /// ask whether the old app runs.
    func testOnlyTheBundledAppEverRunsIt() throws {
        try makeLegacy()
        let before = tree()
        let settings = defaults.domains
        for bundle in [nil, Bundle.main.bundleIdentifier, "com.apple.dt.xctest.tool", "io.supersparrow.mac", "Paper"] {
            XCTAssertEqual(migration(bundle: bundle).run(), .notThisApp, String(describing: bundle))
        }
        XCTAssertEqual(runningChecks, 0)
        XCTAssertEqual(tree(), before)
        XCTAssertEqual(defaults.domains as NSDictionary, settings as NSDictionary)
        XCTAssertEqual(defaults.writes, 0)
    }

    /// The test process is not the bundled app, so nothing here can run the move or read an old Keychain item.
    func testThisProcessIsNeverTheOneTheMoveIsFor() {
        XCTAssertFalse(IdentityMigration.appliesToThisProcess)
        XCTAssertTrue(IdentityMigration.applies(toBundleIdentifier: AppIdentity.bundleIdentifier))
        XCTAssertFalse(IdentityMigration.applies(toBundleIdentifier: nil))
        XCTAssertNil(KeychainTokenStore.defaultLegacyService)
        XCTAssertNil(AIKeyStore.defaultLegacyService)
    }

    func testNothingMovesWhileTheOldAppRuns() throws {
        try makeLegacy()
        let before = tree()
        let settings = defaults.domains
        XCTAssertEqual(migration(running: true).run(), .deferred(applicationSupportWaiting: true))
        XCTAssertEqual(runningChecks, 1)
        XCTAssertEqual(tree(), before)
        XCTAssertEqual(defaults.domains as NSDictionary, settings as NSDictionary)
        XCTAssertEqual(defaults.writes, 0)

        // The next launch, with the old app quit, moves everything.
        XCTAssertEqual(migration().run(), .ran)
        XCTAssertEqual(text("Library/Application Support/app.paperinbox.mac/mail.sqlite"), "mailbox")
    }

    /// With the mailbox moved, the old app open again (on an empty folder of its own) does not hold Paper's launch up.
    func testTheOldAppRunningHoldsTheLaunchOnlyWhileItsFolderHasSomethingToMove() throws {
        try write("mailbox", "Library/Application Support/SuperSparrow/mail.sqlite")
        XCTAssertEqual(migration().run(), .ran)
        XCTAssertEqual(defaults.domains["app.paperinbox.mac"]?[IdentityMigration.mailboxMovedKey] as? Bool, true)
        try write("fresh", "Library/Application Support/SuperSparrow/mail.sqlite")
        XCTAssertEqual(migration(running: true).run(), .deferred(applicationSupportWaiting: false))
        try write("draft", "Library/Application Support/SuperSparrow/Drafts/1.json")
        XCTAssertEqual(migration(running: true).run(), .deferred(applicationSupportWaiting: true))
        try FileManager.default.removeItem(at: legacySupport)
        XCTAssertEqual(migration(running: true).run(), .deferred(applicationSupportWaiting: false))
    }

    /// A mailbox in each folder, the old one never moved: the old app open on it holds the launch up as well, since what
    /// Paper would open is not the user's mail.
    func testTheOldAppRunningOnAMailboxNeverMovedHoldsTheLaunch() throws {
        try write("mailbox", "Library/Application Support/SuperSparrow/mail.sqlite")
        try write("", "Library/Application Support/app.paperinbox.mac/mail.sqlite")
        XCTAssertEqual(migration(running: true).run(), .deferred(applicationSupportWaiting: true))
    }

    // MARK: Everything, from the old app alone

    func testTheOldAppsDataMovesWhole() throws {
        try makeLegacy()
        let folder = try inode(legacySupport)
        let queue = try inode(legacyBundleCaches.appending(path: "Sentry"))
        XCTAssertEqual(migration().run(), .ran)

        // Application Support: renamed, not copied.
        XCTAssertFalse(exists("Library/Application Support/SuperSparrow"))
        XCTAssertEqual(try inode(newSupport), folder)
        for (name, text) in [("mail.sqlite", "mailbox"), ("mail.sqlite-wal", "mailbox log"), ("mail.sqlite-shm", "mailbox index"),
                             ("demo.sqlite", "old demo"), ("oauth-clients.json", "clients"), ("Drafts/draft-1.json", "draft"),
                             (".hidden", "hidden")] {
            XCTAssertEqual(self.text("Library/Application Support/app.paperinbox.mac/" + name), text, name)
        }
        // Caches: the crash reports' queue moved, the rest of the old bundle's caches gone; the attachments moved.
        XCTAssertEqual(try inode(newCaches.appending(path: "Sentry")), queue)
        XCTAssertEqual(text("Library/Caches/app.paperinbox.mac/Sentry/envelopes/1.envelope"), "report")
        XCTAssertFalse(exists("Library/Caches/io.supersparrow.mac"))
        XCTAssertEqual(text("Library/Caches/app.paperinbox.mac/attachments/acct/msg/1"), "attachment")
        XCTAssertFalse(exists("Library/Caches/SuperSparrow"))
        // Leftovers: gone, with nothing else left in their folders.
        for path in ["Library/WebKit/io.supersparrow.mac", "Library/HTTPStorages/io.supersparrow.mac",
                     "Library/HTTPStorages/io.supersparrow.mac.binarycookies",
                     "Library/Saved Application State/io.supersparrow.mac.savedState"] {
            XCTAssertFalse(exists(path), path)
        }
        // Settings: copied with the mark, the old domain removed.
        let settings = try XCTUnwrap(defaults.domains["app.paperinbox.mac"])
        XCTAssertEqual(settings["theme"] as? String, "dusk")
        XCTAssertEqual(settings["keepMail"] as? Int, 90)
        XCTAssertEqual(settings["NSWindow Frame main"] as? String, "0 0 900 600")
        XCTAssertEqual(settings[IdentityMigration.migratedKey] as? Bool, true)
        XCTAssertNil(defaults.domains["io.supersparrow.mac"])
    }

    func testRunningAgainChangesNothing() throws {
        try makeLegacy()
        migration().run()
        let after = tree()
        let settings = defaults.domains
        let writes = defaults.writes
        XCTAssertEqual(migration().run(), .ran)
        XCTAssertEqual(tree(), after)
        XCTAssertEqual(defaults.domains as NSDictionary, settings as NSDictionary)
        XCTAssertEqual(defaults.writes, writes)
    }

    // MARK: Both folders

    /// The bare binary may have made the new folder for its demo before the bundled app first ran: everything the new
    /// folder lacks moves in, what both hold stays in the old folder, which stays until it is empty.
    func testBothFoldersMergeAndConflictsStayInTheOldOne() throws {
        try makeLegacy()
        try write("new demo", "Library/Application Support/app.paperinbox.mac/demo.sqlite")
        try write("new demo log", "Library/Application Support/app.paperinbox.mac/demo.sqlite-wal")
        try write("new draft", "Library/Application Support/app.paperinbox.mac/Drafts/draft-9.json")
        try write("old demo index", "Library/Application Support/SuperSparrow/demo.sqlite-shm")
        let mailbox = try inode(legacySupport.appending(path: "mail.sqlite"))

        XCTAssertEqual(migration().run(), .ran)

        let new = "Library/Application Support/app.paperinbox.mac/"
        XCTAssertEqual(text(new + "mail.sqlite"), "mailbox")
        XCTAssertEqual(try inode(newSupport.appending(path: "mail.sqlite")), mailbox, "renamed, not copied")
        XCTAssertEqual(text(new + "mail.sqlite-wal"), "mailbox log")
        XCTAssertEqual(text(new + "mail.sqlite-shm"), "mailbox index")
        XCTAssertEqual(text(new + "oauth-clients.json"), "clients")
        XCTAssertEqual(text(new + ".hidden"), "hidden")
        // The new folder's own are untouched; the old demo's index never sits beside the new demo.
        XCTAssertEqual(text(new + "demo.sqlite"), "new demo")
        XCTAssertEqual(text(new + "demo.sqlite-wal"), "new demo log")
        XCTAssertFalse(exists(new + "demo.sqlite-shm"))
        XCTAssertEqual(text(new + "Drafts/draft-9.json"), "new draft")
        XCTAssertFalse(exists(new + "Drafts/draft-1.json"))
        // What both held stays in the old folder, whole.
        let old = "Library/Application Support/SuperSparrow/"
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: legacySupport.path)), ["demo.sqlite", "demo.sqlite-shm", "Drafts"])
        XCTAssertEqual(text(old + "demo.sqlite"), "old demo")
        XCTAssertEqual(text(old + "demo.sqlite-shm"), "old demo index")
        XCTAssertEqual(text(old + "Drafts/draft-1.json"), "draft")

        // Again: nothing changes, and the old folder stays while it holds something.
        let after = tree()
        migration().run()
        XCTAssertEqual(tree(), after)

        // Once its last items are gone, the next launch removes it.
        for name in ["demo.sqlite", "demo.sqlite-shm", "Drafts"] {
            try FileManager.default.removeItem(at: legacySupport.appending(path: name))
        }
        migration().run()
        XCTAssertFalse(exists("Library/Application Support/SuperSparrow"))
    }

    func testAMergeWithNothingInCommonRemovesTheOldFolder() throws {
        try write("mailbox", "Library/Application Support/SuperSparrow/mail.sqlite")
        try write("clients", "Library/Application Support/SuperSparrow/oauth-clients.json")
        try write("new demo", "Library/Application Support/app.paperinbox.mac/demo.sqlite")
        migration().run()
        XCTAssertFalse(exists("Library/Application Support/SuperSparrow"))
        XCTAssertEqual(text("Library/Application Support/app.paperinbox.mac/mail.sqlite"), "mailbox")
        XCTAssertEqual(text("Library/Application Support/app.paperinbox.mac/oauth-clients.json"), "clients")
        XCTAssertEqual(text("Library/Application Support/app.paperinbox.mac/demo.sqlite"), "new demo")
    }

    /// A database and its companions are one: they move together into a folder that has none of them, never one of them
    /// beside another database. A companion left behind by a move cut off after its database follows it.
    func testADatabaseMovesWithItsCompanionsOrNotAtAll() {
        let all = ["mail.sqlite", "mail.sqlite-wal", "mail.sqlite-shm", "oauth-clients.json"]
        XCTAssertEqual(IdentityMigration.plan(legacy: all, new: []),
                       .init(moves: [["mail.sqlite", "mail.sqlite-wal", "mail.sqlite-shm"], ["oauth-clients.json"]], kept: 0))
        XCTAssertEqual(IdentityMigration.plan(legacy: all, new: ["mail.sqlite"]),
                       .init(moves: [["oauth-clients.json"]], kept: 3))
        XCTAssertEqual(IdentityMigration.plan(legacy: all, new: ["mail.sqlite-shm"]),
                       .init(moves: [["oauth-clients.json"]], kept: 3), "another database's companion is there")
        XCTAssertEqual(IdentityMigration.plan(legacy: ["mail.sqlite-wal", "mail.sqlite-shm"], new: ["mail.sqlite"]),
                       .init(moves: [["mail.sqlite-wal"], ["mail.sqlite-shm"]], kept: 0), "a move cut off after the database")
        XCTAssertEqual(IdentityMigration.plan(legacy: ["mail.sqlite-wal", "mail.sqlite-shm"], new: ["mail.sqlite", "mail.sqlite-shm"]),
                       .init(moves: [["mail.sqlite-wal"]], kept: 1))
        XCTAssertEqual(IdentityMigration.plan(legacy: ["mail.sqlite-wal"], new: []),
                       .init(moves: [], kept: 1), "a companion with no database anywhere stays")
        XCTAssertEqual(IdentityMigration.plan(legacy: ["Drafts", "-wal"], new: ["Drafts"]),
                       .init(moves: [["-wal"]], kept: 1))
    }

    // MARK: A mailbox that cannot move

    /// The new folder holds a mailbox the move did not put there (a development build's, or a bare binary run on the
    /// real store before the first launch as Paper): the launch opens nothing and changes nothing of the old app's,
    /// every time, until one of the two mailboxes is moved out; then the move goes ahead.
    func testAMailboxTheNewFolderAlreadyHasHoldsTheLaunchAndMovesNothing() throws {
        try makeLegacy()
        try write("", "Library/Application Support/app.paperinbox.mac/mail.sqlite")
        try write("", "Library/Application Support/app.paperinbox.mac/mail.sqlite-wal")
        let before = tree()
        let settings = defaults.domains
        for _ in 0..<2 {
            XCTAssertEqual(migration().run(), .leftBehind(.mailboxInBothFolders))
            XCTAssertEqual(tree(), before, "nothing moved: not the OAuth clients or drafts either, which go with the mailbox")
            XCTAssertEqual(defaults.domains as NSDictionary, settings as NSDictionary, "the old app keeps its settings")
            XCTAssertEqual(defaults.writes, 0)
        }

        // The user moves Paper's mailbox out: the old one comes in whole.
        for suffix in ["", "-wal"] {
            try FileManager.default.removeItem(at: newSupport.appending(path: "mail.sqlite" + suffix))
        }
        XCTAssertEqual(migration().run(), .ran)
        XCTAssertFalse(exists("Library/Application Support/SuperSparrow"))
        XCTAssertEqual(text("Library/Application Support/app.paperinbox.mac/mail.sqlite"), "mailbox")
        XCTAssertEqual(text("Library/Application Support/app.paperinbox.mac/mail.sqlite-wal"), "mailbox log")
        XCTAssertEqual(defaults.domains["app.paperinbox.mac"]?["theme"] as? String, "dusk")
        XCTAssertEqual(defaults.domains["app.paperinbox.mac"]?[IdentityMigration.mailboxMovedKey] as? Bool, true)
    }

    /// Part of a mailbox in the new folder (its log, from two launches that raced before the lock) holds the launch too:
    /// the app would open an empty database over the old mailbox's log.
    func testAMailboxsLogAloneInTheNewFolderHoldsTheLaunch() throws {
        try write("mailbox", "Library/Application Support/SuperSparrow/mail.sqlite")
        try write("mailbox log", "Library/Application Support/app.paperinbox.mac/mail.sqlite-wal")
        XCTAssertEqual(migration().run(), .leftBehind(.mailboxInBothFolders))
        XCTAssertEqual(text("Library/Application Support/SuperSparrow/mail.sqlite"), "mailbox")
    }

    /// Once the mailbox has moved, one the old app starts later in its own folder stays there and holds nothing up.
    func testAMailboxTheOldAppStartsAfterTheMoveStaysAndHoldsNothingUp() throws {
        try makeLegacy()
        XCTAssertEqual(migration().run(), .ran)
        try write("fresh", "Library/Application Support/SuperSparrow/mail.sqlite")
        XCTAssertEqual(migration().run(), .ran)
        XCTAssertEqual(text("Library/Application Support/SuperSparrow/mail.sqlite"), "fresh")
        XCTAssertEqual(text("Library/Application Support/app.paperinbox.mac/mail.sqlite"), "mailbox")
    }

    /// The one rename of the old folder fails (another volume, a locked item): the launch opens nothing and changes
    /// nothing else of the old app's, and the next launch, with the rename working, moves everything.
    func testAFolderRenameThatFailsHoldsTheLaunchAndTheNextLaunchMovesIt() throws {
        try makeLegacy()
        let before = tree()
        let settings = defaults.domains
        var failing = IdentityMigration.FileOperations.system
        failing.move = { source, destination in
            if source.lastPathComponent == "SuperSparrow" { throw POSIXError(.EXDEV) }
            try IdentityMigration.FileOperations.system.move(source, destination)
        }
        XCTAssertEqual(migration(files: failing).run(), .leftBehind(.moveFailed))
        XCTAssertEqual(tree(), before, "no new folder, no caches moved, no leftovers removed")
        XCTAssertEqual(defaults.domains as NSDictionary, settings as NSDictionary)

        XCTAssertEqual(migration().run(), .ran)
        XCTAssertEqual(text("Library/Application Support/app.paperinbox.mac/mail.sqlite"), "mailbox")
        XCTAssertNil(defaults.domains["io.supersparrow.mac"])
    }

    /// A companion that fails to move takes its database back with it: the three stay together in the old folder, the
    /// new folder gets none of them, and the launch opens nothing.
    func testACompanionThatFailsToMoveTakesItsDatabaseBack() throws {
        try makeLegacy()
        try write("new demo", "Library/Application Support/app.paperinbox.mac/demo.sqlite")
        var failing = IdentityMigration.FileOperations.system
        failing.move = { source, destination in
            if source.lastPathComponent == "mail.sqlite-wal" { throw POSIXError(.EPERM) }
            try IdentityMigration.FileOperations.system.move(source, destination)
        }
        XCTAssertEqual(migration(files: failing).run(), .leftBehind(.moveFailed))
        for name in ["mail.sqlite", "mail.sqlite-wal", "mail.sqlite-shm"] {
            XCTAssertTrue(exists("Library/Application Support/SuperSparrow/" + name), name)
            XCTAssertFalse(exists("Library/Application Support/app.paperinbox.mac/" + name), name)
        }
        XCTAssertEqual(text("Library/Application Support/SuperSparrow/mail.sqlite"), "mailbox")

        XCTAssertEqual(migration().run(), .ran)
        XCTAssertEqual(text("Library/Application Support/app.paperinbox.mac/mail.sqlite-wal"), "mailbox log")
    }

    /// A companion gone since the plan (SQLite removes a log it has checkpointed) is not waited for: the database and
    /// the rest move on, since taking the database back would bring nothing back with it.
    func testACompanionGoneBeforeItsMoveDoesNotHoldItsDatabaseBack() throws {
        try makeLegacy()
        try write("new demo", "Library/Application Support/app.paperinbox.mac/demo.sqlite")
        var vanishing = IdentityMigration.FileOperations.system
        vanishing.move = { source, destination in
            if source.lastPathComponent == "mail.sqlite-wal" { try FileManager.default.removeItem(at: source) }
            try IdentityMigration.FileOperations.system.move(source, destination)
        }
        XCTAssertEqual(migration(files: vanishing).run(), .ran)
        XCTAssertEqual(text("Library/Application Support/app.paperinbox.mac/mail.sqlite"), "mailbox")
        XCTAssertEqual(text("Library/Application Support/app.paperinbox.mac/mail.sqlite-shm"), "mailbox index")
        XCTAssertFalse(exists("Library/Application Support/SuperSparrow/mail.sqlite"))
    }

    /// A move never replaces what is already there, a file or a folder, empty or not: it fails and changes neither side.
    func testAMoveNeverReplacesAnything() throws {
        try write("source", "a/file")
        try write("there", "b/file")
        try write("source", "a/folder/x")
        try write("there", "b/folder/y")
        try FileManager.default.createDirectory(at: root.appending(path: "b/empty"), withIntermediateDirectories: true)
        try write("source", "a/toEmpty")
        let before = tree()
        let move = IdentityMigration.FileOperations.system.move
        for (from, to) in [("a/file", "b/file"), ("a/folder", "b/folder"), ("a/toEmpty", "b/empty"), ("a/folder", "b/file")] {
            XCTAssertThrowsError(try move(root.appending(path: from), root.appending(path: to)), "\(from) -> \(to)") { error in
                XCTAssertEqual((error as? POSIXError)?.code, .EEXIST)
            }
        }
        XCTAssertEqual(tree(), before)
        try move(root.appending(path: "a/file"), root.appending(path: "b/new"))
        XCTAssertEqual(text("b/new"), "source")
        XCTAssertFalse(exists("a/file"))
    }

    /// Two copies of the app launched at once (`open -n`, or two copies of Paper.app): the second waits for the first's
    /// move of the old folder, then finds it done and moves nothing. Without the lock it would move the mailbox's log
    /// while the first moved the database, under it.
    func testASecondLaunchAtTheSameMomentWaitsForTheFirstsMove() throws {
        // Application Support alone: the two would otherwise race over the caches, harmlessly but not the point here.
        for (path, text) in [("SuperSparrow/mail.sqlite", "mailbox"), ("SuperSparrow/mail.sqlite-wal", "mailbox log"),
                             ("SuperSparrow/mail.sqlite-shm", "mailbox index"), ("SuperSparrow/demo.sqlite", "old demo"),
                             ("SuperSparrow/oauth-clients.json", "clients"), ("app.paperinbox.mac/demo.sqlite", "new demo")] {
            try write(text, "Library/Application Support/" + path)
        }
        let locations = locations!
        let second = Second()
        let system = IdentityMigration.FileOperations.system
        var first = system
        first.move = { source, destination in
            try system.move(source, destination)
            guard source.lastPathComponent == "mail.sqlite", !second.started else { return }
            second.started = true
            Thread.detachNewThread {
                var other = IdentityMigration(bundleIdentifier: "app.paperinbox.mac", locations: locations, defaults: FakeDefaults()) {
                    second.reachedTheMove.signal()
                    return false
                }
                other.files.move = { source, destination in
                    second.moves += 1
                    try system.move(source, destination)
                }
                second.outcome = other.run()
                second.done.signal()
            }
            // Long enough for the second to run its whole move if nothing held it back.
            second.reachedTheMove.wait()
            Thread.sleep(forTimeInterval: 0.3)
        }
        XCTAssertEqual(migration(files: first).run(), .ran)
        XCTAssertEqual(second.done.wait(timeout: .now() + 10), .success)
        XCTAssertEqual(second.outcome, .ran)
        XCTAssertEqual(second.moves, 0, "the second found the move done")
        for name in ["mail.sqlite", "mail.sqlite-wal", "mail.sqlite-shm"] {
            XCTAssertTrue(exists("Library/Application Support/app.paperinbox.mac/" + name), name)
            XCTAssertFalse(exists("Library/Application Support/SuperSparrow/" + name), name)
        }
        XCTAssertEqual(text("Library/Application Support/app.paperinbox.mac/mail.sqlite"), "mailbox")
        XCTAssertEqual(text("Library/Application Support/app.paperinbox.mac/mail.sqlite-wal"), "mailbox log")
    }

    private final class Second: @unchecked Sendable {
        var started = false
        var moves = 0
        var outcome: IdentityMigration.Outcome?
        let reachedTheMove = DispatchSemaphore(value: 0)
        let done = DispatchSemaphore(value: 0)
    }

    // MARK: Settings

    func testSettingsTheNewDomainHoldsWinAndTheOldDomainGoes() throws {
        defaults.domains["io.supersparrow.mac"] = ["theme": "dusk", "keepMail": 90]
        defaults.domains["app.paperinbox.mac"] = ["theme": "rain", "textSize": "large"]
        migration().run()
        let settings = try XCTUnwrap(defaults.domains["app.paperinbox.mac"])
        XCTAssertEqual(settings["theme"] as? String, "rain", "the new domain's own value wins")
        XCTAssertEqual(settings["textSize"] as? String, "large")
        XCTAssertEqual(settings["keepMail"] as? Int, 90)
        XCTAssertEqual(settings[IdentityMigration.migratedKey] as? Bool, true)
        XCTAssertNil(defaults.domains["io.supersparrow.mac"])

        // The old app run again writes its domain anew: the mark keeps it from being copied over the user's settings,
        // and the old domain goes again.
        defaults.domains["io.supersparrow.mac"] = ["theme": "study", "keepMail": 30, "late": true]
        migration().run()
        XCTAssertEqual(defaults.domains["app.paperinbox.mac"] as NSDictionary?, settings as NSDictionary)
        XCTAssertNil(defaults.domains["io.supersparrow.mac"])
    }

    /// The old bare binary's domain is a developer's, never the user's: the move leaves it alone.
    func testTheOldBareBinarysSettingsAreLeftAlone() {
        defaults.domains["SuperSparrow"] = ["theme": "grove"]
        migration().run()
        XCTAssertEqual(defaults.domains["SuperSparrow"]?["theme"] as? String, "grove")
        XCTAssertNil(defaults.domains["app.paperinbox.mac"])
    }

    // MARK: Caches and leftovers

    /// A queue the new crash reporter already keeps stays; the old bundle's caches go all the same.
    func testTheNewCrashQueueWinsAndTheOldCachesGo() throws {
        try write("old report", "Library/Caches/io.supersparrow.mac/Sentry/1.envelope")
        try write("new report", "Library/Caches/app.paperinbox.mac/Sentry/2.envelope")
        try write("old attachment", "Library/Caches/SuperSparrow/attachments/a")
        try write("new attachment", "Library/Caches/app.paperinbox.mac/attachments/b")
        try write("old demo attachment", "Library/Caches/SuperSparrow/demo-attachments/c")
        migration().run()
        XCTAssertFalse(exists("Library/Caches/io.supersparrow.mac"))
        XCTAssertEqual(text("Library/Caches/app.paperinbox.mac/Sentry/2.envelope"), "new report")
        XCTAssertFalse(exists("Library/Caches/app.paperinbox.mac/Sentry/1.envelope"))
        XCTAssertEqual(text("Library/Caches/app.paperinbox.mac/attachments/b"), "new attachment")
        XCTAssertEqual(text("Library/Caches/app.paperinbox.mac/demo-attachments/c"), "old demo attachment")
        XCTAssertEqual(text("Library/Caches/SuperSparrow/attachments/a"), "old attachment", "what both hold stays")
    }

    /// Of the old attachment caches' folder, only the attachment caches move: it was also the old bare binary's own
    /// caches folder, whose web caches are a developer's and never become the app's. The folder stays while they are in it.
    func testOnlyTheAttachmentCachesMove() throws {
        try write("attachment", "Library/Caches/SuperSparrow/attachments/a")
        try write("demo attachment", "Library/Caches/SuperSparrow/demo-attachments/b")
        try write("network", "Library/Caches/SuperSparrow/WebKit/NetworkCache/x")
        try write("hsts", "Library/Caches/SuperSparrow/WebKit/HSTS/y")
        try write("url cache", "Library/Caches/SuperSparrow/Cache.db")
        XCTAssertEqual(migration().run(), .ran)
        XCTAssertEqual(text("Library/Caches/app.paperinbox.mac/attachments/a"), "attachment")
        XCTAssertEqual(text("Library/Caches/app.paperinbox.mac/demo-attachments/b"), "demo attachment")
        XCTAssertFalse(exists("Library/Caches/app.paperinbox.mac/WebKit"))
        XCTAssertFalse(exists("Library/Caches/app.paperinbox.mac/Cache.db"))
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: legacyAttachmentCaches.path)), ["WebKit", "Cache.db"])
        XCTAssertEqual(text("Library/Caches/SuperSparrow/WebKit/NetworkCache/x"), "network")
    }

    /// Exactly the old app's four per-bundle leftovers, nothing beside them.
    func testOnlyTheListedLeftoversAreRemoved() throws {
        try makeLegacy()
        let kept = [
            "Library/WebKit/app.paperinbox.mac/x",
            "Library/WebKit/io.supersparrow.mac.other/x",
            "Library/HTTPStorages/com.example.app/x",
            "Library/HTTPStorages/app.paperinbox.mac.binarycookies",
            "Library/Saved Application State/com.example.app.savedState/x",
            "Library/Preferences/io.supersparrow.mac.plist",
            "Library/Containers/io.supersparrow.mac/x",
            "Library/Caches/SuperSparrow.other/x",
        ]
        for path in kept { try write("keep", path) }
        migration().run()
        for path in kept { XCTAssertEqual(text(path), "keep", path) }
        XCTAssertFalse(exists("Library/WebKit/io.supersparrow.mac"))
        XCTAssertFalse(exists("Library/HTTPStorages/io.supersparrow.mac"))
        XCTAssertFalse(exists("Library/HTTPStorages/io.supersparrow.mac.binarycookies"))
        XCTAssertFalse(exists("Library/Saved Application State/io.supersparrow.mac.savedState"))
    }

    // MARK: Cut off part-way

    /// A launch cut off after any number of changes (a crash, a forced quit) never loses a file, and the next launch
    /// finishes: the end state is the one an uninterrupted run reaches. Every change after the `n`th fails here, as if
    /// the process had stopped there.
    func testARunCutOffAnywhereIsFinishedByTheNextLaunch() throws {
        for variant in ["old only", "both"] {
            let reference = try finalState(variant: variant, cutOffAfter: nil)
            let changes = reference.changes
            XCTAssertGreaterThan(changes, 8, variant)
            for n in 0..<changes {
                let state = try finalState(variant: variant, cutOffAfter: n)
                XCTAssertEqual(state.tree, reference.tree, "\(variant), cut off after \(n)")
                XCTAssertEqual(state.settings as NSDictionary, reference.settings as NSDictionary, "\(variant), cut off after \(n)")
            }
        }
    }

    private struct FinalState {
        var tree: [String: String]
        var settings: [String: [String: Any]]
        var changes: Int
    }

    private func finalState(variant: String, cutOffAfter limit: Int?) throws -> FinalState {
        try? FileManager.default.removeItem(at: root)
        try setUpWithError()
        try makeLegacy()
        if variant == "both" {
            try write("new demo", "Library/Application Support/app.paperinbox.mac/demo.sqlite")
            try write("new report", "Library/Caches/app.paperinbox.mac/Sentry/2.envelope")
        }
        let dataFiles = tree().filter { $0.key.hasPrefix("Library/Application Support/") && $0.value != "/" }.map(\.value)
        let budget = ChangeBudget(limit: limit ?? .max)
        defaults.budget = budget
        migration(files: .budgeted(budget)).run()
        if limit != nil {
            // Cut off: every data file is still in one of the two folders.
            let now = tree().filter { $0.key.hasPrefix("Library/Application Support/") && $0.value != "/" }.map(\.value)
            XCTAssertEqual(now.sorted(), dataFiles.sorted(), "cut off after \(limit!)")
            defaults.budget = nil
            migration().run()
        }
        return FinalState(tree: tree(), settings: defaults.domains, changes: budget.spent)
    }
}

// MARK: - Stand-ins

/// The persistent domains as a dictionary: a test's own `UserDefaults` suite would still be written to
/// `~/Library/Preferences`.
private final class FakeDefaults: PersistentDefaultsDomains {
    var domains: [String: [String: Any]] = [:]
    private(set) var writes = 0
    var budget: ChangeBudget?

    func persistentDomain(forName domainName: String) -> [String: Any]? {
        domains[domainName]
    }

    func setPersistentDomain(_ domain: [String: Any], forName domainName: String) {
        guard budget?.spend() ?? true else { return }
        writes += 1
        domains[domainName] = domain
    }

    func removePersistentDomain(forName domainName: String) {
        guard budget?.spend() ?? true else { return }
        writes += 1
        domains[domainName] = nil
    }
}

/// How many changes a run may still make before it is "cut off": every later change fails, as if the process had
/// stopped.
private final class ChangeBudget: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private(set) var spent = 0

    init(limit: Int) {
        self.limit = limit
    }

    /// Whether one more change may happen.
    func spend() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard spent < limit else { return false }
        spent += 1
        return true
    }
}

private struct CutOff: Error {}

private extension IdentityMigration.FileOperations {
    static func budgeted(_ budget: ChangeBudget) -> Self {
        let system = Self.system
        return Self(
            move: { guard budget.spend() else { throw CutOff() }; try system.move($0, $1) },
            remove: { guard budget.spend() else { throw CutOff() }; try system.remove($0) },
            removeIfEmpty: { guard budget.spend() else { throw CutOff() }; return try system.removeIfEmpty($0) },
            makeDirectory: { guard budget.spend() else { throw CutOff() }; try system.makeDirectory($0) }
        )
    }
}
