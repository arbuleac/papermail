// Measures which Unicode scalars the system serif (New York) draws itself and prints them as the range table
// that Sources/PaperCore/Render/NewYorkCoverage.swift embeds. PaperCore cannot import AppKit, and New York is a
// system font reachable only by design (not by name), so the table is measured here once and checked in.
//
// Usage: swift scripts/tools/newyork-coverage.swift > ranges.txt
// Then replace the `ranges` literal in NewYorkCoverage.swift with the output, including its first comment line.
import AppKit
import CoreText

let base = NSFont.systemFont(ofSize: 15, weight: .regular)
guard let descriptor = base.fontDescriptor.withDesign(.serif),
      let serif = NSFont(descriptor: descriptor, size: 15) else {
    FileHandle.standardError.write("The system serif design is not available on this Mac.\n".data(using: .utf8)!)
    exit(1)
}
let characterSet = CTFontCopyCharacterSet(serif as CTFont) as CharacterSet

var ranges: [(low: UInt32, high: UInt32)] = []
for value in UInt32(0)...0x10FFFF {
    guard let scalar = Unicode.Scalar(value), characterSet.contains(scalar) else { continue }
    if let last = ranges.last, last.high + 1 == value {
        ranges[ranges.count - 1].high = value
    } else {
        ranges.append((value, value))
    }
}

let version = ProcessInfo.processInfo.operatingSystemVersionString
let total = ranges.reduce(0) { $0 + Int($1.high - $1.low + 1) }
print("// \(serif.fontName), macOS \(version): \(total) scalars in \(ranges.count) ranges.")
var line = "   "
for range in ranges {
    let item = String(format: " 0x%04X, 0x%04X,", range.low, range.high)
    if line.count + item.count > 116 {
        print(line)
        line = "   "
    }
    line += item
}
if line.count > 3 { print(line) }
