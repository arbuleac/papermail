import Foundation
import PaperCore
import os

/// Settings › General › At login (spec §5.40, roadmap Q2.7): whether Paper opens when the user logs in, so new
/// mail notifies from then on. macOS keeps the answer, not our defaults: it comes from `LoginItemHandling`, asked again
/// whenever the row appears and the app comes to the front, since the user can approve or remove the item in System
/// Settings meanwhile.
@MainActor
final class LaunchAtLoginModel: ObservableObject {
    enum State: Equatable {
        /// Not answered yet: the row shows no toggle rather than one that may flip.
        case unknown
        /// Not a login item, or a copy macOS has not met yet: a press registers it either way.
        case off
        case on
        /// Asked for, and waiting for the user in System Settings (or turned off there since).
        case needsApproval
        /// macOS cannot open this copy at login: it runs outside an app bundle, or macOS still could not find it after
        /// a register. The toggle stays off and disabled.
        case unavailable
    }

    /// A change the user asked for.
    enum Change: Equatable {
        case turnOn
        case turnOff
    }

    /// What the rows show.
    struct Row: Equatable {
        /// The toggle's position; nil hides it until the first answer.
        var isOn: Bool?
        var isToggleEnabled = true
        /// The approval line under the toggle: the words and Open Login Items.
        var needsApproval = false
        /// In `ink3` under the row: why the toggle is disabled.
        var caption: String?
        /// In `danger` under the row (§5.25's help line), never an alert.
        var failure: String?
    }

    static let toggleTitle = "Open Paper"
    /// The toggle's words leave the moment to the row's label; VoiceOver reads the toggle on its own.
    static let accessibilityLabel = "Open Paper at login"
    static let approvalWords = "Needs approval in System Settings"
    static let openLoginItemsTitle = "Open Login Items"
    static let unavailableWords = "Not available for this copy of Paper. Move it to the Applications folder and open it from there."
    static let turnOnFailureWords = "Couldn't set Paper to open at login. You can add it in System Settings › General › Login Items & Extensions."
    static let turnOffFailureWords = "Couldn't stop Paper opening at login. You can remove it in System Settings › General › Login Items & Extensions."

    private static let log = Logger(subsystem: AppIdentity.bundleIdentifier, category: "shell")

    @Published private(set) var state: State = .unknown
    /// The change macOS is making now; the toggle shows where it is going and ignores presses until macOS answers.
    @Published private(set) var pending: Change?
    /// A change that did not take: its words stay until macOS is found where the user asked, through a retry too.
    @Published private(set) var failed: Change?
    private let handler: LoginItemHandling
    /// Bumped by every request, so an older answer arriving late never overwrites a newer one.
    private var generation = 0
    /// A snapshot set the state; the row appearing must not ask over it.
    private var isPinnedForSnapshot = false
    /// macOS still answered not found after a register, so not found now means it cannot open this copy at login,
    /// until it answers anything else.
    private var registerFoundNothing = false

    init(handler: LoginItemHandling) {
        self.handler = handler
    }

    var row: Row {
        switch state {
        case .unknown:
            return Row()
        case .unavailable:
            return Row(isOn: false, isToggleEnabled: false, caption: Self.unavailableWords)
        case .off, .on, .needsApproval:
            let isOn = pending.map { $0 == .turnOn } ?? (state != .off)
            // One line under the toggle at a time, so General stays short enough never to scroll: a turn-off that
            // failed while macOS waits for approval names Login Items itself.
            return Row(isOn: isOn, needsApproval: state == .needsApproval && failed == nil, failure: failed.map(Self.failureWords))
        }
    }

    /// Asks macOS where Paper stands. Never while a change is under way, whose own answer follows it.
    func refresh() {
        guard pending == nil, !isPinnedForSnapshot else { return }
        generation += 1
        let asked = generation
        let handler = handler
        Task { [weak self] in
            let status = await handler.status()
            guard let self, self.generation == asked else { return }
            self.settle(on: self.read(status))
        }
    }

    /// The toggle: asks macOS once, then shows what macOS answers afterwards, which wins over any error on the way.
    func setOn(_ isOn: Bool) {
        guard pending == nil, !isPinnedForSnapshot, state != .unknown, state != .unavailable else { return }
        let change: Change = isOn ? .turnOn : .turnOff
        guard !Self.state(state, satisfies: change) else { return }
        generation += 1
        let asked = generation
        pending = change
        let handler = handler
        Task { [weak self] in
            var failure: Error?
            do {
                if isOn { try await handler.register() } else { try await handler.unregister() }
            } catch {
                failure = error
            }
            let status = await handler.status()
            guard let self, self.generation == asked else { return }
            self.pending = nil
            let state = self.read(status, afterRegister: isOn)
            if !Self.state(state, satisfies: change), state != .unavailable {
                let error = failure.map { $0 as NSError }
                Self.log.error("login item not changed: \(error?.domain ?? "no error", privacy: .public) \(error?.code ?? 0, privacy: .public)")
                self.failed = change
            } else if Self.state(state, satisfies: change) {
                Analytics.send(.settingChanged(.launchAtLogin(isOn)))
            }
            self.settle(on: state)
        }
    }

    /// Opens System Settings at Login Items & Extensions, where the user approves the item.
    func openLoginItems() {
        guard !isPinnedForSnapshot else { return }
        handler.openLoginItemsSettings()
    }

    /// `--snapshot-settings-states` only: shows a state without asking or changing anything.
    func showForSnapshot(_ state: State, failed: Change? = nil) {
        generation += 1
        isPinnedForSnapshot = true
        pending = nil
        self.failed = failed
        self.state = state
    }

    /// What macOS's answer shows. Not found reads as off, so the toggle can register a copy macOS has not met yet; only
    /// a register that leaves it not found makes it unavailable, and that holds until macOS answers anything else.
    private func read(_ status: LoginItemStatus, afterRegister: Bool = false) -> State {
        switch status {
        case .enabled:
            registerFoundNothing = false
            return .on
        case .notRegistered:
            registerFoundNothing = false
            return .off
        case .requiresApproval:
            registerFoundNothing = false
            return .needsApproval
        case .notFound:
            if afterRegister { registerFoundNothing = true }
            return registerFoundNothing ? .unavailable : .off
        case .noAppBundle:
            return .unavailable
        }
    }

    /// The answer replaces the state; a failure's words go once macOS stands where the user asked, or once the row
    /// says the toggle cannot be used at all.
    private func settle(on state: State) {
        if let failed, Self.state(state, satisfies: failed) || state == .unavailable { self.failed = nil }
        self.state = state
    }

    /// An item waiting for approval is on as far as this Mac's user asked; approving it is System Settings' part.
    private static func state(_ state: State, satisfies change: Change) -> Bool {
        switch change {
        case .turnOn: return state == .on || state == .needsApproval
        case .turnOff: return state == .off
        }
    }

    private static func failureWords(_ change: Change) -> String {
        change == .turnOn ? turnOnFailureWords : turnOffFailureWords
    }
}
