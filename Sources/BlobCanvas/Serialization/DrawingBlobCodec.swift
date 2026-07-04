import Foundation
import Compression

/// Flat binary codec for `DrawingSession` → single `Data` blob.
///
/// ## Format v2 (current)
///
/// Points are **quantized and delta-encoded**, then LZFSE-compressed. Raw
/// `Float32` coordinates are high-entropy in their low mantissa bits and
/// compress poorly; quantizing to a fixed grid and storing deltas between
/// consecutive samples as zig-zag varints shrinks the payload several-fold on
/// real hand-drawn input (adjacent samples are close, so deltas are tiny).
///
/// - Coordinates: fixed-point at 1/32 pt (`coordScale`) — sub-pixel, visually
///   lossless. Stored as zig-zag varint deltas.
/// - Pressure: 8-bit (0…255).
/// - Timestamp: milliseconds (`timeScale`), zig-zag varint delta.
///
/// ```
/// Outer container:
///   magic        4 × UInt8   "BLBC"
///   version      UInt16      2
///   algorithm    UInt8       0 = raw, 1 = LZFSE
///   payload      [UInt8]     (compressed) inner payload
///
/// Inner payload (v2):
///   canvasW      Float32
///   canvasH      Float32
///   strokeCount  varint
///   strokes:
///     r,g,b,a    4 × UInt8
///     brushSize  Float32
///     pointCount varint
///     points:    (Δx zig-zag varint, Δy zig-zag varint, pressure UInt8, Δt zig-zag varint)
/// ```
///
/// ## Format v1 (legacy, decode-only)
///
/// Points stored as raw `Float32 × 4` (16 bytes). Still decoded for migration.
public enum DrawingBlobCodec {

    public enum CodecError: Error, Equatable {
        case badMagic
        case unsupportedVersion(UInt16)
        case truncated
        case decompressionFailed
        /// A declared point/stroke count that exceeds `pointSanityLimit`,
        /// indicating a corrupt or hostile blob.
        case implausibleCount
    }

    static let magic: [UInt8] = [0x42, 0x4C, 0x42, 0x43] // "BLBC"
    static let version: UInt16 = 3
    static let legacyPointStride = MemoryLayout<StrokePoint>.stride // 16

    /// Fixed-point resolution for coordinates: 1/32 pt.
    static let coordScale: Float = 32
    /// Fixed-point resolution for timestamps: milliseconds.
    static let timeScale: Float = 1000

    /// Upper bound on points in one stroke, guarding against a corrupt length
    /// field driving a huge allocation. 64M points ≈ 1 GB raw — well beyond any
    /// real drawing, but bounded.
    static let pointSanityLimit: UInt64 = 64 * 1024 * 1024

    // MARK: - Encode (v2)

    /// Serializes and LZFSE-compresses a session. Call on auto-save/export
    /// (off the main thread for large drawings), never per frame.
    public static func encode(_ session: DrawingSession, compress: Bool = true) -> Data {
        var payload = Data(capacity: 8 + session.strokes.count * 8 + session.pointCount * 6)

        payload.appendLE(session.canvasSize.x)
        payload.appendLE(session.canvasSize.y)
        payload.appendVarint(UInt64(session.strokes.count))

        for stroke in session.strokes {
            payload.append(contentsOf: [stroke.color.r, stroke.color.g, stroke.color.b, stroke.color.a])
            payload.append(flags(for: stroke))
            payload.appendLE(stroke.brushSize)
            payload.appendVarint(UInt64(stroke.points.count))

            var px: Int64 = 0, py: Int64 = 0, pt: Int64 = 0
            for point in stroke.points {
                let fx = Int64((point.x * coordScale).rounded())
                let fy = Int64((point.y * coordScale).rounded())
                let ft = Int64((point.timestamp * timeScale).rounded())
                payload.appendZigzag(fx - px)
                payload.appendZigzag(fy - py)
                payload.append(quantizePressure(point.pressure))
                payload.appendZigzag(ft - pt)
                px = fx; py = fy; pt = ft
            }
        }

        return wrap(payload, version: version, compress: compress)
    }

    // MARK: - Decode

    public static func decode(_ blob: Data) throws -> DrawingSession {
        var reader = Reader(blob)
        guard try reader.readBytes(4).elementsEqual(magic) else { throw CodecError.badMagic }
        let fileVersion: UInt16 = try reader.readLE()

        switch fileVersion {
        case 3: return try decodeDelta(payload: decompressPayload(&reader), hasFlags: true)
        case 2: return try decodeDelta(payload: decompressPayload(&reader), hasFlags: false)
        case 1: return try decodeV1(payload: decompressPayload(&reader))
        default: throw CodecError.unsupportedVersion(fileVersion)
        }
    }

    /// Shared decoder for the delta point format. `hasFlags` distinguishes v3
    /// (per-stroke blend/dynamics byte) from v2 (no such byte).
    private static func decodeDelta(payload: Data, hasFlags: Bool) throws -> DrawingSession {
        var body = Reader(payload)
        let w: Float = try body.readLE()
        let h: Float = try body.readLE()
        let strokeCount = try body.readVarint()
        guard strokeCount <= pointSanityLimit else { throw CodecError.implausibleCount }

        var strokes: [Stroke] = []
        strokes.reserveCapacity(Int(strokeCount))

        for _ in 0..<strokeCount {
            let color = StrokeColor(
                r: try body.readByte(), g: try body.readByte(),
                b: try body.readByte(), a: try body.readByte()
            )
            let (blendMode, dynamics): (BlendMode, WidthDynamics) =
                hasFlags ? decodeFlags(try body.readByte()) : (.normal, .pressure)
            let brushSize: Float = try body.readLE()
            let pointCount = try body.readVarint()
            guard pointCount <= pointSanityLimit else { throw CodecError.implausibleCount }

            var points = [StrokePoint]()
            points.reserveCapacity(Int(pointCount))
            var px: Int64 = 0, py: Int64 = 0, pt: Int64 = 0
            for _ in 0..<pointCount {
                px += try body.readZigzag()
                py += try body.readZigzag()
                let pressure = try body.readByte()
                pt += try body.readZigzag()
                points.append(StrokePoint(
                    x: Float(px) / coordScale,
                    y: Float(py) / coordScale,
                    pressure: Float(pressure) / 255,
                    timestamp: Float(pt) / timeScale
                ))
            }
            strokes.append(Stroke(points: points, color: color, brushSize: brushSize,
                                  blendMode: blendMode, dynamics: dynamics))
        }
        return DrawingSession(canvasSize: SIMD2(w, h), strokes: strokes)
    }

    // MARK: - Stroke flags

    private static func flags(for stroke: Stroke) -> UInt8 {
        (stroke.blendMode == .erase ? 1 : 0) | (stroke.dynamics.rawValue << 1)
    }

    private static func decodeFlags(_ byte: UInt8) -> (BlendMode, WidthDynamics) {
        let blend: BlendMode = (byte & 1) == 1 ? .erase : .normal
        let dynamics = WidthDynamics(rawValue: (byte >> 1) & 0x3) ?? .pressure
        return (blend, dynamics)
    }

    private static func decodeV1(payload: Data) throws -> DrawingSession {
        var body = Reader(payload)
        let w: Float = try body.readLE()
        let h: Float = try body.readLE()
        let strokeCount: UInt32 = try body.readLE()
        guard UInt64(strokeCount) <= pointSanityLimit else { throw CodecError.implausibleCount }

        var strokes: [Stroke] = []
        strokes.reserveCapacity(Int(strokeCount))

        for _ in 0..<strokeCount {
            let color = StrokeColor(
                r: try body.readByte(), g: try body.readByte(),
                b: try body.readByte(), a: try body.readByte()
            )
            let brushSize: Float = try body.readLE()
            let pointCount: UInt32 = try body.readLE()
            guard UInt64(pointCount) <= pointSanityLimit else { throw CodecError.implausibleCount }

            let byteCount = Int(pointCount) * legacyPointStride
            let pointBytes = try body.readBytes(byteCount)
            let points = [StrokePoint](unsafeUninitializedCapacity: Int(pointCount)) { buffer, initialized in
                _ = pointBytes.copyBytes(to: buffer)
                initialized = Int(pointCount)
            }
            strokes.append(Stroke(points: points, color: color, brushSize: brushSize))
        }
        return DrawingSession(canvasSize: SIMD2(w, h), strokes: strokes)
    }

    // MARK: - Container helpers

    private static func wrap(_ payload: Data, version: UInt16, compress: Bool) -> Data {
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

    private static func decompressPayload(_ reader: inout Reader) throws -> Data {
        let algorithm: UInt8 = try reader.readByte()
        switch algorithm {
        case 0:
            return try reader.remainder()
        case 1:
            let compressed = try reader.remainder()
            guard let raw = try? (compressed as NSData).decompressed(using: .lzfse) else {
                throw CodecError.decompressionFailed
            }
            return raw as Data
        default:
            throw CodecError.decompressionFailed
        }
    }

    private static func quantizePressure(_ p: Float) -> UInt8 {
        UInt8((min(max(p, 0), 1) * 255).rounded())
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
            guard count >= 0, data.endIndex - offset >= count else { throw CodecError.truncated }
            defer { offset += count }
            return data[offset..<(offset + count)]
        }

        mutating func readByte() throws -> UInt8 {
            guard offset < data.endIndex else { throw CodecError.truncated }
            defer { offset += 1 }
            return data[offset]
        }

        mutating func readLE<T: FixedWidthInteger>() throws -> T {
            let bytes = try readBytes(MemoryLayout<T>.size)
            return bytes.withUnsafeBytes { T(littleEndian: $0.loadUnaligned(as: T.self)) }
        }

        mutating func readLE() throws -> Float {
            let raw: UInt32 = try readLE()
            return Float(bitPattern: raw)
        }

        mutating func readVarint() throws -> UInt64 {
            var result: UInt64 = 0
            var shift: UInt64 = 0
            while true {
                let byte = try readByte()
                result |= UInt64(byte & 0x7F) << shift
                if byte & 0x80 == 0 { break }
                shift += 7
                if shift >= 64 { throw CodecError.truncated }
            }
            return result
        }

        mutating func readZigzag() throws -> Int64 {
            let n = try readVarint()
            return Int64(bitPattern: (n >> 1) ^ (0 &- (n & 1)))
        }

        mutating func remainder() throws -> Data {
            defer { offset = data.endIndex }
            return data[offset...]
        }
    }
}

// MARK: - Legacy v1 encoder (test/migration fixtures only)

extension DrawingBlobCodec {
    /// Produces a version-1 blob (raw `Float32` points). Not used in production
    /// — kept so the v1 decode path can be exercised and to generate migration
    /// fixtures.
    static func encodeLegacyV1(_ session: DrawingSession, compress: Bool = true) -> Data {
        var payload = Data()
        payload.appendLE(session.canvasSize.x)
        payload.appendLE(session.canvasSize.y)
        payload.appendLE(UInt32(session.strokes.count))
        for stroke in session.strokes {
            payload.append(contentsOf: [stroke.color.r, stroke.color.g, stroke.color.b, stroke.color.a])
            payload.appendLE(stroke.brushSize)
            payload.appendLE(UInt32(stroke.points.count))
            stroke.points.withUnsafeBytes { payload.append(contentsOf: $0) }
        }
        return wrap(payload, version: 1, compress: compress)
    }

    /// Produces a version-2 blob (delta points, no per-stroke flags). Test-only,
    /// for exercising the v2 → current migration path.
    static func encodeLegacyV2(_ session: DrawingSession, compress: Bool = true) -> Data {
        var payload = Data()
        payload.appendLE(session.canvasSize.x)
        payload.appendLE(session.canvasSize.y)
        payload.appendVarint(UInt64(session.strokes.count))
        for stroke in session.strokes {
            payload.append(contentsOf: [stroke.color.r, stroke.color.g, stroke.color.b, stroke.color.a])
            payload.appendLE(stroke.brushSize)
            payload.appendVarint(UInt64(stroke.points.count))
            var px: Int64 = 0, py: Int64 = 0, pt: Int64 = 0
            for point in stroke.points {
                let fx = Int64((point.x * coordScale).rounded())
                let fy = Int64((point.y * coordScale).rounded())
                let ft = Int64((point.timestamp * timeScale).rounded())
                payload.appendZigzag(fx - px); payload.appendZigzag(fy - py)
                payload.append(UInt8((min(max(point.pressure, 0), 1) * 255).rounded()))
                payload.appendZigzag(ft - pt)
                px = fx; py = fy; pt = ft
            }
        }
        return wrap(payload, version: 2, compress: compress)
    }
}

// MARK: - Data writing helpers

extension Data {
    @usableFromInline
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }

    @usableFromInline
    mutating func appendLE(_ value: Float) {
        appendLE(value.bitPattern)
    }

    /// LEB128 unsigned varint.
    mutating func appendVarint(_ value: UInt64) {
        var v = value
        repeat {
            var byte = UInt8(v & 0x7F)
            v >>= 7
            if v != 0 { byte |= 0x80 }
            append(byte)
        } while v != 0
    }

    /// Zig-zag mapped signed varint (small magnitudes → few bytes).
    mutating func appendZigzag(_ value: Int64) {
        appendVarint(UInt64(bitPattern: (value << 1) ^ (value >> 63)))
    }
}
