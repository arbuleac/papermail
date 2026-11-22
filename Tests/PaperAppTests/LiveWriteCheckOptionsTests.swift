@testable import PaperApp
import XCTest

/// The debug launch options of the live Help Me Write check: parsed in debug builds, and the check runs only in the demo.
final class LiveWriteCheckOptionsTests: XCTestCase {
    func testTheLiveCheckImpliesTheDemoAndCarriesItsProviderAndModel() {
        let options = LaunchOptions(arguments: ["Paper", "--live-ai-clis", "--ai-provider=claudeCode", "--ai-model=haiku",
                                                "--live-write-check=/tmp/report.json"])
        XCTAssertTrue(options.demo)
        XCTAssertTrue(options.liveAICLIs)
        XCTAssertEqual(options.aiProvider, "claudeCode")
        XCTAssertEqual(options.aiModel, "haiku")
        XCTAssertEqual(options.liveWriteCheckPath, "/tmp/report.json")
    }

    func testWithoutThemNothingIsChosenAndNoCheckRuns() {
        let options = LaunchOptions(arguments: ["Paper", "--ai-provider=", "--live-write-check="])
        XCTAssertNil(options.aiProvider)
        XCTAssertNil(options.aiModel)
        XCTAssertNil(options.liveWriteCheckPath)
        XCTAssertFalse(options.demo)
    }
}
