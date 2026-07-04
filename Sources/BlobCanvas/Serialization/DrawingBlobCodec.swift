import Foundation
import Compression

/// Flat binary codec for `DrawingSession` → single `Data` blob.
///
/// Layout (all little-endian, the native byte order on every Apple platform):
///
/// ```
/// Outer container:
///   magic        4 × UInt8   "BLBC"
///   version      UInt16      format version (currently 1)
///   algorithm    UInt8       0 = raw, 1 = LZFSE
///   payload      [UInt8]     (compressed) inner payload
///
/// Inner payload:
///   canvasW      Float32
///   canvasH      Float32
///   strokeCount  UInt32
///   strokes:
///     r,g,b,a    4 × UInt8
///     brushSize  Float32
///     pointCount UInt32
///     points     pointCount × 16 bytes  (x, y, pressure, timestamp — Float32 each,
///                copied in bulk from the contiguous [StrokePoint] buffer)
/// ```
///
/// A 10k-point drawing is ~160 KB raw and typically 40–80 KB after LZFSE —
/// versus thousands of rows in a relational model.
public enum DrawingBlobCodec {

    public enum CodecError: Error {
        case badMagic
        case unsupportedVersion(UInt16)
        case truncated
        case decompressionFailed
    }

    static let magic: [UInt8] = [0x42, 0x4C, 0x42, 0x43] // "BLBC"
    static let version: UInt16 = 1
    static let pointStride = MemoryLayout<StrokePoint>.stride // 16

    // MARK: - Encode

    /// Serializes and LZFSE-compresses a session. Call on auto-save/export
    /// (off the main thread for large drawings), never per frame.
    public static func encode(_ session: DrawingSession, compress: Bool = true) -> Data {
        var payload = Data(capacity: payloadSize(of: session))

        payload.appendLE(session.canvasSize.x)
        payload.appendLE(session.canvasSize.y)
        payload.appendLE(UInt32(session.strokes.count))

        for stroke in session.strokes {
            payload.append(contentsOf: [stroke.color.r, stroke.color.g, stroke.color.b, stroke.color.a])
            payload.appendLE(stroke.brushSize)
            payload.appendLE(UInt32(stroke.points.count))
            // Bulk copy: [StrokePoint] is a contiguous buffer of 4 Float32s per element.
            stroke.points.withUnsafeBytes { payload.append(contentsOf: $0) }
        }

        var blob = Data(capacity: payload.count + 8)
        blob.append(contentsOf: magic)
        blob.appendLE(version)

        if compress,
           let compressed = try? (payload as NSData).compressed(using: .lzfse),
           compressed.count < payload.count {
            blob.append(1)
            blob.append(compressed as Data)
        } else {
            blob.append(0)
            blob.append(payload)
        }
        return blob
    }

    // MARK: - Decode

    public static func decode(_ blob: Data) throws -> DrawingSession {
        var reader = Reader(blob)

        guard try reader.readBytes(4).elementsEqual(magic) else { throw CodecError.badMagic }
        let fileVersion: UInt16 = try reader.readLE()
        guard fileVersion == version else { throw CodecError.unsupportedVersion(fileVersion) }
        let algorithm: UInt8 = try reader.readLE()

        let payload: Data
        switch algorithm {
        case 0:
            payload = try reader.remainder()
        case 1:
            let compressed = try reader.remainder()
            guard let raw = try? (compressed as NSData).decompressed(using: .lzfse) else {
                throw CodecError.decompressionFailed
            }
            payload = raw as Data
        default:
            throw CodecError.decompressionFailed
        }

        var body = Reader(payload)
        let w: Float = try body.readLE()
        let h: Float = try body.readLE()
        let strokeCount: UInt32 = try body.readLE()

        var strokes: [Stroke] = []
        strokes.reserveCapacity(Int(strokeCount))

        for _ in 0..<strokeCount {
            // Note: readBytes returns a slice sharing the parent's indices,
            // so color bytes are read individually rather than subscripted.
            let color = StrokeColor(
                r: try body.readLE(), g: try body.readLE(),
                b: try body.readLE(), a: try body.readLE()
            )
            let brushSize: Float = try body.readLE()
            let pointCount: UInt32 = try body.readLE()

            let byteCount = Int(pointCount) * pointStride
            let pointBytes = try body.readBytes(byteCount)
            // Bulk copy back into a contiguous [StrokePoint].
            let points = [StrokePoint](unsafeUninitializedCapacity: Int(pointCount)) { buffer, initialized in
                _ = pointBytes.copyBytes(to: buffer)
                initialized = Int(pointCount)
            }
            strokes.append(Stroke(points: points, color: color, brushSize: brushSize))
        }

        return DrawingSession(canvasSize: SIMD2(w, h), strokes: strokes)
    }

    // MARK: - Helpers

    private static func payloadSize(of session: DrawingSession) -> Int {
        12 + session.strokes.reduce(0) { $0 + 12 + $1.points.count * pointStride }
    }

    /// Zero-copy sequential reader over a Data blob.
    private struct Reader {
        let data: Data
        var offset: Int

        init(_ data: Data) {
            self.data = data
            self.offset = data.startIndex
        }

        mutating func readBytes(_ count: Int) throws -> Data {
            guard data.endIndex - offset >= count else { throw CodecError.truncated }
            defer { offset += count }
            return data[offset..<(offset + count)]
        }

        mutating func readLE<T: FixedWidthInteger>() throws -> T {
            let bytes = try readBytes(MemoryLayout<T>.size)
            return bytes.withUnsafeBytes { T(littleEndian: $0.loadUnaligned(as: T.self)) }
        }

        mutating func readLE() throws -> Float {
            let raw: UInt32 = try readLE()
            return Float(bitPattern: raw)
        }

        mutating func remainder() throws -> Data {
            defer { offset = data.endIndex }
            return data[offset...]
        }
    }
}

extension Data {
    @usableFromInline
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }

    @usableFromInline
    mutating func appendLE(_ value: Float) {
        appendLE(value.bitPattern)
    }
}
