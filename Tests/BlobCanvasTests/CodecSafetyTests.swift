import XCTest
@testable import BlobCanvas

/// Hardening tests: a public `decode` accepts arbitrary bytes, so hostile input
/// must never trap (NaN→Int), OOM (amplified counts), or over-read.
final class CodecSafetyTests: XCTestCase {

    /// Builds a minimal v4 container around a raw payload.
    private func v4(_ payload: Data) -> Data {
        var blob = Data()
        blob.append(contentsOf: DrawingBlobCodec.magic)
        blob.appendLE(DrawingBlobCodec.version)  // 4
        blob.append(0)                            // algorithm: raw
        blob.append(payload)
        return blob
    }

    /// A NaN/Inf canvas size must be sanitized so downstream `Int(Float)` render
    /// math can't crash.
    func testNaNCanvasSizeIsSanitized() throws {
        var payload = Data()
        payload.appendLE(Float.nan)              // canvasW
        payload.appendLE(Float.infinity)         // canvasH
        payload.appendVarint(0)                  // activeLayer
        payload.appendVarint(0)                  // layerCount (empty)

        let session = try DrawingBlobCodec.decode(v4(payload))
        XCTAssertTrue(session.canvasSize.x.isFinite && session.canvasSize.y.isFinite)
        XCTAssertGreaterThanOrEqual(session.canvasSize.x, 1)
        // Rendering the sanitized session must not trap.
        XCTAssertNotNil(StrokeRasterizer.makeImage(session, scale: 1))
    }

    /// A tiny blob claiming billions of strokes must fail fast without a giant
    /// eager allocation.
    func testAmplifiedStrokeCountDoesNotOOM() {
        var payload = Data()
        payload.appendLE(Float(100))             // canvasW
        payload.appendLE(Float(100))             // canvasH
        payload.appendVarint(0)                  // activeLayer
        payload.appendVarint(1)                  // 1 layer
        payload.appendVarint(0)                  // name length 0
        payload.appendLE(Float(1))               // opacity
        payload.append(1)                        // visible
        payload.appendVarint(1_000_000_000)      // strokeCount — above the sanity limit
        let result = try? DrawingBlobCodec.decode(v4(payload))
        XCTAssertNil(result)                     // rejected (implausibleCount) — never OOM/crash
    }

    /// A stroke count within the sanity limit but with no backing data must
    /// throw truncated quickly (capped reserve, not a gigabyte pre-alloc).
    func testUnbackedCountThrowsFast() {
        var payload = Data()
        payload.appendLE(Float(100)); payload.appendLE(Float(100))
        payload.appendVarint(0)                  // activeLayer
        payload.appendVarint(1)                  // 1 layer
        payload.appendVarint(0)                  // name len 0
        payload.appendLE(Float(1)); payload.append(1)
        payload.appendVarint(50_000_000)         // < 64M limit, but no strokes follow
        XCTAssertThrowsError(try DrawingBlobCodec.decode(v4(payload)))
    }

    /// A v5 frame length near UInt64.max must not trap on `Int(len)`.
    func testHugeFrameLengthRejected() {
        var payload = Data()
        payload.appendLE(Float(100)); payload.appendLE(Float(100))
        payload.appendVarint(0)                  // activeLayer
        payload.appendVarint(1)                  // 1 layer
        payload.appendVarint(0)                  // name len 0
        payload.appendLE(Float(1)); payload.append(1)
        payload.appendVarint(1)                  // frameCount 1
        payload.appendVarint(UInt64.max)         // frame length — absurd

        var blob = Data()
        blob.append(contentsOf: DrawingBlobCodec.magic)
        blob.appendLE(UInt16(5))                 // version 5
        blob.append(0)                           // raw
        blob.append(payload)
        XCTAssertThrowsError(try DrawingBlobCodec.decode(blob))
    }

    /// A stroke with a NaN brush size (built in code, not decoded) must render
    /// without trapping in either backend.
    func testNaNBrushSizeRendersSafely() {
        var session = DrawingSession(canvasSize: SIMD2(50, 50))
        session.commit(Stroke(points: [StrokePoint(x: 10 as Float, y: 25), StrokePoint(x: 40 as Float, y: 25)],
                              color: .black, brushSize: .nan))
        XCTAssertNotNil(StrokeRasterizer.makeImage(session, scale: 1))
        if let metal = MetalSessionRenderer.shared {
            XCTAssertNotNil(metal.makeImage(session, scale: 1))
        }
    }

    /// Encoding a stroke with NaN/Inf coordinates/pressure must not trap
    /// (`Int64(NaN)` / `UInt8(NaN)`), and must round-trip to a finite stroke.
    func testEncodingNonFiniteStrokeDoesNotTrap() throws {
        var session = DrawingSession(canvasSize: SIMD2(100, 100))
        session.commit(Stroke(points: [
            StrokePoint(x: Float.nan, y: Float.infinity, pressure: Float.nan, timestamp: -Float.infinity),
            StrokePoint(x: 1e30 as Float, y: 50, pressure: 2, timestamp: 0)
        ], color: .black, brushSize: 5))

        let blob = session.serialized()                 // must not crash
        let decoded = try DrawingSession(serialized: blob)
        for p in decoded.strokes[0].points {
            XCTAssertTrue(p.x.isFinite && p.y.isFinite && p.pressure.isFinite && p.timestamp.isFinite)
        }
    }

    /// Hostile zig-zag deltas that overflow the Int64 accumulator must wrap, not
    /// trap, and still yield a finite session.
    func testAccumulatorOverflowDoesNotTrap() throws {
        var payload = Data()
        payload.appendLE(Float(100)); payload.appendLE(Float(100))
        payload.appendVarint(2)                          // 2 strokes... (v2 layout: strokeCount)
        // stroke 0: color + brush + 3 points each with a max-magnitude delta
        func appendStroke() {
            payload.append(contentsOf: [0, 0, 0, 255])   // rgba
            payload.appendLE(Float(4))                   // brushSize
            payload.appendVarint(3)                      // pointCount
            for _ in 0..<3 {
                payload.appendZigzag(Int64.max)          // Δx — repeated adds overflow
                payload.appendZigzag(Int64.max)          // Δy
                payload.append(200)                      // pressure
                payload.appendZigzag(1)                  // Δt
            }
        }
        appendStroke(); appendStroke()

        var blob = Data()
        blob.append(contentsOf: DrawingBlobCodec.magic)
        blob.appendLE(UInt16(2))                         // v2 (delta, no flags)
        blob.append(0)                                   // raw
        blob.append(payload)

        let session = try DrawingBlobCodec.decode(blob)  // must not trap
        for p in session.strokes[0].points {
            XCTAssertTrue(p.x.isFinite && p.y.isFinite)
        }
    }

    /// A directly-constructed NaN canvas size must not crash the raster path.
    func testNaNCanvasSizeInAPIDoesNotCrash() {
        let session = DrawingSession(canvasSize: SIMD2(.nan, 100))
        // pixelDimension clamps NaN → 1; makeImage returns a valid tiny image.
        let image = StrokeRasterizer.makeImage(session, scale: 1)
        XCTAssertNotNil(image)
        XCTAssertGreaterThanOrEqual(image!.width, 1)
    }
}
