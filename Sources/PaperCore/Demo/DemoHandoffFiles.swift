import Foundation

/// The demo's spread of file types (spec §5.57, §5.43): a brand hand-off pack of twelve files across the file families,
/// on one message, so the reader shows a chip of every common kind side by side and Forward carries them all to the
/// composer's strip. Every file is real and small, written here: text as text, the PDF and the picture as the demo's
/// others are made, the Word file and the spreadsheet as the smallest packages Word and Excel open, the zip as a stored
/// archive and the rar as an empty RAR archive, the voice memo half a second of a quiet tone. The deck is a package Quick Look shows by its
/// icon.
enum DemoHandoffFiles {
    struct File {
        let id: String
        let filename: String
        let mimeType: String
        let data: Data
    }

    static let files: [File] = [
        File(id: "att-handoff-guidelines", filename: "brand-guidelines.pdf", mimeType: "application/pdf", data: DemoAssets.makePDF([
            ("Northwind brand guidelines", 720, 20),
            ("The refresh, in one page", 690, 14),
            ("Logo: the wordmark alone, never on a photograph", 650, 11),
            ("Colour: ink, paper and one accent", 632, 11),
            ("Type: New York for headlines, SF Pro for everything else", 614, 11),
        ])),
        File(id: "att-handoff-budget", filename: "Q4-budget.xlsx",
             mimeType: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", data: spreadsheet),
        File(id: "att-handoff-attendees", filename: "launch-attendees.csv", mimeType: "text/csv", data: Data("""
            Name,Team,Session
            Rachel Kim,Leadership,Keynote
            Marcus Bell,Design,Brand walkthrough
            Aisha Rahman,Engineering,Demo
            Tom Hughes,Support,Q&A

            """.utf8)),
        File(id: "att-handoff-contract", filename: "agency-contract.docx",
             mimeType: "application/vnd.openxmlformats-officedocument.wordprocessingml.document", data: document),
        File(id: "att-handoff-deck", filename: "launch-deck.pptx",
             mimeType: "application/vnd.openxmlformats-officedocument.presentationml.presentation", data: zip([
                ("[Content_Types].xml", "<?xml version=\"1.0\" encoding=\"UTF-8\"?><Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"/>"),
             ])),
        File(id: "att-handoff-press", filename: "press-kit.zip", mimeType: "application/zip", data: zip([
            ("press-kit/README.txt", "Northwind press kit: the logo, the boilerplate and two photographs.\n"),
            ("press-kit/boilerplate.txt", "Northwind Labs builds tools for teams who write a lot of mail.\n"),
        ])),
        File(id: "att-handoff-exports", filename: "agency-exports.rar", mimeType: "application/vnd.rar", data: emptyRAR),
        File(id: "att-handoff-hero", filename: "hero-shot.png", mimeType: "image/png", data: DemoAssets.makeSunsetPNG(width: 240, height: 150)),
        File(id: "att-handoff-logo", filename: "logo.svg", mimeType: "image/svg+xml", data: Data("""
            <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64"><rect width="64" height="64" rx="12" fill="#1E5468"/>\
            <path d="M14 44 L32 16 L50 44 Z" fill="#FFFFFF"/></svg>

            """.utf8)),
        File(id: "att-handoff-review", filename: "launch-review.ics", mimeType: "text/calendar", data: Data("""
            BEGIN:VCALENDAR\r
            VERSION:2.0\r
            PRODID:-//Paper Demo//EN\r
            BEGIN:VEVENT\r
            UID:handoff-review@northwind-labs.test\r
            DTSTAMP:20261101T090000Z\r
            DTSTART:20261128T140000Z\r
            DTEND:20261128T150000Z\r
            SUMMARY:Brand refresh: launch review\r
            END:VEVENT\r
            END:VCALENDAR\r

            """.utf8)),
        File(id: "att-handoff-notes", filename: "release-notes.txt", mimeType: "text/plain", data: Data("""
            Brand refresh, release notes
            - New wordmark and app icon
            - Paper and ink palette for the site
            - Press kit updated

            """.utf8)),
        File(id: "att-handoff-memo", filename: "voice-memo.wav", mimeType: "audio/wav", data: tone),
    ]

    static func data(for attachmentID: String) -> Data? {
        files.first { $0.id == attachmentID }?.data
    }

    static var attachments: [AttachmentInfo] {
        files.map { AttachmentInfo(id: $0.id, filename: $0.filename, mimeType: $0.mimeType, sizeBytes: $0.data.count, isInline: false) }
    }

    // MARK: Packages

    /// The smallest workbook Excel and Numbers open: one sheet of inline strings and numbers.
    static let spreadsheet: Data = zip([
        ("[Content_Types].xml", """
            <?xml version="1.0" encoding="UTF-8"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
            <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
            <Default Extension="xml" ContentType="application/xml"/>\
            <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>\
            <Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>\
            </Types>
            """),
        ("_rels/.rels", """
            <?xml version="1.0" encoding="UTF-8"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
            <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>\
            </Relationships>
            """),
        ("xl/workbook.xml", """
            <?xml version="1.0" encoding="UTF-8"?><workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" \
            xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets>\
            <sheet name="Q4" sheetId="1" r:id="rId1"/></sheets></workbook>
            """),
        ("xl/_rels/workbook.xml.rels", """
            <?xml version="1.0" encoding="UTF-8"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
            <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>\
            </Relationships>
            """),
        ("xl/worksheets/sheet1.xml", """
            <?xml version="1.0" encoding="UTF-8"?><worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>\
            <row r="1"><c r="A1" t="inlineStr"><is><t>Item</t></is></c><c r="B1" t="inlineStr"><is><t>Budget</t></is></c></row>\
            <row r="2"><c r="A2" t="inlineStr"><is><t>Agency</t></is></c><c r="B2"><v>24000</v></c></row>\
            <row r="3"><c r="A3" t="inlineStr"><is><t>Photography</t></is></c><c r="B3"><v>6500</v></c></row>\
            <row r="4"><c r="A4" t="inlineStr"><is><t>Print</t></is></c><c r="B4"><v>3200</v></c></row>\
            </sheetData></worksheet>
            """),
    ])

    /// The smallest document Word and Pages open: one paragraph.
    static let document: Data = zip([
        ("[Content_Types].xml", """
            <?xml version="1.0" encoding="UTF-8"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
            <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
            <Default Extension="xml" ContentType="application/xml"/>\
            <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>\
            </Types>
            """),
        ("_rels/.rels", """
            <?xml version="1.0" encoding="UTF-8"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
            <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>\
            </Relationships>
            """),
        ("word/document.xml", """
            <?xml version="1.0" encoding="UTF-8"?><w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">\
            <w:body><w:p><w:r><w:t>Agency agreement: the brand refresh, draft for review.</w:t></w:r></w:p></w:body></w:document>
            """),
    ])

    /// Half a second of a quiet 440 Hz tone: 16-bit mono PCM at 8 kHz in a WAVE file.
    static let tone: Data = {
        let rate = 8_000
        let samples = (0..<(rate / 2)).map { Int16(1_200 * sin(Double($0) * 2 * .pi * 440 / Double(rate))) }
        var out = Data("RIFF".utf8)
        out.appendLE(UInt32(36 + samples.count * 2))
        out.append(Data("WAVEfmt ".utf8))
        out.appendLE(UInt32(16)); out.appendLE(UInt16(1)); out.appendLE(UInt16(1))
        out.appendLE(UInt32(rate)); out.appendLE(UInt32(rate * 2)); out.appendLE(UInt16(2)); out.appendLE(UInt16(16))
        out.append(Data("data".utf8))
        out.appendLE(UInt32(samples.count * 2))
        for sample in samples { out.appendLE(UInt16(bitPattern: sample)) }
        return out
    }()

    /// A zip of stored (uncompressed) entries, as every unzip reads.
    static func zip(_ entries: [(name: String, text: String)]) -> Data {
        var out = Data()
        var directory = Data()
        for entry in entries {
            let name = Data(entry.name.utf8)
            let body = Data(entry.text.utf8)
            let crc = DemoAssets.crc32(body)
            let offset = UInt32(out.count)
            out.appendLE(UInt32(0x0403_4B50))
            out.appendLE(UInt16(20)); out.appendLE(UInt16(0)); out.appendLE(UInt16(0))
            out.appendLE(UInt16(0)); out.appendLE(UInt16(0x21)) // 00:00, 1 Jan 1980
            out.appendLE(crc); out.appendLE(UInt32(body.count)); out.appendLE(UInt32(body.count))
            out.appendLE(UInt16(name.count)); out.appendLE(UInt16(0))
            out.append(name)
            out.append(body)
            directory.appendLE(UInt32(0x0201_4B50))
            directory.appendLE(UInt16(20)); directory.appendLE(UInt16(20)); directory.appendLE(UInt16(0)); directory.appendLE(UInt16(0))
            directory.appendLE(UInt16(0)); directory.appendLE(UInt16(0x21))
            directory.appendLE(crc); directory.appendLE(UInt32(body.count)); directory.appendLE(UInt32(body.count))
            directory.appendLE(UInt16(name.count)); directory.appendLE(UInt16(0)); directory.appendLE(UInt16(0))
            directory.appendLE(UInt16(0)); directory.appendLE(UInt16(0)); directory.appendLE(UInt32(0)); directory.appendLE(offset)
            directory.append(name)
        }
        let start = UInt32(out.count)
        out.append(directory)
        out.appendLE(UInt32(0x0605_4B50))
        out.appendLE(UInt16(0)); out.appendLE(UInt16(0))
        out.appendLE(UInt16(entries.count)); out.appendLE(UInt16(entries.count))
        out.appendLE(UInt32(directory.count)); out.appendLE(start); out.appendLE(UInt16(0))
        return out
    }

    /// An empty RAR 1.5 archive: the marker, the archive header and the end of archive, each header's CRC the low half of
    /// the CRC-32 of its bytes after the CRC field.
    static let emptyRAR: Data = {
        var out = Data([0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x00])
        func block(_ body: Data) {
            out.appendLE(UInt16(DemoAssets.crc32(body) & 0xFFFF))
            out.append(body)
        }
        var main = Data([0x73])
        main.appendLE(UInt16(0)); main.appendLE(UInt16(13)); main.appendLE(UInt16(0)); main.appendLE(UInt32(0))
        block(main)
        var end = Data([0x7B])
        end.appendLE(UInt16(0x4000)); end.appendLE(UInt16(7))
        block(end)
        return out
    }()
}

private extension Data {
    mutating func appendLE(_ value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8(value >> 8))
    }

    mutating func appendLE(_ value: UInt32) {
        appendLE(UInt16(value & 0xFFFF))
        appendLE(UInt16(value >> 16))
    }
}
