import Foundation
import ServiceManagement

/// What macOS says about SuperSparrow as a login item, in our own words so the model and its tests never import
/// ServiceManagement.
enum LoginItemStatus: Equatable, Sendable {
    case enabled
    case notRegistered
    /// Registered, but the user has to allow it in System Settings › General › Login Items & Extensions first, or
    /// turned it off there after it was added.
    case requiresApproval
    /// macOS cannot find this copy of the app as a service, as for a build run outside an app bundle.
    case notFound
}

/// SuperSparrow as a login item. Settings › General asks and changes it only through this, so the app's tests, which
/// pass a fake, never read or change the Mac's real login items.
@MainActor
protocol LoginItemHandling {
    func status() async -> LoginItemStatus
    /// Asks macOS to open SuperSparrow at login. macOS may hold it for the user's approval.
    func register() async throws
    func unregister() async throws
    /// System Settings at Login Items & Extensions, where the user approves or removes it.
    func openLoginItemsSettings()
}

/// The app bundle itself through `SMAppService.mainApp`: no helper app and no launch agent to ship.
struct MainAppLoginItem: LoginItemHandling {
    /// Off the main thread: each call is a round trip to the system's background task daemon.
    func status() async -> LoginItemStatus {
        await Task.detached(priority: .userInitiated) {
            LoginItemStatus(SMAppService.mainApp.status)
        }.value
    }

    func register() async throws {
        try await Task.detached(priority: .userInitiated) {
            try SMAppService.mainApp.register()
        }.value
    }

    func unregister() async throws {
        try await Task.detached(priority: .userInitiated) {
            try await SMAppService.mainApp.unregister()
        }.value
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

/// The snapshots' answer: not a login item, and nothing is ever asked of or changed in macOS, so a render depends on
/// nothing but the build.
struct SnapshotLoginItem: LoginItemHandling {
    func status() async -> LoginItemStatus { .notRegistered }
    func register() async throws { throw CocoaError(.featureUnsupported) }
    func unregister() async throws { throw CocoaError(.featureUnsupported) }
    func openLoginItemsSettings() {}
}

private extension LoginItemStatus {
    init(_ status: SMAppService.Status) {
        switch status {
        case .enabled: self = .enabled
        case .notRegistered: self = .notRegistered
        case .requiresApproval: self = .requiresApproval
        case .notFound: self = .notFound
        @unknown default: self = .notFound
        }
    }
}
