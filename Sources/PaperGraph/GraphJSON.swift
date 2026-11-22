import Foundation
import PaperCore

/// Coding front door that turns every Codable failure into `ProviderError.decoding`, so the engine never sees
/// Foundation's own error types.
enum GraphJSON {
    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw ProviderError.decoding("\(T.self): \(error)")
        }
    }

    static func decode<T: Decodable>(_ type: T.Type, from value: GraphJSONValue) throws -> T {
        try decode(T.self, from: try encode(value))
    }

    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do {
            return try encoder.encode(value)
        } catch {
            throw ProviderError.decoding("encoding \(T.self): \(error)")
        }
    }
}
