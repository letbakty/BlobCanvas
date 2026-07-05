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
    static let version: UInt16 = 4
    static let legacyPointStride = MemoryLayout<StrokePoint>.stride // 16

    /// Fixed-point resolution for coordinates: 1/32 pt.
    static let coordScale: Float = 32
    /// Fixed-point resolution for timestamps: milliseconds.
    static let timeScale: Float = 1000

    /// Upper bound on points in one stroke, guarding against a corrupt length
    /// field driving a huge allocation. 64M points ≈ 1 GB raw — well beyond any
    /// real drawing, but bounded.
    static let pointSanityLimit: UInt64 = 64 * 1024 * 1024

    /// Largest canvas dimension we'll trust from a decoded blob (also the common
    /// GPU max texture size). Guards `Int(Float)` conversions downstream from
    /// trapping on NaN/Inf or exploding on absurd sizes.
    static let maxCanvasDimension: Float = 16384

    /// Cap on eager `reserveCapacity` from an untrusted count, so a tiny blob
    /// claiming a huge count can't pre-allocate gigabytes. Real arrays still grow
    /// as data is actually read.
    static let reserveCap = 4096

    /// Clamps an untrusted float to a finite range, replacing NaN/Inf with `def`.
    static func sanitize(_ v: Float, default def: Float, min lo: Float, max hi: Float) -> Float {
        v.isFinite ? Swift.min(Swift.max(v, lo), hi) : def
    }

    /// A finite, bounded canvas size — safe for downstream `Int(Float)` math.
    static func sanitizedCanvas(_ w: Float, _ h: Float) -> SIMD2<Float> {
        SIMD2(sanitize(w, default: 1, min: 1, max: maxCanvasDimension),
              sanitize(h, default: 1, min: 1, max: maxCanvasDimension))
    }

    // MARK: - Encode (v4: layers)

    /// Serializes and LZFSE-compresses a session. Call on auto-save/export
    /// (off the main thread for large drawings), never per frame.
    public static func encode(_ session: DrawingSession, compress: Bool = true) -> Data {
        var payload = Data(capacity: 12 + session.pointCount * 6)

        payload.appendLE(session.canvasSize.x)
        payload.appendLE(session.canvasSize.y)
        payload.appendVarint(UInt64(session.activeLayerIndex))
        payload.appendVarint(UInt64(session.layers.count))

        for layer in session.layers {
            appendString(layer.name, to: &payload)
            payload.appendLE(layer.opacity)
            payload.append(layer.isVisible ? 1 : 0)
            payload.appendVarint(UInt64(layer.strokes.count))
            for stroke in layer.strokes { appendStroke(stroke, to: &payload) }
        }
        return wrap(payload, version: version, compress: compress)
    }

    /// Encodes one stroke (color, flags, brush size, delta-varint points).
    private static func appendStroke(_ stroke: Stroke, to payload: inout Data) {
        payload.append(contentsOf: [stroke.color.r, stroke.color.g, stroke.color.b, stroke.color.a])
        payload.append(flags(for: stroke))
        payload.appendLE(stroke.brushSize)
        payload.appendVarint(UInt64(stroke.points.count))
        var px: Int64 = 0, py: Int64 = 0, pt: Int64 = 0
        for point in stroke.points {
            let fx = fixed(point.x, coordScale)
            let fy = fixed(point.y, coordScale)
            let ft = fixed(point.timestamp, timeScale)
            payload.appendZigzag(fx &- px)
            payload.appendZigzag(fy &- py)
            payload.append(quantizePressure(point.pressure))
            payload.appendZigzag(ft &- pt)
            px = fx; py = fy; pt = ft
        }
    }

    // MARK: - Decode

    public static func decode(_ blob: Data) throws -> DrawingSession {
        var reader = Reader(blob)
        guard try reader.readBytes(4).elementsEqual(magic) else { throw CodecError.badMagic }
        let fileVersion: UInt16 = try reader.readLE()

        switch fileVersion {
        case 5: return try decodeV5(payload: decompressPayload(&reader))
        case 4: return try decodeV4(payload: decompressPayload(&reader))
        case 3: return try decodeSingleLayer(payload: decompressPayload(&reader), hasFlags: true)
        case 2: return try decodeSingleLayer(payload: decompressPayload(&reader), hasFlags: false)
        case 1: return try decodeV1(payload: decompressPayload(&reader))
        default: throw CodecError.unsupportedVersion(fileVersion)
        }
    }

    /// v5 (incremental log): per-layer, strokes stored as one or more
    /// independently-compressed frames so a save can append only new strokes.
    private static func decodeV5(payload: Data) throws -> DrawingSession {
        var body = Reader(payload)
        let w: Float = try body.readLE()
        let h: Float = try body.readLE()
        let activeIndex = try body.readVarint()
        let layerCount = try body.readVarint()
        guard layerCount <= pointSanityLimit else { throw CodecError.implausibleCount }

        var layers: [Layer] = []
        layers.reserveCapacity(min(Int(layerCount), reserveCap))
        for _ in 0..<layerCount {
            let name = try readString(&body)
            let opacity: Float = try body.readLE()
            let isVisible = try body.readByte() != 0
            let frameCount = try body.readVarint()
            guard frameCount <= pointSanityLimit else { throw CodecError.implausibleCount }

            var strokes: [Stroke] = []
            for _ in 0..<frameCount {
                let len = try body.readVarint()
                guard len <= UInt64(Int.max) else { throw CodecError.truncated }
                let frame = try body.readBytes(Int(len))
                strokes.append(contentsOf: try decodeFrame(frame))
            }
            layers.append(Layer(name: name, strokes: strokes, opacity: sanitize(opacity, default: 1, min: 0, max: 1),
                                isVisible: isVisible))
        }
        return DrawingSession(canvasSize: sanitizedCanvas(w, h), layers: layers,
                              activeLayerIndex: Int(min(activeIndex, UInt64(Int.max))))
    }

    // MARK: - Frames (incremental)

    /// Encodes a run of strokes as a self-contained, optionally-LZFSE-compressed
    /// frame: `[algo UInt8][ (compressed) varint(strokeCount) + strokes ]`.
    static func encodeFrame<S: Sequence>(_ strokes: S, count: Int) -> Data where S.Element == Stroke {
        var raw = Data()
        raw.appendVarint(UInt64(count))
        for stroke in strokes { appendStroke(stroke, to: &raw) }

        var frame = Data()
        if let compressed = try? (raw as NSData).compressed(using: .lzfse), compressed.count < raw.count {
            frame.append(1)
            frame.append(compressed as Data)
        } else {
            frame.append(0)
            frame.append(raw)
        }
        return frame
    }

    private static func decodeFrame(_ frame: Data) throws -> [Stroke] {
        var reader = Reader(frame)
        let algorithm = try reader.readByte()
        let body: Data
        switch algorithm {
        case 0: body = try reader.remainder()
        case 1:
            let compressed = try reader.remainder()
            guard let raw = try? (compressed as NSData).decompressed(using: .lzfse) else {
                throw CodecError.decompressionFailed
            }
            body = raw as Data
        default: throw CodecError.decompressionFailed
        }
        var r = Reader(body)
        return try readStrokes(&r, hasFlags: true)
    }

    /// Assembles a v5 container from already-encoded per-layer frames.
    static func assembleV5(canvasSize: SIMD2<Float>, activeLayerIndex: Int,
                           layers: [(name: String, opacity: Float, isVisible: Bool, frames: [Data])]) -> Data {
        var payload = Data()
        payload.appendLE(canvasSize.x)
        payload.appendLE(canvasSize.y)
        payload.appendVarint(UInt64(max(activeLayerIndex, 0)))
        payload.appendVarint(UInt64(layers.count))
        for layer in layers {
            appendString(layer.name, to: &payload)
            payload.appendLE(layer.opacity)
            payload.append(layer.isVisible ? 1 : 0)
            payload.appendVarint(UInt64(layer.frames.count))
            for frame in layer.frames {
                payload.appendVarint(UInt64(frame.count))
                payload.append(frame)
            }
        }
        // Frames carry their own compression; the container is stored raw.
        return wrap(payload, version: 5, compress: false)
    }

    private static func decodeV4(payload: Data) throws -> DrawingSession {
        var body = Reader(payload)
        let w: Float = try body.readLE()
        let h: Float = try body.readLE()
        let activeIndex = try body.readVarint()
        let layerCount = try body.readVarint()
        guard layerCount <= pointSanityLimit else { throw CodecError.implausibleCount }

        var layers: [Layer] = []
        layers.reserveCapacity(min(Int(layerCount), reserveCap))
        for _ in 0..<layerCount {
            let name = try readString(&body)
            let opacity: Float = try body.readLE()
            let isVisible = try body.readByte() != 0
            let strokes = try readStrokes(&body, hasFlags: true)
            layers.append(Layer(name: name, strokes: strokes, opacity: sanitize(opacity, default: 1, min: 0, max: 1),
                                isVisible: isVisible))
        }
        return DrawingSession(canvasSize: sanitizedCanvas(w, h), layers: layers,
                              activeLayerIndex: Int(min(activeIndex, UInt64(Int.max))))
    }

    /// v2/v3: canvas + a single flat stroke block → one default layer.
    private static func decodeSingleLayer(payload: Data, hasFlags: Bool) throws -> DrawingSession {
        var body = Reader(payload)
        let w: Float = try body.readLE()
        let h: Float = try body.readLE()
        let strokes = try readStrokes(&body, hasFlags: hasFlags)
        return DrawingSession(canvasSize: sanitizedCanvas(w, h), strokes: strokes)
    }

    /// Reads a varint-prefixed run of delta-encoded strokes.
    private static func readStrokes(_ body: inout Reader, hasFlags: Bool) throws -> [Stroke] {
        let strokeCount = try body.readVarint()
        guard strokeCount <= pointSanityLimit else { throw CodecError.implausibleCount }
        var strokes: [Stroke] = []
        strokes.reserveCapacity(min(Int(strokeCount), reserveCap))
        for _ in 0..<strokeCount {
            let color = StrokeColor(
                r: try body.readByte(), g: try body.readByte(),
                b: try body.readByte(), a: try body.readByte()
            )
            let (blendMode, dynamics): (BlendMode, WidthDynamics) =
                hasFlags ? decodeFlags(try body.readByte()) : (.normal, .pressure)
            let brushSize = sanitize(try body.readLE(), default: 1, min: 0, max: maxCanvasDimension)
            let pointCount = try body.readVarint()
            guard pointCount <= pointSanityLimit else { throw CodecError.implausibleCount }

            var points = [StrokePoint]()
            points.reserveCapacity(min(Int(pointCount), reserveCap))
            var px: Int64 = 0, py: Int64 = 0, pt: Int64 = 0
            for _ in 0..<pointCount {
                // Wrapping add: hostile deltas can't overflow-trap; the result
                // stays a finite Int64 (→ finite Float below).
                px &+= try body.readZigzag()
                py &+= try body.readZigzag()
                let pressure = try body.readByte()
                pt &+= try body.readZigzag()
                // Values are integer-derived, so always finite — no sanitize needed.
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
        return strokes
    }

    // MARK: - String helpers

    private static func appendString(_ s: String, to payload: inout Data) {
        let bytes = Array(s.utf8)
        payload.appendVarint(UInt64(bytes.count))
        payload.append(contentsOf: bytes)
    }

    private static func readString(_ body: inout Reader) throws -> String {
        let count = try body.readVarint()
        guard count <= pointSanityLimit else { throw CodecError.implausibleCount }
        let bytes = try body.readBytes(Int(count))
        return String(decoding: bytes, as: UTF8.self)
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
        strokes.reserveCapacity(min(Int(strokeCount), reserveCap))

        for _ in 0..<strokeCount {
            let color = StrokeColor(
                r: try body.readByte(), g: try body.readByte(),
                b: try body.readByte(), a: try body.readByte()
            )
            let brushSize = sanitize(try body.readLE(), default: 1, min: 0, max: maxCanvasDimension)
            let pointCount: UInt32 = try body.readLE()
            guard UInt64(pointCount) <= pointSanityLimit else { throw CodecError.implausibleCount }

            // The bytes must actually be present, so this alloc is bounded by the
            // real blob size (no small-blob amplification).
            let byteCount = Int(pointCount) * legacyPointStride
            let pointBytes = try body.readBytes(byteCount)
            let raw = [StrokePoint](unsafeUninitializedCapacity: Int(pointCount)) { buffer, initialized in
                _ = pointBytes.copyBytes(to: buffer)
                initialized = Int(pointCount)
            }
            // v1 points are raw Float32 — sanitize NaN/Inf so downstream Int()
            // math can't trap.
            let points = raw.map {
                StrokePoint(x: sanitize($0.x, default: 0, min: -1e6, max: 1e6),
                            y: sanitize($0.y, default: 0, min: -1e6, max: 1e6),
                            pressure: sanitize($0.pressure, default: 1, min: 0, max: 1),
                            timestamp: sanitize($0.timestamp, default: 0, min: 0, max: 1e9))
            }
            strokes.append(Stroke(points: points, color: color, brushSize: brushSize))
        }
        return DrawingSession(canvasSize: sanitizedCanvas(w, h), strokes: strokes)
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
        guard p.isFinite else { return 255 }
        return UInt8((min(max(p, 0), 1) * 255).rounded())
    }

    /// Fixed-point encode of a coordinate/time, clamped so `Int64()` can't trap
    /// on NaN/Inf or huge finite values from a caller-built stroke.
    private static func fixed(_ v: Float, _ scale: Float) -> Int64 {
        let x = (v * scale).rounded()
        guard x.isFinite else { return 0 }
        let cap: Float = 1e15   // safely inside Int64 range
        return Int64(Swift.min(Swift.max(x, -cap), cap))
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
        let strokes = session.allStrokes   // v1 is flat — flatten every layer
        payload.appendLE(session.canvasSize.x)
        payload.appendLE(session.canvasSize.y)
        payload.appendLE(UInt32(strokes.count))
        for stroke in strokes {
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
        let strokes = session.allStrokes   // v2 is flat — flatten every layer
        payload.appendLE(session.canvasSize.x)
        payload.appendLE(session.canvasSize.y)
        payload.appendVarint(UInt64(strokes.count))
        for stroke in strokes {
            payload.append(contentsOf: [stroke.color.r, stroke.color.g, stroke.color.b, stroke.color.a])
            payload.appendLE(stroke.brushSize)
            payload.appendVarint(UInt64(stroke.points.count))
            var px: Int64 = 0, py: Int64 = 0, pt: Int64 = 0
            for point in stroke.points {
                let fx = fixed(point.x, coordScale)
                let fy = fixed(point.y, coordScale)
                let ft = fixed(point.timestamp, timeScale)
                payload.appendZigzag(fx &- px); payload.appendZigzag(fy &- py)
                payload.append(quantizePressure(point.pressure))
                payload.appendZigzag(ft &- pt)
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
