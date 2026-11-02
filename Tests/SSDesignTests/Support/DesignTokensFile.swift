import Foundation

/// docs/design/tokens.json, read straight from the repository so tests can compare the generated runtime with
/// its source. Located from this file's path, which is stable inside the package.
final class DesignTokensFile {
    static let shared = DesignTokensFile()

    let url: URL
    let root: [String: Any]

    private init() {
        url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Support
            .deletingLastPathComponent() // SSDesignTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repository
            .appendingPathComponent("docs/design/tokens.json")
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            preconditionFailure("cannot read \(url.path)")
        }
        root = object
    }

    func object(_ key: String) -> [String: Any] { root[key] as? [String: Any] ?? [:] }

    func array(_ key: String) -> [Any] { root[key] as? [Any] ?? [] }

    func pairCount(_ key: String) -> Int { array(key).count }

    /// The value at a dotted path such as `layout.row.height`.
    func value(_ path: String) -> Any? {
        var cur: Any? = root
        for part in path.split(separator: ".") {
            cur = (cur as? [String: Any])?[String(part)]
        }
        return cur
    }

    func number(_ path: String) -> Double? { (value(path) as? NSNumber)?.doubleValue }

    /// How many leaves (numbers, strings, booleans and arrays) the objects under `keys` hold.
    func leafCount(under keys: [String]) -> Int {
        func count(_ v: Any) -> Int {
            if let d = v as? [String: Any] { return d.values.reduce(0) { $0 + count($1) } }
            return 1
        }
        return keys.reduce(0) { $0 + count(object($1)) }
    }

    /// Every numeric metric under `layout` whose key contains "adius" (build.py's test), as dotted paths.
    func layoutRadiusPaths() -> [String] {
        var out: [String] = []
        func walk(_ prefix: String, _ v: Any) {
            if let d = v as? [String: Any] {
                for (k, vv) in d { walk(prefix.isEmpty ? k : prefix + "." + k, vv) }
            } else if let last = prefix.split(separator: ".").last, last.contains("adius"), v is NSNumber || v is [Any] {
                out.append(prefix)
            }
        }
        walk("", object("layout"))
        return out.sorted()
    }
}
