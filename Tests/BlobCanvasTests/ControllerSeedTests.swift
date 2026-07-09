import XCTest
@testable import BlobCanvas

/// Fix #3: opening a drawing must seed the controller's mirrored UI state
/// (layers, canUndo) *without* firing the autosave callback.
@MainActor
final class ControllerSeedTests: XCTestCase {

    private func stroke(x: Float) -> Stroke {
        Stroke(points: [StrokePoint(x: x, y: 10), StrokePoint(x: x + 10, y: 20)],
               color: .black, brushSize: 6)
    }

    func testLoadingSeedsMirrorStateWithoutFiringChange() {
        let controller = BlobCanvasController()
        var changeCount = 0
        controller.onSessionChanged = { _ in changeCount += 1 }

        var session = DrawingSession(canvasSize: SIMD2(200, 200))
        session.commit(stroke(x: 10))          // layer 0
        session.addLayer(name: "Second")       // active → 1
        session.commit(stroke(x: 30))          // layer 1 has a stroke

        let view = BlobCanvasView(controller: controller, session: session)
        _ = view.makeEngineView()

        XCTAssertEqual(controller.layers.count, 2, "layer panel should reflect the loaded session")
        XCTAssertEqual(controller.activeLayerIndex, 1)
        XCTAssertTrue(controller.canUndo, "undo should be enabled for a loaded drawing with strokes")
        XCTAssertEqual(changeCount, 0, "opening a drawing must not fire the autosave callback")
    }

    /// A real edit still fires the callback exactly once.
    func testEditAfterSeedFiresChange() {
        let controller = BlobCanvasController()
        var changeCount = 0
        controller.onSessionChanged = { _ in changeCount += 1 }

        let view = BlobCanvasView(controller: controller)
        let engine = view.makeEngineView()
        XCTAssertEqual(changeCount, 0)

        engine._commitStrokeForTesting(stroke(x: 5))
        XCTAssertEqual(changeCount, 1)
        XCTAssertTrue(controller.canUndo)
    }
}
