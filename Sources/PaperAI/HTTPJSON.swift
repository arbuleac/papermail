import Foundation

/// Loose reading of the APIs' JSON: their events and error documents carry many fields this build ignores and gains
/// new ones without notice, so they are read as dictionaries, field by field, rather than decoded into types that
/// would fail on a shape change.
enum HTTPJSON {
    static func object(_ data: Data) -> [String: Any]? {
        guard !data.isEmpty else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func object(_ text: String) -> [String: Any]? {
        object(Data(text.utf8))
    }

    /// A whole number, whether JSON gave it as an integer or a float; nil for booleans, which `NSNumber` also carries.
    static func int(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        guard double.isFinite, double >= Double(Int.min), double <= Double(Int.max) else { return nil }
        return number.intValue
    }

    /// A string field, or a number written as one (an error `code` is usually a string, now and then a number).
    static func string(_ value: Any?) -> String? {
        if let string = value as? String { return string }
        if let number = int(value) { return String(number) }
        return nil
    }

    static func dictionary(_ value: Any?) -> [String: Any]? {
        value as? [String: Any]
    }
}
