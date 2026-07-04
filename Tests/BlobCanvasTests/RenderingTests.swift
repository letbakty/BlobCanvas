import XCTest
import CoreGraphics
@testable import BlobCanvas

final class RasterizerTests: XCTestCase {

    /// Reads one pixel (premultiplied RGBA) by drawing the image into a known
    /// context. The image's y is flipped here, so probe symmetric locations.
    private func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        let w = image.width, h = image.height
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let i = (y * w + x) * 4
        return (buf[i], buf[i + 1], buf[i + 2], buf[i + 3])
    }

    private func horizontalLine(color: StrokeColor, brushSize: Float, blendMode: BlendMode = .normal) -> Stroke {
        Stroke(points: [StrokePoint(x: 10 as Float, y: 50), StrokePoint(x: 90 as Float, y: 50)],
               color: color, brushSize: brushSize, blendMode: blendMode)
    }

    func testStrokePaintsPixels() {
        var session = DrawingSession(canvasSize: SIMD2(100, 100))
        session.commit(horizontalLine(color: StrokeColor(r: 255, g: 0, b: 0), brushSize: 12))
        let image = StrokeRasterizer.makeImage(session, scale: 1)!

        let center = pixel(image, 50, 50)
        XCTAssertGreaterThan(center.r, 200)
        XCTAssertGreaterThan(center.a, 200)

        let corner = pixel(image, 3, 3)
        XCTAssertLessThan(corner.a, 20) // transparent away from the stroke
    }

    func testEraserClearsPixels() {
        var session = DrawingSession(canvasSize: SIMD2(100, 100))
        session.commit(horizontalLine(color: StrokeColor(r: 255, g: 0, b: 0), brushSize: 24))
        session.commit(horizontalLine(color: .black, brushSize: 24, blendMode: .erase))
        let image = StrokeRasterizer.makeImage(session, scale: 1)!

        XCTAssertLessThan(pixel(image, 50, 50).a, 20) // erased back to transparent
    }

    func testBackgroundFills() {
        let session = DrawingSession(canvasSize: SIMD2(20, 20))
        let image = StrokeRasterizer.makeImage(session, scale: 1, background: StrokeColor(r: 0, g: 0, b: 255))!
        let p = pixel(image, 10, 10)
        XCTAssertGreaterThan(p.b, 200)
        XCTAssertGreaterThan(p.a, 200)
    }

    func testScaleProducesLargerImage() {
        let session = DrawingSession(canvasSize: SIMD2(50, 40))
        let image = StrokeRasterizer.makeImage(session, scale: 3)!
        XCTAssertEqual(image.width, 150)
        XCTAssertEqual(image.height, 120)
    }
}

final class LayerTests: XCTestCase {

    private func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        let w = image.width, h = image.height
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let i = (y * w + x) * 4
        return (buf[i], buf[i + 1], buf[i + 2], buf[i + 3])
    }

    func testLayersRoundTrip() throws {
        var session = DrawingSession(canvasSize: SIMD2(200, 150))
        session.commit(Stroke(points: [StrokePoint(x: 10 as Float, y: 10)], color: .black, brushSize: 5))
        session.addLayer(name: "Ink")
        session.setOpacity(0.5, ofLayer: 1)
        session.commit(Stroke(points: [StrokePoint(x: 20 as Float, y: 20)], color: .white, brushSize: 7))

        let decoded = try DrawingSession(serialized: session.serialized())
        XCTAssertEqual(decoded.layers.count, 2)
        XCTAssertEqual(decoded.layers[1].name, "Ink")
        XCTAssertEqual(decoded.layers[1].opacity, 0.5, accuracy: 1e-6)
        XCTAssertEqual(decoded.activeLayerIndex, 1)
    }

    func testHiddenLayerNotRendered() {
        var session = DrawingSession(canvasSize: SIMD2(60, 60))
        session.commit(Stroke(points: [StrokePoint(x: 5 as Float, y: 30), StrokePoint(x: 55 as Float, y: 30)],
                              color: StrokeColor(r: 255, g: 0, b: 0), brushSize: 20))
        session.setVisible(false, ofLayer: 0)
        let image = StrokeRasterizer.makeImage(session, scale: 1)!
        XCTAssertLessThan(pixel(image, 30, 30).a, 20) // nothing drawn
    }

    func testLayerOpacityHalvesAlpha() {
        var session = DrawingSession(canvasSize: SIMD2(60, 60))
        session.commit(Stroke(points: [StrokePoint(x: 5 as Float, y: 30), StrokePoint(x: 55 as Float, y: 30)],
                              color: StrokeColor(r: 0, g: 0, b: 0), brushSize: 30))
        session.setOpacity(0.5, ofLayer: 0)
        let image = StrokeRasterizer.makeImage(session, scale: 1, background: nil)!
        let a = pixel(image, 30, 30).a
        XCTAssertGreaterThan(a, 100) // ~half of 255
        XCTAssertLessThan(a, 160)
    }

    func testUndoIsPerActiveLayer() {
        var session = DrawingSession(canvasSize: SIMD2(50, 50))
        session.commit(Stroke(points: [StrokePoint(x: 1 as Float, y: 1)]))
        session.addLayer()
        session.commit(Stroke(points: [StrokePoint(x: 2 as Float, y: 2)]))
        XCTAssertTrue(session.undo())              // undoes layer 2's stroke
        XCTAssertTrue(session.layers[1].strokes.isEmpty)
        XCTAssertEqual(session.layers[0].strokes.count, 1) // layer 1 untouched
    }
}

final class CanvasViewportTests: XCTestCase {

    func testFitCentersSquareInWideView() {
        let vp = CanvasViewport(canvasSize: CGSize(width: 100, height: 100),
                                viewBounds: CGSize(width: 300, height: 100))
        XCTAssertEqual(vp.scale, 1, accuracy: 1e-6)          // fits by height
        XCTAssertEqual(vp.origin.x, 100, accuracy: 1e-6)     // centered horizontally
        XCTAssertEqual(vp.origin.y, 0, accuracy: 1e-6)
    }

    func testRoundTripMapping() {
        let vp = CanvasViewport(canvasSize: CGSize(width: 200, height: 150),
                                viewBounds: CGSize(width: 400, height: 400), zoom: 2)
        let canvasPoint = CGPoint(x: 73, y: 40)
        let view = vp.canvasToView(canvasPoint)
        let back = vp.viewToCanvas(view, clamped: false)
        XCTAssertEqual(back.x, canvasPoint.x, accuracy: 1e-4)
        XCTAssertEqual(back.y, canvasPoint.y, accuracy: 1e-4)
    }

    func testZoomKeepsFocalPointFixed() {
        var vp = CanvasViewport(canvasSize: CGSize(width: 100, height: 100),
                                viewBounds: CGSize(width: 100, height: 100))
        let focal = CGPoint(x: 25, y: 25)
        let before = vp.viewToCanvas(focal, clamped: false)
        vp.zoom(by: 3, at: focal)
        let after = vp.viewToCanvas(focal, clamped: false)
        XCTAssertEqual(before.x, after.x, accuracy: 1e-3)
        XCTAssertEqual(before.y, after.y, accuracy: 1e-3)
    }

    func testZoomClampedToRange() {
        var vp = CanvasViewport(canvasSize: CGSize(width: 100, height: 100),
                                viewBounds: CGSize(width: 100, height: 100),
                                minZoom: 1, maxZoom: 4)
        vp.zoom(by: 100, at: .zero)
        XCTAssertEqual(vp.zoom, 4, accuracy: 1e-6)
        vp.zoom(by: 0.001, at: .zero)
        XCTAssertEqual(vp.zoom, 1, accuracy: 1e-6)
    }

    func testPanIgnoredWhenNotZoomed() {
        var vp = CanvasViewport(canvasSize: CGSize(width: 100, height: 100),
                                viewBounds: CGSize(width: 100, height: 100))
        vp.translate(by: CGPoint(x: 50, y: 50))
        XCTAssertEqual(vp.pan, .zero) // clamped back — nothing to pan at fit
    }
}

final class ExporterTests: XCTestCase {

    private func sampleSession() -> DrawingSession {
        var session = DrawingSession(canvasSize: SIMD2(120, 90))
        session.commit(Stroke(points: [StrokePoint(x: 10 as Float, y: 10), StrokePoint(x: 100 as Float, y: 80)],
                              color: StrokeColor(r: 20, g: 120, b: 220), brushSize: 8))
        return session
    }

    func testPNGHasSignature() throws {
        let data = try XCTUnwrap(DrawingExporter.pngData(sampleSession(), scale: 1))
        XCTAssertEqual(Array(data.prefix(4)), [0x89, 0x50, 0x4E, 0x47]) // ‰PNG
    }

    func testPDFHasHeader() throws {
        let data = try XCTUnwrap(DrawingExporter.pdfData(sampleSession()))
        XCTAssertEqual(String(bytes: data.prefix(4), encoding: .ascii), "%PDF")
    }

    func testSVGStructure() {
        let svg = DrawingExporter.svgString(sampleSession(), background: .white)
        XCTAssertTrue(svg.contains("<svg"))
        XCTAssertTrue(svg.contains("<path"))
        XCTAssertTrue(svg.contains("viewBox=\"0 0 120.00 90.00\""))
    }

    func testThumbnailFitsMaxDimension() throws {
        let data = try XCTUnwrap(DrawingExporter.thumbnailPNG(sampleSession(), maxDimension: 60))
        let src = CGImageSourceCreateWithData(data as CFData, nil)!
        let image = CGImageSourceCreateImageAtIndex(src, 0, nil)!
        XCTAssertLessThanOrEqual(max(image.width, image.height), 60)
    }
}

final class DrawingPlayerTests: XCTestCase {

    private func timedSession() -> DrawingSession {
        var session = DrawingSession(canvasSize: SIMD2(100, 100))
        for s in 0..<3 {
            var stroke = Stroke(brushSize: 5)
            for p in 0..<20 {
                stroke.append(StrokePoint(x: Float(p) + Float(s) * 10, y: 50, timestamp: Float(p) / 60))
            }
            session.commit(stroke)
        }
        return session
    }

    func testEmptyAtStartFullAtEnd() {
        let player = DrawingPlayer(timedSession())
        XCTAssertTrue(player.snapshot(at: 0).strokes.isEmpty)
        XCTAssertEqual(player.snapshot(at: player.duration + 1).strokes.count, 3)
        XCTAssertGreaterThan(player.duration, 0)
    }

    func testProgressIsMonotonic() {
        let session = timedSession()
        let player = DrawingPlayer(session)
        var lastPoints = -1
        for step in 0...20 {
            let t = player.duration * Double(step) / 20
            let points = player.snapshot(at: t).pointCount
            XCTAssertGreaterThanOrEqual(points, lastPoints)
            lastPoints = points
        }
        XCTAssertEqual(player.snapshot(at: player.duration + 1).pointCount, session.pointCount)
    }
}
