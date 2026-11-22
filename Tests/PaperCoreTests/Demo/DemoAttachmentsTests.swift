import Foundation
import XCTest
@testable import PaperCore

/// The demo carries a message with two files of its own, so the reader shows its count line and Download all
/// (spec §5.17, §5.43), and the demo provider serves both.
final class DemoAttachmentsTests: XCTestCase {
    func testTheGoLiveChecklistCarriesTwoFilesTheProviderServes() throws {
        let account = AccountID("demo-outlook")
        let now = Date()
        let mailbox = DemoMailbox(profile: .outlook, accountID: account, reference: now, liveInterval: 3_600, now: { now })
        var builder = DemoMailboxBuilder(profile: .outlook, accountID: account, reference: now)
        let records = builder.build()
        let record = try XCTUnwrap(records.first { $0.metadata.subject == "Contoso rollout: go-live checklist" })
        XCTAssertTrue(record.metadata.hasAttachments)
        let files = record.body.attachments.filter { !$0.isInline }
        XCTAssertEqual(files.map(\.filename), ["go-live-checklist.pdf", "training-schedule.csv"])
        XCTAssertEqual(files.map(\.id), [DemoMailboxBuilder.checklistAttachmentID, DemoMailboxBuilder.trainingAttachmentID])

        let pdf = try XCTUnwrap(mailbox.attachment(messageID: record.metadata.id.providerID, attachmentID: files[0].id))
        XCTAssertEqual(pdf.count, files[0].sizeBytes)
        XCTAssertEqual(String(decoding: pdf.prefix(8), as: UTF8.self), "%PDF-1.4")
        XCTAssertTrue(String(decoding: pdf, as: UTF8.self).hasSuffix("%%EOF\n"))
        let csv = try XCTUnwrap(mailbox.attachment(messageID: record.metadata.id.providerID, attachmentID: files[1].id))
        XCTAssertEqual(csv.count, files[1].sizeBytes)
        XCTAssertTrue(String(decoding: csv, as: UTF8.self).hasPrefix("Store,Session,Date,Trainer\n"))
        XCTAssertNil(mailbox.attachment(messageID: "not-a-message", attachmentID: files[0].id), "only the message that carries it")
    }

    /// The hand-off pack (spec §5.57): the last message of a thread in the work inbox carries a file of every common
    /// family, each served as the bytes its listing says, each the kind of file its name says.
    func testTheHandoffPackCarriesAFileOfEveryCommonFamily() throws {
        let account = AccountID("demo-outlook")
        let now = Date()
        let mailbox = DemoMailbox(profile: .outlook, accountID: account, reference: now, liveInterval: 3_600, now: { now })
        var builder = DemoMailboxBuilder(profile: .outlook, accountID: account, reference: now)
        let records = builder.build()
        let thread = records.filter { $0.metadata.subject.hasSuffix(DemoComposerSample.handoffSubject) }
        XCTAssertEqual(thread.count, 2)
        let pack = try XCTUnwrap(thread.max { $0.metadata.date < $1.metadata.date })
        XCTAssertTrue(pack.metadata.roles.contains(.inbox))
        let files = pack.body.attachments
        XCTAssertEqual(files.count, 12)
        XCTAssertTrue(files.allSatisfy { !$0.isInline })
        let families = Set(files.map { FileMark(filename: $0.filename, mimeType: $0.mimeType).family })
        XCTAssertEqual(families, [.pdf, .spreadsheet, .document, .presentation, .archive, .image, .design, .mail, .text, .audio])
        XCTAssertEqual(Set(files.map { FileMark(filename: $0.filename, mimeType: $0.mimeType).label }).isSuperset(of: ["PDF", "XLS", "CSV", "TXT", "ZIP", "RAR"]), true)
        let signatures: [String: [UInt8]] = ["pdf": Array("%PDF".utf8), "xlsx": [0x50, 0x4B, 0x03, 0x04], "docx": [0x50, 0x4B, 0x03, 0x04],
                                             "pptx": [0x50, 0x4B, 0x03, 0x04], "zip": [0x50, 0x4B, 0x03, 0x04], "rar": Array("Rar!".utf8),
                                             "png": [0x89, 0x50, 0x4E, 0x47], "wav": Array("RIFF".utf8)]
        for file in files {
            let data = try XCTUnwrap(mailbox.attachment(messageID: pack.metadata.id.providerID, attachmentID: file.id), file.filename)
            XCTAssertEqual(data.count, file.sizeBytes, file.filename)
            if let signature = signatures[(file.filename as NSString).pathExtension] {
                XCTAssertEqual(Array(data.prefix(signature.count)), signature, file.filename)
            }
        }
        // The empty RAR archive's two headers carry their CRCs: an archiver reads it.
        let rar = try XCTUnwrap(files.first { $0.filename.hasSuffix(".rar") })
        let bytes = Array(try XCTUnwrap(mailbox.attachment(messageID: pack.metadata.id.providerID, attachmentID: rar.id)))
        XCTAssertEqual(bytes.count, 7 + 13 + 7)
        XCTAssertEqual(UInt16(bytes[7]) | UInt16(bytes[8]) << 8, UInt16(DemoAssets.crc32(Data(bytes[9..<20])) & 0xFFFF))
    }
}
