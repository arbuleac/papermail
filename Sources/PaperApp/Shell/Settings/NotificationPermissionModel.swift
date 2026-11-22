import Foundation

/// Settings › General › Notifications' line about macOS (spec §5.40, §5.28): whether macOS lets Paper show new
/// mail and the Dock badge. Both are macOS's to allow, not the app's: with notifications off for Paper in System
/// Settings it shows neither, though the New mail toggle is on and the app sets the badge, and nothing in the app says
/// why. So General says so, with the one button that can change it. macOS keeps the answer: it is asked whenever the
/// row appears and the app comes to the front, since the user can change it in System Settings meanwhile.
@MainActor
final class NotificationPermissionModel: ObservableObject {
    /// What the line's button does.
    enum Action: Equatable {
        /// Puts macOS's prompt up: the user has not been asked.
        case ask
        /// Opens System Settings at Notifications: macOS asks only once, so only there can the answer change.
        case openSettings
    }

    /// The line under the toggle: glyph, words and button, and the caption under it.
    struct Line: Equatable {
        var words: String
        var buttonTitle: String
        var action: Action
        var caption: String?
    }

    static let deniedWords = "Off in System Settings"
    static let notAskedWords = "Not allowed yet"
    static let badgeOffWords = "Dock badge off in System Settings"
    static let openNotificationsTitle = "Open Notifications"
    static let allowTitle = "Allow…"
    /// The Dock badge is named: it is what goes missing without a word, while the toggle above still reads on.
    static let deniedCaption = "No notifications and no Dock badge until they're allowed there."

    /// macOS's answer; nil until the first, so no line flashes.
    @Published private(set) var permission: NotificationPermission?
    private let handler: NotificationPermissionHandling
    /// Bumped by every request, so an older answer arriving late never overwrites a newer one.
    private var generation = 0
    /// A snapshot set the answer; the row appearing must not ask over it.
    private var isPinnedForSnapshot = false
    /// macOS's prompt is up; the button does nothing until it is answered.
    private(set) var isAsking = false

    init(handler: NotificationPermissionHandling) {
        self.handler = handler
    }

    /// Nil while nothing stands in the way: allowed with the badge, not answered yet, or no notification center.
    var line: Line? {
        switch permission {
        case .denied?:
            return Line(words: Self.deniedWords, buttonTitle: Self.openNotificationsTitle, action: .openSettings, caption: Self.deniedCaption)
        case .notAsked?:
            return Line(words: Self.notAskedWords, buttonTitle: Self.allowTitle, action: .ask)
        case .allowedWithoutBadge?:
            return Line(words: Self.badgeOffWords, buttonTitle: Self.openNotificationsTitle, action: .openSettings)
        case .allowed?, .unavailable?, nil:
            return nil
        }
    }

    /// Asks macOS what it allows.
    func refresh() {
        guard !isPinnedForSnapshot, !isAsking else { return }
        generation += 1
        let asked = generation
        let handler = handler
        Task { [weak self] in
            let permission = await handler.permission()
            guard let self, self.generation == asked else { return }
            if self.permission != permission { self.permission = permission }
        }
    }

    /// The line's button.
    func act() {
        guard !isPinnedForSnapshot, let line else { return }
        switch line.action {
        case .openSettings:
            handler.openNotificationSettings()
        case .ask:
            guard !isAsking else { return }
            isAsking = true
            let handler = handler
            Task { [weak self] in
                await handler.request()
                guard let self else { return }
                self.isAsking = false
                self.refresh()
            }
        }
    }

    /// `--snapshot-settings-states` only: shows an answer without asking or opening anything.
    func showForSnapshot(_ permission: NotificationPermission?) {
        generation += 1
        isPinnedForSnapshot = true
        self.permission = permission
    }
}
