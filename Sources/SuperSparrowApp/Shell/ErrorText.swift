import Foundation
import SSCore

/// Errors in plain words (spec §4.13: what happened and what happens next, never blaming the user). Alerts,
/// banners and Settings statuses take their reasons from here; logs keep the technical descriptions.
enum ErrorText {
    static func company(_ kind: ProviderKind) -> String {
        kind == .gmail ? "Google" : "Microsoft"
    }

    /// The service an account syncs with, as the sync line and Settings name it.
    static func service(_ kind: ProviderKind) -> String {
        kind == .gmail ? "Gmail" : "Microsoft"
    }

    /// Why a sign-in (adding or reconnecting) failed.
    static func signIn(_ error: Error, kind: ProviderKind) -> String {
        let company = company(kind)
        switch error {
        case AuthError.userCancelled, ProviderError.cancelled:
            return "The browser sign-in was cancelled."
        case AuthError.tokenExchangeFailed:
            return "\(company) refused the sign-in. Check the client ID in Settings › OAuth."
        case AuthError.invalidResponse:
            return "\(company) sent a sign-in response SuperSparrow didn't expect. Try again in a moment."
        case AuthError.refreshFailed:
            return "The sign-in expired and couldn't be renewed."
        case AuthError.keychain:
            return "The Keychain didn't let SuperSparrow store the sign-in."
        case AuthError.missingClientConfiguration:
            return "Add your \(company) OAuth client in Settings › OAuth first."
        case ProviderError.unauthorized:
            return "\(company) didn't allow access to the mailbox. Allow mail access when you sign in."
        case ProviderError.network, is URLError:
            return "Couldn't reach \(company). Check your internet connection."
        case ProviderError.throttled:
            return "\(company) is limiting requests. Try again in a minute."
        case ProviderError.server(let status, _):
            return "\(company) returned an error (\(status)). Try again in a moment."
        case ProviderError.decoding:
            return "\(company) returned an unexpected response."
        default:
            return "Something went wrong while signing in."
        }
    }

    /// Why the OAuth settings file could not be read, for the Settings › OAuth danger banner.
    static func oauthFile(_ error: Error) -> String {
        if case AuthError.invalidResponse = error { return "The file isn't valid JSON." }
        // JSONSerialization reports malformed text as Cocoa's “corrupt data” read error.
        if let cocoa = error as? CocoaError, cocoa.code == .propertyListReadCorrupt { return "The file isn't valid JSON." }
        return "The file couldn't be read."
    }

    /// A sync failure recorded in `AccountSyncStatus.message` (`SyncErrorDescription` prefixes), for the
    /// Settings status tooltip and the account detail's Last error.
    static func sync(_ message: String?, kind: ProviderKind) -> String {
        let service = service(kind)
        let text = message ?? ""
        if text.hasPrefix("network") { return "Couldn't reach \(service)." }
        if text.hasPrefix("throttled") || text.hasPrefix("Rate limited") { return "\(service) is limiting requests." }
        if text.hasPrefix("decoding") { return "\(service) returned an unexpected response." }
        if text.hasPrefix("server") {
            let status = text.dropFirst("server ".count).prefix { $0.isNumber }
            return status.isEmpty ? "\(service) returned an error." : "\(service) returned an error (\(status))."
        }
        if text.hasPrefix("not found") { return "\(service) couldn't find something SuperSparrow expected." }
        return "Something went wrong while syncing with \(service)."
    }

    /// True for a sync failure that is the network's, not the account's.
    static func isNetwork(_ message: String?) -> Bool {
        (message ?? "").hasPrefix("network")
    }
}
