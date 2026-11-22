import Darwin
import Foundation
import os

/// The first launch as Paper: brings over what the app kept on this Mac under its old name (`LegacyIdentity`), so the
/// user finds their settings, mailbox, OAuth clients, drafts and unsent crash reports where `AppIdentity` keeps them
/// (docs/ARCHITECTURE.md, "Identity"). The Keychain items move lazily, item by item, in `KeychainTokenStore` and
/// `AIKeyStore`.
///
/// It runs only in the bundled app (the new bundle identifier), never in the bare binary or a test: agents render with
/// the bare binary while the old app is open on the live data. And never while the old app runs, which would go on
/// writing where it always did; that launch defers to the next. Each step is idempotent and leaves, wherever it is cut
/// off, a state the next launch finishes: files only ever move by an exclusive rename on the same volume (never a copy,
/// never a replace), a folder is removed only once empty, and a data file is never deleted or opened.
///
/// The folders, the defaults and the running-app check are injected, so the tests run it on temporary folders and a
/// dictionary; only the app passes the user's own (`Locations.user`, `UserDefaults.standard`).
public struct IdentityMigration {
    /// The user's Library folders, or a test's temporary ones.
    public struct Locations: Equatable, Sendable {
        /// `~/Library/Application Support`.
        public var applicationSupport: URL
        /// `~/Library/Caches`.
        public var caches: URL
        /// `~/Library`, which holds the old app's per-bundle leftovers.
        public var library: URL

        public init(applicationSupport: URL, caches: URL, library: URL) {
            self.applicationSupport = applicationSupport
            self.caches = caches
            self.library = library
        }

        /// The user's own. Only the app's launch uses these; the tests pass temporary folders.
        public static var user: Locations {
            let fileManager = FileManager.default
            let library = fileManager.urls(for: .libraryDirectory, in: .userDomainMask).first
                ?? fileManager.homeDirectoryForCurrentUser.appending(path: "Library", directoryHint: .isDirectory)
            return Locations(
                applicationSupport: fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                    ?? library.appending(path: "Application Support", directoryHint: .isDirectory),
                caches: fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
                    ?? library.appending(path: "Caches", directoryHint: .isDirectory),
                library: library
            )
        }
    }

    public enum Outcome: Equatable, Sendable {
        /// Not the bundled app (the bare binary, a test): nothing was looked at.
        case notThisApp
        /// The old app is running: nothing moved, and the next launch tries again. `applicationSupportWaiting` when its
        /// folder in Application Support still holds something to move: the mailbox may be in it, and this launch must
        /// not start an empty one beside it.
        case deferred(applicationSupportWaiting: Bool)
        /// Every step ran; one with nothing left to do did nothing.
        case ran
    }

    /// Set in the new defaults domain once the old domain's settings were copied in, so a later launch never copies
    /// them over the user's changes again.
    public static let migratedKey = "identity.migrated"

    /// The names SQLite gives a database's companion files. A database moves with them as one, never one of them
    /// beside another database.
    static let databaseCompanionSuffixes = ["-wal", "-shm", "-journal"]

    private static let log = Logger(subsystem: AppIdentity.bundleIdentifier, category: "identity")

    private let bundleIdentifier: String?
    private let locations: Locations
    private let defaults: PersistentDefaultsDomains
    private let isLegacyAppRunning: () -> Bool
    /// The file operations that change anything; the tests stand in ones that stop part-way, as a crash would.
    var files: FileOperations = .system

    /// `bundleIdentifier` is the running bundle's (`Bundle.main.bundleIdentifier`): the move runs only when it is
    /// `AppIdentity.bundleIdentifier`. `isLegacyAppRunning` says whether an app with the old bundle identifier runs.
    public init(bundleIdentifier: String?, locations: Locations, defaults: PersistentDefaultsDomains,
                isLegacyAppRunning: @escaping () -> Bool) {
        self.bundleIdentifier = bundleIdentifier
        self.locations = locations
        self.defaults = defaults
        self.isLegacyAppRunning = isLegacyAppRunning
    }

    /// Whether a process with this bundle identifier is the one the move is for: the bundled app, never the bare
    /// binary (no bundle identifier) or a test runner.
    public static func applies(toBundleIdentifier identifier: String?) -> Bool {
        identifier == AppIdentity.bundleIdentifier
    }

    /// Whether this process is the bundled app. The Keychain stores read the old items only then.
    public static var appliesToThisProcess: Bool {
        applies(toBundleIdentifier: Bundle.main.bundleIdentifier)
    }

    /// Runs every step that has something to do, in order: the defaults, Application Support, the caches, the old
    /// app's leftovers.
    @discardableResult
    public func run() -> Outcome {
        guard Self.applies(toBundleIdentifier: bundleIdentifier) else { return .notThisApp }
        if isLegacyAppRunning() {
            let waiting = applicationSupportWaiting
            Self.log.info("the old app is running; its data moves on a launch without it (mailbox waiting: \(waiting, privacy: .public))")
            return .deferred(applicationSupportWaiting: waiting)
        }
        moveDefaults()
        moveApplicationSupport()
        moveCaches()
        removeLeftovers()
        return .ran
    }

    // MARK: Defaults

    /// Every key of the old domain the new one does not hold yet, and the mark, in one write; then the old domain goes.
    /// Cut off before the write, the next launch copies again; after it, the next launch only removes the old domain.
    func moveDefaults() {
        let legacyDomain = LegacyIdentity.defaultsDomain
        let newDomain = AppIdentity.bundleIdentifier
        guard let legacy = defaults.persistentDomain(forName: legacyDomain), !legacy.isEmpty else { return }
        let current = defaults.persistentDomain(forName: newDomain) ?? [:]
        if current[Self.migratedKey] == nil {
            var merged = current
            var copied = 0
            for (key, value) in legacy where merged[key] == nil {
                merged[key] = value
                copied += 1
            }
            merged[Self.migratedKey] = true
            defaults.setPersistentDomain(merged, forName: newDomain)
            Self.log.info("settings copied (\(copied, privacy: .public) of \(legacy.count, privacy: .public) keys)")
        }
        defaults.removePersistentDomain(forName: legacyDomain)
        Self.log.info("old settings removed")
    }

    // MARK: Application Support

    /// The mailbox (`mail.sqlite` with its companions), the demo's, the OAuth clients, the drafts and anything else the
    /// old folder holds.
    func moveApplicationSupport() {
        moveOrMerge(LegacyIdentity.applicationSupportDirectory(in: locations.applicationSupport),
                    into: AppIdentity.applicationSupportDirectory(in: locations.applicationSupport),
                    what: "application support")
    }

    /// Whether the old Application Support folder holds something the move would take: the old app is open on it, so
    /// this launch must not start a mailbox in the new folder.
    var applicationSupportWaiting: Bool {
        let legacy = LegacyIdentity.applicationSupportDirectory(in: locations.applicationSupport)
        let new = AppIdentity.applicationSupportDirectory(in: locations.applicationSupport)
        guard let legacyNames = try? Self.names(in: legacy), !legacyNames.isEmpty else { return false }
        guard Self.exists(new) else { return true }
        guard let newNames = try? Self.names(in: new) else { return true }
        return !Self.plan(legacy: legacyNames, new: Set(newNames)).moves.isEmpty
    }

    // MARK: Caches

    /// The crash reporter's queue, so reports not sent yet still go, then the old bundle's caches folder (what else is in
    /// it the system rebuilds); and the old attachment caches, so nothing is downloaded again.
    func moveCaches() {
        let legacyBundleCaches = LegacyIdentity.cachesDirectory(in: locations.caches)
        if Self.exists(legacyBundleCaches) {
            let legacySentry = LegacyIdentity.sentryCacheDirectory(in: locations.caches)
            let newSentry = AppIdentity.sentryCacheDirectory(in: locations.caches)
            do {
                if Self.exists(legacySentry), !Self.exists(newSentry) {
                    try files.makeDirectory(AppIdentity.cachesDirectory(in: locations.caches))
                    try files.move(legacySentry, newSentry)
                    Self.log.info("crash reports' queue moved")
                }
                // Removed only once the queue is safe: a failed move leaves both for the next launch.
                try files.remove(legacyBundleCaches)
                Self.log.info("old caches removed")
            } catch {
                Self.log.error("old caches not moved (\(Self.describe(error), privacy: .public))")
            }
        }
        moveOrMerge(LegacyIdentity.attachmentCachesDirectory(in: locations.caches),
                    into: AppIdentity.cachesDirectory(in: locations.caches),
                    what: "attachment caches")
    }

    // MARK: Leftovers

    /// The old app's per-bundle state, no user data: exactly `LegacyIdentity.leftovers(inLibrary:)`, nothing broader.
    func removeLeftovers() {
        var removed = 0
        for url in LegacyIdentity.leftovers(inLibrary: locations.library) where Self.exists(url) {
            do {
                try files.remove(url)
                removed += 1
            } catch {
                Self.log.error("an old leftover not removed (\(Self.describe(error), privacy: .public))")
            }
        }
        if removed > 0 { Self.log.info("\(removed, privacy: .public) old leftovers removed") }
    }

    // MARK: Moving a folder

    /// `legacy` becomes `new` when `new` does not exist: one rename, atomic. When both exist, each item `new` lacks moves
    /// into it, a database with its companions as one; what both hold stays in `legacy`, which goes only once empty.
    private func moveOrMerge(_ legacy: URL, into new: URL, what: String) {
        guard Self.exists(legacy) else { return }
        guard Self.exists(new) else {
            do {
                try files.move(legacy, new)
                Self.log.info("\(what, privacy: .public) moved")
            } catch {
                Self.log.error("\(what, privacy: .public) not moved (\(Self.describe(error), privacy: .public))")
            }
            return
        }
        let plan: Plan
        do {
            plan = Self.plan(legacy: try Self.names(in: legacy), new: Set(try Self.names(in: new)))
        } catch {
            Self.log.error("\(what, privacy: .public) not read (\(Self.describe(error), privacy: .public))")
            return
        }
        var moved = 0
        for unit in plan.moves where move(unit, from: legacy, to: new) { moved += unit.count }
        do {
            if try files.removeIfEmpty(legacy) {
                Self.log.info("\(what, privacy: .public) merged (\(moved, privacy: .public) moved), old folder removed")
            } else {
                Self.log.info("\(what, privacy: .public) merged (\(moved, privacy: .public) moved), old folder kept for \(plan.kept, privacy: .public) the new one already had")
            }
        } catch {
            Self.log.error("old \(what, privacy: .public) folder not removed (\(Self.describe(error), privacy: .public))")
        }
    }

    /// Moves one unit in order, the database first. A companion that fails takes the files moved before it back, so a
    /// database never opens without its write-ahead log.
    private func move(_ unit: [String], from legacy: URL, to new: URL) -> Bool {
        var done: [String] = []
        for name in unit {
            do {
                try files.move(legacy.appending(path: name), new.appending(path: name))
                done.append(name)
            } catch {
                Self.log.error("an item not moved (\(Self.describe(error), privacy: .public))")
                for name in done.reversed() {
                    try? files.move(new.appending(path: name), legacy.appending(path: name))
                }
                return false
            }
        }
        return true
    }

    /// What a merge moves, unit by unit, and how many of the old folder's items stay because the new one has its own.
    struct Plan: Equatable {
        var moves: [[String]]
        var kept: Int
    }

    /// A database (`x`) and its companions (`x-wal`, `x-shm`, `x-journal`) are one unit: it moves only when the new folder
    /// has none of them, the database first. A companion whose database is no longer here moves to the new folder's
    /// database when that has none of its own: a move cut off between them. Any other item moves when the new folder
    /// lacks its name.
    static func plan(legacy: [String], new: Set<String>) -> Plan {
        let present = Set(legacy)
        var units: [String: [String]] = [:]
        for name in legacy { units[base(of: name), default: []].append(name) }
        var plan = Plan(moves: [], kept: 0)
        for base in units.keys.sorted() {
            let members = units[base] ?? []
            let companions = databaseCompanionSuffixes.map { base + $0 }.filter(present.contains)
            if present.contains(base) {
                let names = [base] + databaseCompanionSuffixes.map { base + $0 }
                if names.contains(where: new.contains) {
                    plan.kept += members.count
                } else {
                    plan.moves.append([base] + companions)
                }
            } else if new.contains(base) {
                let missing = companions.filter { !new.contains($0) }
                for companion in missing { plan.moves.append([companion]) }
                plan.kept += members.count - missing.count
            } else {
                // Companions with no database on either side belong to none: never beside one made later.
                plan.kept += members.count
            }
        }
        return plan
    }

    /// The database a companion belongs to, or the name itself.
    static func base(of name: String) -> String {
        for suffix in databaseCompanionSuffixes where name.hasSuffix(suffix) && name.count > suffix.count {
            return String(name.dropLast(suffix.count))
        }
        return name
    }

    // MARK: Support

    /// Whether anything is at `url`, a symbolic link included (never followed).
    static func exists(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
    }

    /// Every name in a folder, hidden ones included.
    static func names(in folder: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path)
    }

    /// An error's domain and code: never its description, which names the file and so the user.
    static func describe(_ error: Error) -> String {
        let error = error as NSError
        return "\(error.domain) \(error.code)"
    }
}

extension IdentityMigration {
    /// The file system calls that change anything. Each either does all it says or nothing.
    struct FileOperations: Sendable {
        /// Renames `source` to `destination`, failing when something is already there: never a replace, and never a copy
        /// (a rename across volumes fails instead).
        var move: @Sendable (_ source: URL, _ destination: URL) throws -> Void
        /// Deletes an item and what it holds: only the old app's caches and per-bundle leftovers.
        var remove: @Sendable (URL) throws -> Void
        /// Deletes a folder only when it is empty; false when it still holds something.
        var removeIfEmpty: @Sendable (URL) throws -> Bool
        /// Makes a folder and its parents, when missing.
        var makeDirectory: @Sendable (URL) throws -> Void

        static let system = FileOperations(
            move: { source, destination in
                guard renamex_np(source.path, destination.path, UInt32(RENAME_EXCL)) == 0 else { throw Self.posixError() }
            },
            remove: { try FileManager.default.removeItem(at: $0) },
            removeIfEmpty: { folder in
                if rmdir(folder.path) == 0 { return true }
                let code = errno
                if code == ENOTEMPTY || code == EEXIST { return false }
                throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
            },
            makeDirectory: { try FileManager.default.createDirectory(at: $0, withIntermediateDirectories: true) }
        )

        private static func posixError() -> POSIXError {
            POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}
