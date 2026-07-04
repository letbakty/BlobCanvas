import XCTest
import CoreGraphics
@testable import BlobCanvas

/// End-to-end verification that the O(1) undo checkpoint restores the exact
/// pre-stroke pixels (not just the right session state).
final class EngineCheckpointTests: XCTestCase {

    private func line(_ color: StrokeColor, y: Float) -> Stroke {
        Stroke(points: [StrokePoint(x: 10 as Float, y: y), StrokePoint(x: 90 as Float, y: y)],
               color: color, brushSize: 8)
    }

    /// Counts roughly-red and roughly-blue opaque pixels (orientation-agnostic).
    private func colorCounts(_ image: CGImage) -> (red: Int, blue: Int) {
        let w = image.width, h = image.height
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        var red = 0, blue = 0
        for i in stride(from: 0, to: buf.count, by: 4) {
            let r = buf[i], g = buf[i + 1], b = buf[i + 2], a = buf[i + 3]
            guard a > 128 else { continue }
            if r > 150, g < 100, b < 100 { red += 1 }
            if b > 150, r < 100, g < 100 { blue += 1 }
        }
        return (red, blue)
    }

    func testUndoCheckpointRestoresExactPixels() {
        let view = CanvasEngineView(frame: CGRect(x: 0, y: 0, width: 100, height: 80))
        view.load(DrawingSession(canvasSize: SIMD2(100, 80)))
        view.undoCheckpointDepth = 4

        view._commitStrokeForTesting(line(StrokeColor(r: 255, g: 0, b: 0), y: 20))   // red
        let afterRed = colorCounts(view._committedImageForTesting()!)
        XCTAssertGreaterThan(afterRed.red, 50)
        XCTAssertEqual(afterRed.blue, 0)

        view._commitStrokeForTesting(line(StrokeColor(r: 0, g: 0, b: 255), y: 60))   // blue
        let afterBlue = colorCounts(view._committedImageForTesting()!)
        XCTAssertGreaterThan(afterBlue.blue, 50)

        XCTAssertTrue(view.undo())   // O(1) checkpoint restore
        let afterUndo = colorCounts(view._committedImageForTesting()!)
        XCTAssertEqual(afterUndo.blue, 0, "blue stroke should be gone")
        // Red pixels restored to (near) exactly the pre-blue count.
        XCTAssertEqual(afterUndo.red, afterRed.red, accuracy: 4)
    }

    func testRedoAfterCheckpointUndo() {
        let view = CanvasEngineView(frame: CGRect(x: 0, y: 0, width: 100, height: 80))
        view.load(DrawingSession(canvasSize: SIMD2(100, 80)))
        view.undoCheckpointDepth = 4

        view._commitStrokeForTesting(line(StrokeColor(r: 255, g: 0, b: 0), y: 20))
        view._commitStrokeForTesting(line(StrokeColor(r: 0, g: 0, b: 255), y: 60))
        XCTAssertTrue(view.undo())
        XCTAssertTrue(view.redo())
        let counts = colorCounts(view._committedImageForTesting()!)
        XCTAssertGreaterThan(counts.red, 50)
        XCTAssertGreaterThan(counts.blue, 50)
    }
}
