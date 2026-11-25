import Foundation

/// What an answer given from an event's details answers: a single event, one occurrence of a repeating one (This Event),
/// or its whole series (All Events).
public enum AnswerSpan: String, Codable, Sendable, CaseIterable {
    case single
    case occurrence
    case series
}
