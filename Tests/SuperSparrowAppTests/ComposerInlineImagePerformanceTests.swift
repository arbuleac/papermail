import AppKit
import ImageIO
import SSCore
import XCTest
@testable import SuperSparrowApp

/// The composer's picture budgets in docs/ARCHITECTURE.md (spec §5.20, Images in the body). On the main thread a
/// picture costs only its header and its line: a 12-megapixel photo pasted as a JPEG, or as a TIFF that is encoded
/// again as a PNG, is in the text, as a skeleton of its size, within 16 ms, and ten 12-megapixel photos dropped together
/// within 50 ms. Off it, the JPEG is ready (its copy for the screen decoded) within 100 ms and the TIFF within 1.5 s.
/// Making the pictures takes a while in a debug build, so it only runs with `SS_PERF=1`:
///
///     SS_PERF=1 swift test -c release --filter ComposerInlineImagePerformanceTests
@MainActor
final class ComposerInlineImagePerformanceTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        guard ProcessInfo.processInfo.environment["SS_PERF"] == "1" else {
            throw XCTSkip("set SS_PERF=1 to run the picture benchmark")
        }
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("ComposerPicturePerf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let folder { try? FileManager.default.removeItem(at: folder) }
        super.tearDown()
    }

    func testAPastedPhotoIsInTheTextWithinBudget() throws {
        let photo = Self.photo(width: 4000, height: 3000)
        let jpeg = try XCTUnwrap(photo.representation(using: .jpeg, properties: [.compressionFactor: 0.85]))
        let tiff = try XCTUnwrap(photo.tiffRepresentation)
        let editor = ComposeTextView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))

        var pictures: [ComposeImageAttachment] = []
        func paste(_ data: Data, as type: String) throws {
            let picture = try XCTUnwrap(ComposeImageAttachment.make(data: data, typeIdentifier: type, filename: nil))
            editor.insertPictures([picture])
            editor.layoutManager?.ensureLayout(for: try XCTUnwrap(editor.textContainer))
            pictures.append(picture)
        }
        // Each phase starts with the queue empty: pictures are prepared one at a time, so one still queued would be
        // counted in the next picture's time.
        let keptInText = try median(of: 5) { try paste(jpeg, as: "public.jpeg") }
        pictures.forEach { $0.finishNow() }
        let keptReady = try median(of: 5) {
            try paste(jpeg, as: "public.jpeg")
            pictures.last?.finishNow()
        }
        let encodedInText = try median(of: 3) { try paste(tiff, as: "public.tiff") }
        pictures.forEach { $0.finishNow() }
        let encodedReady = try median(of: 3) {
            try paste(tiff, as: "public.tiff")
            pictures.last?.finishNow()
        }
        pictures.forEach { $0.finishNow() }
        XCTAssertTrue(pictures.allSatisfy(\.isReady))
        print("picture budget: 12 MP JPEG in the text \(Self.ms(keptInText)), ready \(Self.ms(keptReady)) (\(jpeg.count / 1024) KB);"
              + " 12 MP TIFF to PNG in the text \(Self.ms(encodedInText)), ready \(Self.ms(encodedReady))")
        XCTAssertLessThan(keptInText, 0.016, "a JPEG is in the text within 16 ms")
        XCTAssertLessThan(encodedInText, 0.016, "a TIFF too: it is encoded off the main thread")
        XCTAssertLessThan(keptReady, 0.1, "a JPEG is ready within 100 ms")
        XCTAssertLessThan(encodedReady, 1.5, "a TIFF, encoded as a PNG first, within 1.5 s")
    }

    func testTenPhotosDroppedTogetherAreInTheTextWithinBudget() throws {
        let photo = Self.photo(width: 4000, height: 3000)
        // HEIC where this Mac writes it (an iPhone's photos), else TIFF: both are encoded again as they are prepared.
        let heic = Self.encode(photo, as: "public.heic")
        let data = try heic ?? XCTUnwrap(photo.tiffRepresentation)
        let urls = try (1...10).map { index -> URL in
            let url = folder.appendingPathComponent("IMG_\(index).\(heic == nil ? "tiff" : "heic")")
            try data.write(to: url)
            return url
        }
        let editor = ComposeTextView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        let start = DispatchTime.now().uptimeNanoseconds
        editor.insertPictureFiles(urls)
        editor.layoutManager?.ensureLayout(for: try XCTUnwrap(editor.textContainer))
        let inText = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
        let pictures = ComposeInlineImages.pictures(in: try XCTUnwrap(editor.textStorage))
        XCTAssertEqual(pictures.count, 10)
        pictures.forEach { $0.finishNow() }
        let ready = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
        XCTAssertTrue(pictures.allSatisfy(\.isReady))
        print("picture budget: ten 12 MP \(heic == nil ? "TIFF" : "HEIC") files in the text \(Self.ms(inText)), all ready \(Self.ms(ready))")
        XCTAssertLessThan(inText, 0.05, "ten photos are in the text within 50 ms; the window never waits for their conversion")
    }

    private static func ms(_ seconds: TimeInterval) -> String {
        "\(Int((seconds * 1000).rounded())) ms"
    }

    private func median(of runs: Int, _ work: () throws -> Void) throws -> TimeInterval {
        var times: [TimeInterval] = []
        for _ in 0..<runs {
            let start = DispatchTime.now().uptimeNanoseconds
            try work()
            times.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9)
        }
        return times.sorted()[times.count / 2]
    }

    private static func encode(_ rep: NSBitmapImageRep, as type: String) -> Data? {
        guard let image = rep.cgImage else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, type as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination), output.length > 0 else { return nil }
        return output as Data
    }

    /// A photo-like picture: smooth gradients with fine noise, which compresses as a camera's does rather than as a
    /// flat colour would.
    private static func photo(width: Int, height: Int) -> NSBitmapImageRep {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 3,
                                   hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: width * 3, bitsPerPixel: 24)!
        let pixels = rep.bitmapData!
        var seed: UInt32 = 2_463_534_242
        for y in 0..<height {
            for x in 0..<width {
                seed ^= seed << 13; seed ^= seed >> 17; seed ^= seed << 5
                let noise = Int(seed & 15) - 8
                let offset = (y * width + x) * 3
                pixels[offset] = UInt8(clamping: x * 255 / width + noise)
                pixels[offset + 1] = UInt8(clamping: y * 255 / height + noise)
                pixels[offset + 2] = UInt8(clamping: 128 + noise)
            }
        }
        return rep
    }
}
