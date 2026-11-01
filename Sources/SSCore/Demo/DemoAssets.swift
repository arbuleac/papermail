import Foundation

/// Attachment bytes the demo mailbox serves, generated in code so the repository carries no binary fixtures.
enum DemoAssets {
    /// A 160×100 "sunset over the bay" picture. Valid PNG with stored (uncompressed) deflate blocks, so no
    /// compression library is needed.
    static let offsitePhotoPNG: Data = makeSunsetPNG(width: 160, height: 100)

    /// A one-page invoice in PDF 1.4 with a real cross-reference table, so Quick Look renders it.
    static let invoicePDF: Data = makeInvoicePDF()

    // MARK: PNG

    static func makeSunsetPNG(width: Int, height: Int) -> Data {
        var raw = Data(capacity: (width * 3 + 1) * height)
        let sunX = Double(width) * 0.68, sunY = Double(height) * 0.52, sunR = Double(height) * 0.16
        let horizon = Int(Double(height) * 0.62)
        for y in 0..<height {
            raw.append(0) // filter type: none
            for x in 0..<width {
                var r: Double, g: Double, b: Double
                if y < horizon {
                    let t = Double(y) / Double(horizon)
                    r = 70 + 185 * t; g = 90 + 80 * t; b = 170 - 60 * t
                    let dx = Double(x) - sunX, dy = Double(y) - sunY
                    let d = (dx * dx + dy * dy).squareRoot()
                    if d < sunR {
                        r = 255; g = 214; b = 120
                    } else if d < sunR * 2.2 {
                        let glow = 1 - (d - sunR) / (sunR * 1.2)
                        r += (255 - r) * glow * 0.5
                        g += (200 - g) * glow * 0.4
                    }
                } else {
                    let t = Double(y - horizon) / Double(height - horizon)
                    let wave = (sin(Double(x) / 6 + Double(y) * 1.3) + 1) / 2
                    r = 40 + 60 * (1 - t) + 30 * wave
                    g = 70 + 40 * (1 - t) + 20 * wave
                    b = 120 + 40 * (1 - t)
                    if abs(Double(x) - sunX) < sunR * (1.2 - t), wave > 0.55 { r = 240; g = 190; b = 110 }
                }
                raw.append(UInt8(max(0, min(255, r))))
                raw.append(UInt8(max(0, min(255, g))))
                raw.append(UInt8(max(0, min(255, b))))
            }
        }
        var png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        var header = Data()
        header.appendBigEndian(UInt32(width))
        header.appendBigEndian(UInt32(height))
        header.append(contentsOf: [8, 2, 0, 0, 0]) // 8-bit RGB, deflate, adaptive filtering, no interlace
        png.appendChunk("IHDR", header)
        png.appendChunk("IDAT", zlibStored(raw))
        png.appendChunk("IEND", Data())
        return png
    }

    static func zlibStored(_ data: Data) -> Data {
        var out = Data([0x78, 0x01])
        let bytes = [UInt8](data)
        var offset = 0
        repeat {
            let length = min(65_535, bytes.count - offset)
            let isFinal: UInt8 = offset + length >= bytes.count ? 1 : 0
            out.append(isFinal)
            out.append(UInt8(length & 0xFF))
            out.append(UInt8(length >> 8))
            let complement = ~UInt16(length)
            out.append(UInt8(complement & 0xFF))
            out.append(UInt8(complement >> 8))
            out.append(contentsOf: bytes[offset..<(offset + length)])
            offset += length
        } while offset < bytes.count
        var a: UInt32 = 1, b: UInt32 = 0
        for byte in bytes {
            a = (a + UInt32(byte)) % 65_521
            b = (b + a) % 65_521
        }
        out.appendBigEndian((b << 16) | a)
        return out
    }

    static let crcTable: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func crc32(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for byte in data { c = crcTable[Int((c ^ UInt32(byte)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }

    // MARK: PDF

    static func makeInvoicePDF() -> Data {
        let lines: [(text: String, y: Int, size: Int)] = [
            ("Northwind Print Co.", 720, 20),
            ("Invoice INV-2041", 690, 14),
            ("Bill to: Alex Morgan", 650, 11),
            ("Description                          Qty      Amount", 610, 11),
            ("Conference banners (2 x 1 m)          3      $420.00", 590, 11),
            ("Printed programmes                  250      $187.50", 572, 11),
            ("Delivery                              1       $35.00", 554, 11),
            ("Total due                                    $642.50", 520, 12),
            ("Payment terms: 30 days. Thank you for your business.", 480, 10),
        ]
        var stream = "BT\n"
        for line in lines {
            let escaped = line.text.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "(", with: "\\(")
                .replacingOccurrences(of: ")", with: "\\)")
            stream += "/F1 \(line.size) Tf 1 0 0 1 72 \(line.y) Tm (\(escaped)) Tj\n"
        }
        stream += "ET\n"
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>",
            "<< /Length \(stream.utf8.count) >>\nstream\n\(stream)endstream",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
        ]
        var pdf = "%PDF-1.4\n"
        var offsets: [Int] = []
        for (index, body) in objects.enumerated() {
            offsets.append(pdf.utf8.count)
            pdf += "\(index + 1) 0 obj\n\(body)\nendobj\n"
        }
        let xref = pdf.utf8.count
        pdf += "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for offset in offsets { pdf += String(format: "%010d 00000 n \n", offset) }
        pdf += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        return Data(pdf.utf8)
    }
}

private extension Data {
    mutating func appendBigEndian(_ value: UInt32) {
        append(UInt8(value >> 24))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8(value & 0xFF))
    }

    mutating func appendChunk(_ type: String, _ payload: Data) {
        appendBigEndian(UInt32(payload.count))
        var typed = Data(type.utf8)
        typed.append(payload)
        append(typed)
        appendBigEndian(DemoAssets.crc32(typed))
    }
}
