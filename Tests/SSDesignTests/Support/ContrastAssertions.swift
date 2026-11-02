import XCTest
@testable import SSDesign

extension XCTestCase {
    /// Asserts one contrast pair in all four modes: ≥ `need`, or ≥ `needIC` in the Increase Contrast modes when
    /// the pair has one. The 1e-9 slack is build.py's, so a pair that passes there passes here.
    func assertContrast(_ use: String, fg: [String], bg: [String], need: Double, needIC: Double? = nil,
                        file: StaticString = #filePath, line: UInt = #line) {
        for mode in QuireMode.allCases {
            let required = (mode.isIncreasedContrast ? needIC : nil) ?? need
            let ratio = TokenResolver.ratio(fg: fg, bg: bg, mode)
            XCTAssertGreaterThanOrEqual(ratio, required - 1e-9,
                                        "\(use) [\(mode.rawValue)]: \(fg.joined(separator: " + ")) on \(bg.joined(separator: " + ")) is \(String(format: "%.2f", ratio)), needs \(required)",
                                        file: file, line: line)
        }
    }
}
