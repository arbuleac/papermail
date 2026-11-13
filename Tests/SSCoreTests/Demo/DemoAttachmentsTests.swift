import Foundation
import XCTest
@testable import SSCore

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
}
