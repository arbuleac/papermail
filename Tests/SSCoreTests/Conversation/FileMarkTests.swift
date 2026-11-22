import Foundation
import XCTest
@testable import SSCore

/// Spec §5.57: one mapping from a file's name and MIME type to its mark's family, label and the meta line's kind, for
/// every surface that shows a file.
final class FileMarkTests: XCTestCase {
    private func mark(_ name: String, _ mime: String = "application/octet-stream") -> FileMark {
        FileMark(filename: name, mimeType: mime)
    }

    private func assertMark(_ name: String, _ family: FileFamily, _ label: String, _ kind: String,
                            mime: String = "application/octet-stream", file: StaticString = #filePath, line: UInt = #line) {
        let m = mark(name, mime)
        XCTAssertEqual(m.family, family, name, file: file, line: line)
        XCTAssertEqual(m.label, label, name, file: file, line: line)
        XCTAssertEqual(m.kind, kind, name, file: file, line: line)
    }

    func testEveryFamilyFromItsExtensions() {
        assertMark("plan.pdf", .pdf, "PDF", "PDF")
        assertMark("contract.docx", .document, "DOC", "Word")
        assertMark("letter.pages", .document, "PAGE", "Pages")
        assertMark("notes.rtf", .document, "RTF", "Rich Text")
        assertMark("minutes.odt", .document, "ODT", "OpenDocument")
        assertMark("Q4-forecast.xlsx", .spreadsheet, "XLS", "Excel")
        assertMark("budget.numbers", .spreadsheet, "NUM", "Numbers")
        assertMark("attendees.csv", .spreadsheet, "CSV", "CSV")
        assertMark("export.tsv", .spreadsheet, "TSV", "TSV")
        assertMark("kickoff.pptx", .presentation, "PPT", "PowerPoint")
        assertMark("keynote.key", .presentation, "KEY", "Keynote")
        assertMark("press-kit.zip", .archive, "ZIP", "Archive")
        assertMark("legacy-exports.rar", .archive, "RAR", "Archive")
        assertMark("bundle.7z", .archive, "7Z", "Archive")
        assertMark("SuperSparrow.dmg", .archive, "DMG", "Disk Image")
        assertMark("tools.pkg", .archive, "PKG", "Installer")
        assertMark("setup.exe", .archive, "EXE", "App")
        assertMark("app-release.apk", .archive, "APK", "App")
        assertMark("hero.png", .image, "PNG", "PNG")
        assertMark("IMG_2041.HEIC", .image, "HEIC", "HEIC")
        assertMark("scan.jpeg", .image, "JPG", "JPEG")
        assertMark("walkthrough.mov", .video, "MOV", "QuickTime")
        assertMark("demo.mp4", .video, "MP4", "Video")
        assertMark("clip.webm", .video, "WEBM", "Video")
        assertMark("voice-memo.m4a", .audio, "M4A", "Audio")
        assertMark("song.mp3", .audio, "MP3", "Audio")
        assertMark("take.wav", .audio, "WAV", "Audio")
        assertMark("release-notes.txt", .text, "TXT", "Text")
        assertMark("README.md", .text, "MD", "Text")
        assertMark("site-config.json", .text, "JSON", "JSON")
        assertMark("index.htm", .text, "HTML", "HTML")
        assertMark("server.log", .text, "LOG", "Text")
        assertMark("main.swift", .text, "SWFT", "Code")
        assertMark("launch-plan.ics", .mail, "ICS", "Calendar")
        assertMark("Ben Carter.vcf", .mail, "VCF", "Contact")
        assertMark("forwarded.eml", .mail, "EML", "Message")
        assertMark("logo.svg", .design, "SVG", "SVG")
        assertMark("hero.psd", .design, "PSD", "Photoshop")
        assertMark("brand.ai", .design, "AI", "Illustrator")
        assertMark("flows.fig", .design, "FIG", "Figma")
        assertMark("screens.sketch", .design, "SKT", "Sketch")
        assertMark("readings.dat", .other, "DAT", "DAT")
    }

    func testLetterCaseNeverMatters() {
        for name in ["PLAN.PDF", "Plan.Pdf", "plan.pdf", "plan.pDF"] {
            XCTAssertEqual(mark(name), mark("plan.pdf"), name)
        }
        XCTAssertEqual(mark("data.XLSX").label, "XLS")
        XCTAssertEqual(mark("x.bin", "Application/PDF").family, .pdf, "MIME types are compared without case")
    }

    func testTheLastExtensionDecidesButATarballKeepsItsTar() {
        assertMark("report.pdf.zip", .archive, "ZIP", "Archive")
        assertMark("photo.jpg.exe", .archive, "EXE", "App")
        assertMark("site.tar.gz", .archive, "TGZ", "Archive")
        assertMark("Site.TAR.BZ2", .archive, "TBZ", "Archive")
        assertMark("site.tar.xz", .archive, "TXZ", "Archive")
        assertMark("site.tar.zst", .archive, "TZST", "Archive")
        assertMark("site.tgz", .archive, "TGZ", "Archive")
        assertMark("notes.tar", .archive, "TAR", "Archive")
        assertMark("readme.txt.gz", .archive, "GZ", "Archive")
    }

    func testANumberedPartTakesTheExtensionBeforeIt() {
        assertMark("backup.zip.001", .archive, "ZIP", "Archive")
        assertMark("footage.7z.002", .archive, "7Z", "Archive")
        assertMark("release v1.2", .other, "", "File")
        assertMark("draft.2", .other, "", "File")
    }

    func testMIMETypeWhenTheNameHasNoKnownType() {
        assertMark("Invoice", .pdf, "PDF", "PDF", mime: "application/pdf")
        assertMark("image", .image, "JPG", "JPEG", mime: "image/jpeg; name=image")
        assertMark("invite", .mail, "ICS", "Calendar", mime: "text/calendar; method=REQUEST")
        assertMark("message", .mail, "EML", "Message", mime: "message/rfc822")
        assertMark("sheet", .spreadsheet, "XLS", "Excel", mime: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet")
        assertMark("archive", .archive, "RAR", "Archive", mime: "application/x-rar-compressed")
        assertMark("report.final", .pdf, "PDF", "PDF", mime: "application/pdf")
        // A top-level type the table does not list still picks the family; a short plain subtype becomes the label.
        assertMark("picture", .image, "AVIF", "Image", mime: "image/avif")
        assertMark("picture", .image, "", "Image", mime: "image/x-portable-anymap")
        assertMark("film", .video, "", "Video", mime: "video/x-flv")
        assertMark("sound", .audio, "", "Audio", mime: "audio/x-unknown-thing")
        assertMark("notes", .text, "", "Text", mime: "text/x-unknown")
        // A known extension wins over what the provider guessed.
        assertMark("plan.pdf", .pdf, "PDF", "PDF", mime: "image/png")
    }

    func testUnknownTypesAndNoType() {
        assertMark("weights.bin", .other, "BIN", "BIN")
        assertMark("movie.torrent", .other, "TORR", "TORRENT")
        assertMark("archive.abcdefgh", .other, "ABCD", "ABCDEFGH")
        assertMark("archive.abcdefghi", .other, "", "File")
        assertMark("Notes. Final draft", .other, "", "File")
        assertMark("Makefile", .other, "", "File")
        assertMark("", .other, "", "File", mime: "")
        assertMark("file.", .other, "", "File")
        assertMark(".bashrc", .other, "", "File")
        assertMark(".hidden.pdf", .pdf, "PDF", "PDF", mime: "")
        assertMark("café.naïve", .other, "", "File", mime: "")
    }

    func testEveryLabelFitsTheBand() {
        for (ext, m) in FileMark.byExtension {
            XCTAssertFalse(m.label.isEmpty, ext)
            XCTAssertLessThanOrEqual(m.label.count, FileMark.maxLabel, ext)
            XCTAssertTrue(m.label.allSatisfy { $0.isASCII && ($0.isUppercase || $0.isNumber) }, ext)
            XCTAssertFalse(m.kind.isEmpty, ext)
        }
        for m in FileMark.byMIME.values { XCTAssertLessThanOrEqual(m.label.count, FileMark.maxLabel) }
        XCTAssertLessThanOrEqual(mark("x.abcdefgh").label.count, FileMark.maxLabel)
    }

    /// The families are the file inks of the tokens (`filePalette`), by name in lower case, in the same order, so the
    /// reader's `--q-file-<family>` and `Quire.FileInk` exist for every family.
    func testFamiliesAreTheTokensFileInks() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/design/tokens.json")
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let palette = try XCTUnwrap(root["filePalette"] as? [[String: Any]])
        XCTAssertEqual(palette.compactMap { ($0["name"] as? String)?.lowercased() }, FileFamily.allCases.map(\.rawValue))
        let layout = try XCTUnwrap((root["layout"] as? [String: Any])?["fileMark"] as? [String: Any])
        XCTAssertEqual(layout["labelMax"] as? Int, FileMark.maxLabel)
    }
}
