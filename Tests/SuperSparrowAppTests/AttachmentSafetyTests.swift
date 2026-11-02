import Foundation
import XCTest
@testable import SuperSparrowApp

/// Attachment files carry the quarantine mark an email client sets, and programs ask before they open (§5.17).
final class AttachmentSafetyTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("AttachmentSafetyTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    func testAWrittenAttachmentIsQuarantinedAsAnEmailAttachment() throws {
        let url = folder.appendingPathComponent("Invoice.command")
        try AttachmentSafety.write(Data("#!/bin/sh\necho hi\n".utf8), to: url)
        let properties = try XCTUnwrap(try url.resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties)
        XCTAssertEqual(properties[kLSQuarantineTypeKey as String] as? String, kLSQuarantineTypeEmailAttachment as String)
        XCTAssertEqual(properties[kLSQuarantineAgentNameKey as String] as? String, "SuperSparrow")
        XCTAssertNotNil(Self.xattr("com.apple.quarantine", of: url), "the attribute Gatekeeper reads is on disk")
    }

    /// Save to Downloads and Save As copy the preview file; the copy must keep the mark.
    func testACopyKeepsTheQuarantine() throws {
        let url = folder.appendingPathComponent("plan.pdf")
        try AttachmentSafety.write(Data("%PDF-1.4".utf8), to: url)
        let copy = folder.appendingPathComponent("plan 2.pdf")
        try FileManager.default.copyItem(at: url, to: copy)
        XCTAssertTrue(AttachmentSafety.isQuarantined(copy))
    }

    func testProgramsAndScriptsAreRecognised() {
        for name in ["Invoice.command", "run.sh", "Setup.app", "tool.jar", "Install.pkg", "x.terminal", "a.scpt", "go.py", "Open.fileloc"] {
            XCTAssertTrue(AttachmentSafety.runsCode(URL(fileURLWithPath: "/tmp/" + name)), name)
        }
        for name in ["plan.pdf", "photo.jpg", "notes.txt", "sheet.xlsx", "photos.zip", "README"] {
            XCTAssertFalse(AttachmentSafety.runsCode(URL(fileURLWithPath: "/tmp/" + name)), name)
        }
    }

    private static func xattr(_ name: String, of url: URL) -> Data? {
        let length = getxattr(url.path, name, nil, 0, 0, 0)
        guard length > 0 else { return nil }
        var data = Data(count: length)
        let read = data.withUnsafeMutableBytes { getxattr(url.path, name, $0.baseAddress, length, 0, 0) }
        return read == length ? data : nil
    }
}
