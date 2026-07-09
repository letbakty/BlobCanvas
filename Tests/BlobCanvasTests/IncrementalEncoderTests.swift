import XCTest
@testable import BlobCanvas

final class IncrementalEncoderTests: XCTestCase {

    private func stroke(_ n: Int, points: Int = 20) -> Stroke {
        var s = Stroke(color: StrokeColor(r: UInt8(n % 256), g: 100, b: 50), brushSize: Float(n % 10 + 1))
        for p in 0..<points {
            s.append(StrokePoint(x: Float(n * 3 + p), y: Float(50 + (p % 7)), timestamp: Float(p) / 60))
        }
        return s
    }

    /// A sequence of incremental saves must decode to the same drawing as a
    /// single one-shot encode of the final state.
    func testIncrementalMatchesOneShot() throws {
        let encoder = IncrementalDrawingEncoder()
        var session = DrawingSession(canvasSize: SIMD2(500, 400))

        var lastBlob = Data()
        for n in 0..<25 {
            session.commit(stroke(n))
            lastBlob = encoder.encode(session)   // append save each stroke
        }

        let incremental = try DrawingSession(serialized: lastBlob)
        let oneShot = try DrawingSession(serialized: session.serialized())
        XCTAssertEqual(incremental.strokes.count, oneShot.strokes.count)
        XCTAssertEqual(incremental.strokes.count, 25)
        XCTAssertEqual(incremental.strokes, oneShot.strokes) // both are quantized identically
    }

    func testAppendThenUndoRecompacts() throws {
        let encoder = IncrementalDrawingEncoder()
        var session = DrawingSession(canvasSize: SIMD2(300, 300))
        for n in 0..<10 { session.commit(stroke(n)) }
        _ = encoder.encode(session)

        session.undo()
        session.undo()
        let blob = encoder.encode(session)

        let decoded = try DrawingSession(serialized: blob)
        let oneShot = try DrawingSession(serialized: session.serialized())
        XCTAssertEqual(decoded.strokes.count, 8)
        XCTAssertEqual(decoded.strokes, oneShot.strokes) // both quantized identically
    }

    func testMultiLayerIncremental() throws {
        let encoder = IncrementalDrawingEncoder()
        var session = DrawingSession(canvasSize: SIMD2(400, 400))
        session.commit(stroke(1))
        _ = encoder.encode(session)

        session.addLayer(name: "Second")
        session.commit(stroke(2))
        session.commit(stroke(3))
        let blob = encoder.encode(session)

        let decoded = try DrawingSession(serialized: blob)
        XCTAssertEqual(decoded.layers.count, 2)
        XCTAssertEqual(decoded.layers[0].strokes.count, 1)
        XCTAssertEqual(decoded.layers[1].strokes.count, 2)
        XCTAssertEqual(decoded.layers[1].name, "Second")
        XCTAssertEqual(decoded.activeLayerIndex, 1)
    }

    /// Reordering layers must not corrupt the blob — frames are keyed by layer
    /// identity, not index (index-keying would swap the wrong frames).
    func testReorderLayersStaysCorrect() throws {
        let encoder = IncrementalDrawingEncoder(sealThreshold: 4)
        var session = DrawingSession(canvasSize: SIMD2(300, 300))
        for n in 0..<10 { session.commit(stroke(n)) }           // layer 0: 10 strokes
        session.addLayer(name: "Top")
        for n in 100..<103 { session.commit(stroke(n)) }        // layer 1: 3 strokes
        _ = encoder.encode(session)                             // seals frames per layer

        session.moveLayer(from: 0, to: 1)                       // swap order
        let blob = encoder.encode(session)

        let decoded = try DrawingSession(serialized: blob)
        let oneShot = try DrawingSession(serialized: session.serialized())
        XCTAssertEqual(decoded.layers.map(\.name), ["Top", "Layer 1"])
        XCTAssertEqual(decoded.layers[0].strokes, oneShot.layers[0].strokes)
        XCTAssertEqual(decoded.layers[1].strokes, oneShot.layers[1].strokes)
    }

    /// Regression: undo past the seal boundary followed by NEW strokes can bring
    /// the count back to `sealedCount` between saves. The stale sealed frame
    /// must be detected (boundary stroke changed) and rebuilt — otherwise the
    /// save silently keeps the undone stroke and loses the new one.
    func testUndoRedrawSameCountRebuildsSealedFrames() throws {
        let encoder = IncrementalDrawingEncoder(sealThreshold: 4)
        var session = DrawingSession(canvasSize: SIMD2(300, 300))
        for n in 0..<4 { session.commit(stroke(n)) }
        _ = encoder.encode(session)                 // seals strokes 0-3

        session.undo()                              // count 3 — no save in between
        session.commit(stroke(99))                  // count back to 4, different stroke

        let decoded = try DrawingSession(serialized: encoder.encode(session))
        let oneShot = try DrawingSession(serialized: session.serialized())
        XCTAssertEqual(decoded.strokes, oneShot.strokes)
        XCTAssertEqual(decoded.strokes.last?.color, stroke(99).color)
    }

    /// Redo restores the identical stroke — sealed frames stay valid and must
    /// NOT be rebuilt (that's the fast path working as intended).
    func testUndoRedoKeepsSealedFrames() throws {
        let encoder = IncrementalDrawingEncoder(sealThreshold: 4)
        var session = DrawingSession(canvasSize: SIMD2(300, 300))
        for n in 0..<4 { session.commit(stroke(n)) }
        _ = encoder.encode(session)

        session.undo()
        session.redo()                              // same stroke back

        let decoded = try DrawingSession(serialized: encoder.encode(session))
        XCTAssertEqual(decoded.strokes, try DrawingSession(serialized: session.serialized()).strokes)
    }

    func testResetForcesFullReencode() throws {
        let encoder = IncrementalDrawingEncoder()
        var session = DrawingSession()
        for n in 0..<5 { session.commit(stroke(n)) }
        _ = encoder.encode(session)
        encoder.reset()
        let blob = encoder.encode(session)
        XCTAssertEqual(try DrawingSession(serialized: blob).strokes.count, 5)
    }

    /// Chunk sealing keeps the blob within a small multiple of a one-shot
    /// encode even after many incremental saves.
    func testIncrementalBlobStaysReasonable() {
        let encoder = IncrementalDrawingEncoder(sealThreshold: 48)
        var session = DrawingSession(canvasSize: SIMD2(500, 500))
        for n in 0..<200 {
            session.commit(stroke(n, points: 30))
            _ = encoder.encode(session)   // save after every stroke
        }
        let incremental = encoder.encode(session).count
        let oneShot = session.serialized().count
        // Sealed frames compress in 48-stroke chunks — less optimal than one
        // whole-payload pass, but bounded. (Synthetic self-similar strokes
        // compress unusually well one-shot, so allow generous headroom.)
        XCTAssertLessThan(incremental, oneShot * 4)
    }

    /// Sealing must not re-encode already-sealed strokes: a second save that
    /// adds one stroke to a large drawing touches only the open tail.
    func testSealedFramesAreReused() {
        let encoder = IncrementalDrawingEncoder(sealThreshold: 16)
        var session = DrawingSession(canvasSize: SIMD2(400, 400))
        for n in 0..<100 { session.commit(stroke(n)); _ = encoder.encode(session) }
        let before = encoder.encode(session)
        session.commit(stroke(100))
        let after = encoder.encode(session)
        // The blob grew by roughly one stroke's worth, not a full re-encode.
        XCTAssertGreaterThan(after.count, before.count)
        XCTAssertLessThan(after.count - before.count, 400)
    }
}
