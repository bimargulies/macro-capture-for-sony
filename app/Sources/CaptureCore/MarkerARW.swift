import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Builds a minimal but valid ARW file that looks like a photo taken with the lens cap on.
///
/// Stack markers are delivered to the same folder as the real photos, and the importer
/// (import-sony-raw-photos) recognizes them as black frames: it reads the capture time from EXIF,
/// extracts the embedded JPEG preview, and checks that the centre is dark and flat. The file is a
/// tiny TIFF with the same layout as a real ARW: IFD0 (make, model, preview JPEG), an Exif IFD
/// (capture time) and a SubIFD holding a small uncompressed strip, so that the strip offsets and
/// byte counts fit inside the file (the importer treats files whose strips run past the end as
/// still being written).
public enum MarkerARW {
    public static func make(at time: NaiveTime, model: String = "ILCE-7RM5") -> Data {
        var b = Builder()
        let preview = blackJPEG(width: 320, height: 214)
        let strip = Data(count: 16 * 16)  // 16x16, 8-bit gray, all zero

        let dateTime = ascii(time.exifDateTime)
        let subsec = ascii(time.exifSubsec)

        // Fixed layout: header, IFD0, Exif IFD, SubIFD, then out-of-line data.
        let ifd0Count = 10, exifCount = 4, subCount = 10
        func ifdSize(_ n: Int) -> Int { 2 + n * 12 + 4 }
        let ifd0Off = 8
        let exifOff = ifd0Off + ifdSize(ifd0Count)
        let subOff = exifOff + ifdSize(exifCount)
        b.cursor = subOff + ifdSize(subCount)

        let makeOff = b.alloc(ascii("SONY"))
        let modelOff = b.alloc(ascii(model))
        let dtOff = b.alloc(dateTime)
        let dtoOff = b.alloc(dateTime)
        let dtdOff = b.alloc(dateTime)
        let previewOff = b.alloc(preview)
        let stripOff = b.alloc(strip)

        let ifd0: [Entry] = [
            .long(0x00FE, 1),                                   // NewSubfileType: reduced-resolution image
            .short(0x0103, 6),                                  // Compression: JPEG (the preview)
            .ascii(0x010F, "SONY", offset: makeOff),
            .ascii(0x0110, model, offset: modelOff),
            .short(0x0112, 1),                                  // Orientation
            .asciiOut(0x0132, count: dateTime.count, offset: dtOff), // ModifyDate
            .long(0x014A, UInt32(subOff)),                      // SubIFDs
            .long(0x0201, UInt32(previewOff)),                  // PreviewImageStart
            .long(0x0202, UInt32(preview.count)),               // PreviewImageLength
            .long(0x8769, UInt32(exifOff)),                     // ExifIFD
        ]
        let exif: [Entry] = [
            .asciiOut(0x9003, count: dateTime.count, offset: dtoOff),  // DateTimeOriginal
            .asciiOut(0x9004, count: dateTime.count, offset: dtdOff),  // CreateDate
            .asciiInline(0x9290, subsec),                              // SubSecTime
            .asciiInline(0x9291, subsec),                              // SubSecTimeOriginal
        ]
        let sub: [Entry] = [
            .long(0x00FE, 0),                                   // full-resolution image
            .long(0x0100, 16),                                  // ImageWidth
            .long(0x0101, 16),                                  // ImageHeight
            .short(0x0102, 8),                                  // BitsPerSample
            .short(0x0103, 1),                                  // Compression: none
            .short(0x0106, 1),                                  // Photometric: BlackIsZero
            .long(0x0111, UInt32(stripOff)),                    // StripOffsets
            .short(0x0115, 1),                                  // SamplesPerPixel
            .long(0x0116, 16),                                  // RowsPerStrip
            .long(0x0117, UInt32(strip.count)),                 // StripByteCounts
        ]
        precondition(ifd0.count == ifd0Count && exif.count == exifCount && sub.count == subCount)

        var out = Data()
        out.append(contentsOf: [0x49, 0x49, 0x2A, 0x00])        // "II", 42 (little endian)
        out.append(le32(UInt32(ifd0Off)))
        out.append(encode(ifd0))
        out.append(encode(exif))
        out.append(encode(sub))
        for (off, bytes) in b.blobs {
            precondition(out.count == off, "blob layout mismatch")
            out.append(bytes)
            if bytes.count % 2 == 1 { out.append(0) }
        }
        return out
    }

    /// A solid black JPEG, used as the marker's embedded preview.
    public static func blackJPEG(width: Int, height: Int) -> Data {
        let space = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = ctx.makeImage()!
        let data = NSMutableData()
        let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        CGImageDestinationFinalize(dest)
        return data as Data
    }

    // MARK: TIFF encoding

    private struct Builder {
        var cursor = 0
        var blobs: [(Int, Data)] = []
        mutating func alloc(_ bytes: Data) -> Int {
            let off = cursor
            blobs.append((off, bytes))
            cursor += bytes.count + (bytes.count % 2)
            return off
        }
    }

    private struct Entry {
        let tag: UInt16, type: UInt16, count: UInt32
        let value: [UInt8]  // exactly 4 bytes: the inline value or the offset

        static func short(_ tag: UInt16, _ v: UInt16) -> Entry {
            Entry(tag: tag, type: 3, count: 1, value: [UInt8(v & 0xFF), UInt8(v >> 8), 0, 0])
        }
        static func long(_ tag: UInt16, _ v: UInt32) -> Entry {
            Entry(tag: tag, type: 4, count: 1, value: bytes32(v))
        }
        /// An ASCII string stored out of line (more than 4 bytes including the NUL).
        static func ascii(_ tag: UInt16, _ s: String, offset: Int) -> Entry {
            Entry(tag: tag, type: 2, count: UInt32(s.utf8.count + 1), value: bytes32(UInt32(offset)))
        }
        static func asciiOut(_ tag: UInt16, count: Int, offset: Int) -> Entry {
            Entry(tag: tag, type: 2, count: UInt32(count), value: bytes32(UInt32(offset)))
        }
        /// A short ASCII string (3 chars plus NUL) that fits in the 4-byte value field.
        static func asciiInline(_ tag: UInt16, _ d: Data) -> Entry {
            precondition(d.count <= 4)
            var v = [UInt8](d); while v.count < 4 { v.append(0) }
            return Entry(tag: tag, type: 2, count: UInt32(d.count), value: v)
        }
        private static func bytes32(_ v: UInt32) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8(v >> 24)] }
    }

    private static func encode(_ entries: [Entry]) -> Data {
        precondition(entries.map(\.tag) == entries.map(\.tag).sorted(), "IFD tags must be ascending")
        var d = Data()
        d.append(UInt8(entries.count & 0xFF)); d.append(UInt8(entries.count >> 8))
        for e in entries {
            d.append(UInt8(e.tag & 0xFF)); d.append(UInt8(e.tag >> 8))
            d.append(UInt8(e.type & 0xFF)); d.append(UInt8(e.type >> 8))
            d.append(le32(e.count))
            d.append(contentsOf: e.value)
        }
        d.append(le32(0))  // no next IFD
        return d
    }

    private static func le32(_ v: UInt32) -> Data {
        Data([UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8(v >> 24)])
    }

    /// NUL-terminated ASCII bytes.
    private static func ascii(_ s: String) -> Data { Data(s.utf8) + [0] }
}
