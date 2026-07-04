import XCTest
@testable import BlobCanvas

final class CodecTests: XCTestCase {

    private func makeSession(strokeCount: Int, pointsPerStroke: Int) -> DrawingSession {
        var session = DrawingSession(canvasSize: SIMD2(1024, 768))
        for s in 0..<strokeCount {
            var stroke = Stroke(
                color: StrokeColor(r: UInt8(s % 256), g: 128, b: 200, a: 255),
                brushSize: Float(s % 30) + 1
            )
            stroke.points.reserveCapacity(pointsPerStroke)
            for p in 0..<pointsPerStroke {
                stroke.append(StrokePoint(
                    x: Float(p) * 0.5 + Float(s),
                    y: sin(Float(p) * 0.1) * 100 + 384,
                    pressure: Float(p % 100) / 100 + 0.01,
                    timestamp: Float(p) / 120
                ))
            }
            session.commit(stroke)
        }
        return session
    }

    /// v2 quantizes points, so the round trip is lossy within one grid cell:
    /// 1/32 pt for coordinates, 1/255 for pressure, 1 ms for timestamps.
    /// Everything else must survive exactly.
    func testRoundTripWithinQuantizationTolerance() throws {
        let original = makeSession(strokeCount: 50, pointsPerStroke: 200)
        let blob = original.serialized()
        let decoded = try DrawingSession(serialized: blob)

        XCTAssertEqual(decoded.canvasSize, original.canvasSize)
        XCTAssertEqual(decoded.strokes.count, original.strokes.count)

        let coordTol: Float = 1 / 32 / 2 + 1e-4
        let pressureTol: Float = 1 / 255 / 2 + 1e-4
        let timeTol: Float = 1 / 1000 / 2 + 1e-4
        for (a, b) in zip(original.strokes, decoded.strokes) {
            XCTAssertEqual(a.color, b.color)
            XCTAssertEqual(a.brushSize, b.brushSize)
            XCTAssertEqual(a.points.count, b.points.count)
            for (p, q) in zip(a.points, b.points) {
                XCTAssertEqual(p.x, q.x, accuracy: coordTol)
                XCTAssertEqual(p.y, q.y, accuracy: coordTol)
                XCTAssertEqual(p.pressure, q.pressure, accuracy: pressureTol)
                XCTAssertEqual(p.timestamp, q.timestamp, accuracy: timeTol)
            }
        }
    }

    /// Once quantized, re-encoding must be byte-identical — proves the codec is
    /// a stable fixed point (no drift across repeated save cycles).
    func testReencodeIsStable() throws {
        let blob1 = makeSession(strokeCount: 20, pointsPerStroke: 100).serialized()
        let blob2 = try DrawingSession(serialized: blob1).serialized()
        XCTAssertEqual(blob1, blob2)
    }

    /// Legacy v1 blobs must still decode (migration path).
    func testDecodesLegacyV1() throws {
        let original = makeSession(strokeCount: 10, pointsPerStroke: 80)
        let v1Blob = DrawingBlobCodec.encodeLegacyV1(original)
        let decoded = try DrawingBlobCodec.decode(v1Blob)
        // v1 is lossless, so points match exactly.
        XCTAssertEqual(decoded.strokes, original.strokes)
    }

    /// Legacy v2 blobs (delta points, no flags) decode with default flags.
    func testDecodesLegacyV2() throws {
        let original = makeSession(strokeCount: 8, pointsPerStroke: 60)
        let v2Blob = DrawingBlobCodec.encodeLegacyV2(original)
        let decoded = try DrawingBlobCodec.decode(v2Blob)
        XCTAssertEqual(decoded.strokes.count, original.strokes.count)
        XCTAssertEqual(decoded.strokes.first?.blendMode, .normal)
        XCTAssertEqual(decoded.strokes.first?.dynamics, .pressure)
    }

    /// Blend mode and width dynamics survive the round trip (v3 flags byte).
    func testStrokeFlagsRoundTrip() throws {
        var session = DrawingSession(canvasSize: SIMD2(200, 200))
        session.commit(Stroke(points: [StrokePoint(x: 1 as Float, y: 2)], color: .black,
                              brushSize: 5, blendMode: .erase, dynamics: .velocity))
        session.commit(Stroke(points: [StrokePoint(x: 3 as Float, y: 4)], color: .white,
                              brushSize: 9, blendMode: .normal, dynamics: .constant))
        let decoded = try DrawingSession(serialized: session.serialized())
        XCTAssertEqual(decoded.strokes[0].blendMode, .erase)
        XCTAssertEqual(decoded.strokes[0].dynamics, .velocity)
        XCTAssertEqual(decoded.strokes[1].blendMode, .normal)
        XCTAssertEqual(decoded.strokes[1].dynamics, .constant)
    }

    /// Delta+varint must beat raw Float32 storage. Compare uncompressed
    /// payloads on a random-walk stroke (realistic small deltas).
    func testDeltaEncodingIsSmallerThanRaw() {
        var session = DrawingSession(canvasSize: SIMD2(1024, 768))
        var stroke = Stroke(color: .black, brushSize: 6)
        var x: Float = 500, y: Float = 400
        var rng = SystemRandomNumberGenerator()
        for i in 0..<2000 {
            x += Float(Int(rng.next() % 7)) - 3
            y += Float(Int(rng.next() % 7)) - 3
            stroke.append(StrokePoint(x: x, y: y, pressure: 0.8, timestamp: Float(i) / 120))
        }
        session.commit(stroke)

        let v2 = DrawingBlobCodec.encode(session, compress: false).count
        let v1 = DrawingBlobCodec.encodeLegacyV1(session, compress: false).count
        XCTAssertLessThan(v2, v1)
        XCTAssertLessThan(v2, v1 / 2) // expect well over 2× on small-delta input
    }

    func testEmptySessionRoundTrip() throws {
        let blob = DrawingSession().serialized()
        let decoded = try DrawingSession(serialized: blob)
        XCTAssertTrue(decoded.strokes.isEmpty)
    }

    func testCompressionShrinksBlob() {
        let session = makeSession(strokeCount: 50, pointsPerStroke: 200)
        let compressed = DrawingBlobCodec.encode(session, compress: true)
        let raw = DrawingBlobCodec.encode(session, compress: false)
        XCTAssertLessThan(compressed.count, raw.count)
    }

    func testRejectsGarbage() {
        XCTAssertThrowsError(try DrawingBlobCodec.decode(Data([1, 2, 3])))
        XCTAssertThrowsError(try DrawingBlobCodec.decode(Data("not a drawing".utf8)))
    }

    func testTruncatedBlobThrows() {
        let blob = makeSession(strokeCount: 5, pointsPerStroke: 50).serialized()
        XCTAssertThrowsError(try DrawingBlobCodec.decode(blob.prefix(blob.count / 2)))
    }

    /// A blob whose header declares an absurd stroke count must be rejected
    /// before it drives a huge allocation.
    func testImplausibleCountRejected() {
        // Build a minimal valid v4 header, then an inner payload with a bogus
        // (varint) layer count.
        var payload = Data()
        payload.appendLE(Float(100))                  // canvasW
        payload.appendLE(Float(100))                  // canvasH
        payload.appendVarint(0)                       // activeLayerIndex
        payload.appendVarint(UInt64.max)              // layerCount — absurd

        var blob = Data()
        blob.append(contentsOf: DrawingBlobCodec.magic)
        blob.appendLE(DrawingBlobCodec.version)
        blob.append(0)                                // algorithm: raw
        blob.append(payload)

        XCTAssertThrowsError(try DrawingBlobCodec.decode(blob)) { error in
            XCTAssertEqual(error as? DrawingBlobCodec.CodecError, .implausibleCount)
        }
    }

    func testEncodePerformance10kPoints() {
        let session = makeSession(strokeCount: 50, pointsPerStroke: 200)
        measure {
            _ = session.serialized()
        }
    }
}

final class UndoRedoTests: XCTestCase {

    private func stroke(_ n: Int) -> Stroke {
        Stroke(points: [StrokePoint(x: Float(n), y: Float(n))])
    }

    func testUndoRedo() {
        var session = DrawingSession()
        session.commit(stroke(1))
        session.commit(stroke(2))
        session.commit(stroke(3))

        XCTAssertTrue(session.canUndo)
        XCTAssertFalse(session.canRedo)

        XCTAssertTrue(session.undo())
        XCTAssertEqual(session.strokes.count, 2)
        XCTAssertTrue(session.canRedo)

        XCTAssertTrue(session.redo())
        XCTAssertEqual(session.strokes.count, 3)
        XCTAssertEqual(session.strokes.last, stroke(3))
    }

    func testCommitClearsRedoStack() {
        var session = DrawingSession()
        session.commit(stroke(1))
        session.commit(stroke(2))
        session.undo()
        session.commit(stroke(9))

        XCTAssertFalse(session.canRedo)
        XCTAssertFalse(session.redo())
        XCTAssertEqual(session.strokes.map(\.points[0].x), [1, 9])
    }

    func testUndoOnEmptyIsNoop() {
        var session = DrawingSession()
        XCTAssertFalse(session.undo())
        XCTAssertFalse(session.redo())
    }

    func testEmptyStrokeIsNotCommitted() {
        var session = DrawingSession()
        session.commit(Stroke())
        XCTAssertFalse(session.canUndo)
    }
}
