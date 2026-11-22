import Foundation

/// What a progress bar or a contrail shows (spec §5.37).
public enum QuireProgressMode: Equatable, Sendable {
    /// A known fraction, 0…1: the length is the progress. It jumps, never eases.
    case determinate(Double)
    /// Unknown progress: a segment sweeps across every `dur.contrailSweep` (a static segment under Reduce
    /// Motion; the text beside it carries the state).
    case indeterminate
    /// Time running out (the undo-send countdown, a toast's life): the length drains linearly from
    /// `remaining / duration` to nothing over `remaining` seconds, or steps once per second under Reduce
    /// Motion, next to the seconds shown as text.
    case countdown(duration: TimeInterval, remaining: TimeInterval)

    /// A countdown starting now with its whole duration ahead.
    public static func countdown(_ duration: TimeInterval) -> QuireProgressMode {
        .countdown(duration: duration, remaining: duration)
    }
}
