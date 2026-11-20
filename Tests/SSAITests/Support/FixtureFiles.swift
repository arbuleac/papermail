import Foundation
import XCTest

/// The recorded fixtures in `Fixtures/` (see its README), read from the test bundle with their exact bytes.
enum FixtureFiles {
    static var root: URL {
        Bundle.module.resourceURL!.appendingPathComponent("Fixtures", isDirectory: true)
    }

    /// The file at `path` relative to `Fixtures/`, e.g. "cli/claude-stream.jsonl".
    static func url(_ path: String) -> URL {
        root.appendingPathComponent(path)
    }

    static func data(_ path: String, file: StaticString = #filePath, line: UInt = #line) throws -> Data {
        do {
            return try Data(contentsOf: url(path))
        } catch {
            XCTFail("Missing fixture \(path)", file: file, line: line)
            throw error
        }
    }

    static func string(_ path: String, file: StaticString = #filePath, line: UInt = #line) throws -> String {
        String(decoding: try data(path, file: file, line: line), as: UTF8.self)
    }

    /// Every fixture file, relative paths, README excluded.
    static func all() -> [String] {
        let base = root.standardizedFileURL.path
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        return walker.compactMap { $0 as? URL }
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            .map { String($0.standardizedFileURL.path.dropFirst(base.count + 1)) }
            .filter { $0 != "README.md" }
            .sorted()
    }
}
