import Foundation

/// The moments of a write `AIWriter` reports to the app, which leaves them as crash-report breadcrumbs (PaperCore cannot
/// reach CrashReporting). Names from the code only: never a prompt, a model's words or a CLI's output.
public enum AIWriteMilestone: Sendable, Hashable, CaseIterable {
    case started
    case finished
    case failed
    case stopped

    public var breadcrumbName: StaticString {
        switch self {
        case .started: return "write started"
        case .finished: return "write finished"
        case .failed: return "write failed"
        case .stopped: return "write stopped"
        }
    }
}
