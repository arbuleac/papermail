import Foundation

/// Graph speaks ISO 8601 in UTC. Some resources add seven fractional digits, more than Foundation's parser takes.
enum GraphDate {
    private static let plain = Date.ISO8601FormatStyle()
    private static let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    static func parse(_ string: String) -> Date? {
        if let date = try? plain.parse(string) { return date }
        if let date = try? fractional.parse(string) { return date }
        guard let dot = string.firstIndex(of: "."),
              let zone = string[dot...].firstIndex(where: { $0 == "Z" || $0 == "+" || $0 == "-" }) else {
            return nil
        }
        let digits = String(string[string.index(after: dot)..<zone].prefix(3))
        let padded = digits.padding(toLength: 3, withPad: "0", startingAt: 0)
        return try? fractional.parse(String(string[..<dot]) + "." + padded + String(string[zone...]))
    }

    /// Second precision, which is what `$filter=receivedDateTime ge` accepts.
    static func string(_ date: Date) -> String {
        plain.format(date)
    }
}
