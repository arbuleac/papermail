import Foundation
import SSCore

/// The send action every Send button shows and ⌘↩ performs (spec §5.23), read and changed in one place and kept in the
/// settings (`AppSettings.sendAction`). The main window points it at the settings it was given: the app's own, so its
/// composers and the quick reply share the user's choice, or a test's throwaway domain. With none it reads the default
/// and changes nothing.
@MainActor
enum SendActionPreference {
    /// Posted after the choice changes, so open composers and the quick reply re-read it at once.
    static let didChange = Notification.Name("SendActionPreferenceDidChange")

    /// Weak: the app's settings live as long as the app, and a test's go with its window.
    static weak var settings: AppSettings?

    static var current: SendAction { settings?.sendAction ?? .default }

    /// Makes `action` the default for every Send button (the drop-down's choice). It never sends.
    static func choose(_ action: SendAction) {
        settings?.sendAction = action
    }
}
