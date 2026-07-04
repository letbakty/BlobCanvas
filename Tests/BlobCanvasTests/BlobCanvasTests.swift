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

    func testRoundTrip() throws {
        let original = makeSession(strokeCount: 50, pointsPerStroke: 200)
        let blob = original.serialized()
        let decoded = try DrawingSession(serialized: blob)

        XCTAssertEqual(decoded.canvasSize, original.canvasSize)
        XCTAssertEqual(decoded.strokes, original.strokes)
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
