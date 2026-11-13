import AppKit
import SSCore
import XCTest
@testable import SuperSparrowApp

/// The composer's picture budget in docs/ARCHITECTURE.md (spec §5.20, Images in the body): a 12-megapixel photo pasted
/// as a JPEG is in the text within 100 ms (its bytes kept, decoded for the screen no larger than 2,400 pixels), and the
/// same photo pasted as a TIFF, which is encoded again as a PNG first, within 1.5 s. Making the pictures takes a while
/// in a debug build, so it only runs with `SS_PERF=1`:
///
///     SS_PERF=1 swift test -c release --filter ComposerInlineImagePerformanceTests
@MainActor
final class ComposerInlineImagePerformanceTests: XCTestCase {
    func testAPastedPhotoIsInTheTextWithinBudget() throws {
        guard ProcessInfo.processInfo.environment["SS_PERF"] == "1" else {
            throw XCTSkip("set SS_PERF=1 to run the picture benchmark")
        }
        let photo = Self.photo(width: 4000, height: 3000)
        let jpeg = try XCTUnwrap(photo.representation(using: .jpeg, properties: [.compressionFactor: 0.85]))
        let tiff = try XCTUnwrap(photo.tiffRepresentation)
        let editor = ComposeTextView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))

        let kept = try median(of: 5) {
            let picture = try XCTUnwrap(ComposeImageAttachment.make(data: jpeg, typeIdentifier: "public.jpeg", filename: nil))
            editor.insertPictures([picture])
            editor.layoutManager?.ensureLayout(for: try XCTUnwrap(editor.textContainer))
        }
        let encoded = try median(of: 3) {
            let picture = try XCTUnwrap(ComposeImageAttachment.make(data: tiff, typeIdentifier: "public.tiff", filename: nil))
            editor.insertPictures([picture])
            editor.layoutManager?.ensureLayout(for: try XCTUnwrap(editor.textContainer))
        }
        print("picture budget: 12 MP JPEG \(Int(kept * 1000)) ms (\(jpeg.count / 1024) KB); 12 MP TIFF to PNG \(Int(encoded * 1000)) ms")
        XCTAssertLessThan(kept, 0.1, "a JPEG goes in within 100 ms")
        XCTAssertLessThan(encoded, 1.5, "a TIFF, encoded as a PNG first, within 1.5 s")
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
