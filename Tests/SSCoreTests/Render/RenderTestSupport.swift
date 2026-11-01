import Foundation
import XCTest
@testable import SSCore

/// Shared identifiers and assertion helpers for the Render tests. Every fixture is sanitized for the same
/// message so expected `ss-cid` URLs can be computed once.
enum RenderTestSupport {
    static let accountID = AccountID("acct-1")
    static let messageID = MessageID(accountID: accountID, providerID: "msg-1")
    static let date = Date(timeIntervalSince1970: 1_761_555_240)
    static let locale = Locale(identifier: "en_US")

    static func sanitize(_ html: String, allowRemoteImages: Bool = false) -> SanitizedBody {
        HTMLSanitizer(allowRemoteImages: allowRemoteImages)
            .sanitize(MessageBody(html: html, text: nil), messageID: messageID)
    }

    static func sanitizeText(_ text: String) -> SanitizedBody {
        HTMLSanitizer().sanitize(MessageBody(html: nil, text: text), messageID: messageID)
    }

    static func inlineImageURL(_ contentID: String) -> String {
        RenderURLScheme.inlineImageURL(for: messageID, contentID: contentID).absoluteString
    }
}

func assertContains(_ haystack: String, _ needle: String, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertTrue(haystack.contains(needle), "expected to find \(needle) in:\n\(haystack)", file: file, line: line)
}

func assertNotContains(_ haystack: String, _ needle: String, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertFalse(haystack.contains(needle), "expected not to find \(needle) in:\n\(haystack)", file: file, line: line)
}

func assertNotContainsIgnoringCase(_ haystack: String, _ needle: String, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertNil(haystack.range(of: needle, options: .caseInsensitive), "expected not to find \(needle) in:\n\(haystack)", file: file, line: line)
}

/// Both strings must be present and `first` must start before `second`.
func assertOrdered(_ text: String, _ first: String, before second: String, file: StaticString = #filePath, line: UInt = #line) {
    guard let a = text.range(of: first), let b = text.range(of: second) else {
        XCTFail("expected both \(first) and \(second) in:\n\(text)", file: file, line: line)
        return
    }
    XCTAssertLessThan(a.lowerBound, b.lowerBound, "expected \(first) before \(second) in:\n\(text)", file: file, line: line)
}
