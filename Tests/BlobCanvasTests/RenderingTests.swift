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
