import XCTest
import CoreGraphics
@testable import BlobCanvas

final class MetalRendererTests: XCTestCase {

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

    private func makeRenderer() throws -> MetalSessionRenderer {
        try XCTSkipIf(MetalSessionRenderer() == nil, "No Metal device available on this host")
        return MetalSessionRenderer()!
    }

    func testMetalPaintsStrokePixels() throws {
        let renderer = try makeRenderer()
        var session = DrawingSession(canvasSize: SIMD2(100, 100))
        session.commit(Stroke(points: [StrokePoint(x: 10 as Float, y: 50), StrokePoint(x: 90 as Float, y: 50)],
                              color: StrokeColor(r: 255, g: 0, b: 0), brushSize: 14))
        let image = try XCTUnwrap(renderer.makeImage(session, scale: 1, background: nil))

        let center = pixel(image, 50, 50)
        XCTAssertGreaterThan(center.r, 200)
        XCTAssertGreaterThan(center.a, 200)
        XCTAssertLessThan(pixel(image, 4, 4).a, 20)
    }

    func testMetalEraseClearsPixels() throws {
        let renderer = try makeRenderer()
        var session = DrawingSession(canvasSize: SIMD2(100, 100))
        session.commit(Stroke(points: [StrokePoint(x: 10 as Float, y: 50), StrokePoint(x: 90 as Float, y: 50)],
                              color: StrokeColor(r: 0, g: 0, b: 255), brushSize: 26))
        session.commit(Stroke(points: [StrokePoint(x: 10 as Float, y: 50), StrokePoint(x: 90 as Float, y: 50)],
                              color: .black, brushSize: 26, blendMode: .erase))
        let image = try XCTUnwrap(renderer.makeImage(session, scale: 1, background: nil))
        XCTAssertLessThan(pixel(image, 50, 50).a, 30)
    }

    func testMetalBackgroundFills() throws {
        let renderer = try makeRenderer()
        let session = DrawingSession(canvasSize: SIMD2(20, 20))
        let image = try XCTUnwrap(renderer.makeImage(session, scale: 1, background: StrokeColor(r: 0, g: 200, b: 0)))
        let p = pixel(image, 10, 10)
        XCTAssertGreaterThan(p.g, 150)
        XCTAssertGreaterThan(p.a, 200)
    }

    /// Opaque strokes should land in roughly the same place as the CG renderer.
    func testMetalMatchesCoreGraphicsForOpaqueStroke() throws {
        let renderer = try makeRenderer()
        var session = DrawingSession(canvasSize: SIMD2(80, 80))
        session.commit(Stroke(points: [StrokePoint(x: 10 as Float, y: 40), StrokePoint(x: 70 as Float, y: 40)],
                              color: StrokeColor(r: 200, g: 50, b: 50), brushSize: 16))
        let metal = try XCTUnwrap(renderer.makeImage(session, scale: 1))
        let cg = try XCTUnwrap(CoreGraphicsRenderer().makeImage(session, scale: 1))

        // Both cover the center and leave the corner clear.
        XCTAssertGreaterThan(pixel(metal, 40, 40).a, 200)
        XCTAssertGreaterThan(pixel(cg, 40, 40).a, 200)
        XCTAssertLessThan(pixel(metal, 3, 3).a, 20)
        XCTAssertLessThan(pixel(cg, 3, 3).a, 20)
    }

    /// A long stroke tessellates to far more than the 4 KB `setVertexBytes`
    /// limit — it must render via a real vertex buffer.
    func testMetalLongStrokeRenders() throws {
        let renderer = try makeRenderer()
        var session = DrawingSession(canvasSize: SIMD2(400, 100))
        var stroke = Stroke(color: StrokeColor(r: 0, g: 0, b: 0), brushSize: 8)
        for i in 0..<300 { stroke.append(StrokePoint(x: Float(i) + 40, y: 50, timestamp: Float(i) / 120)) }
        session.commit(stroke)
        let image = try XCTUnwrap(renderer.makeImage(session, scale: 1))
        XCTAssertGreaterThan(pixel(image, 200, 50).a, 200) // painted along the line
    }

    /// Shared instance is reusable and renders a smoothed multi-point stroke.
    func testMetalSharedInstanceRendersSmoothedStroke() throws {
        try XCTSkipIf(MetalSessionRenderer.shared == nil, "No Metal device available on this host")
        let renderer = MetalSessionRenderer.shared!
        var session = DrawingSession(canvasSize: SIMD2(120, 120))
        var stroke = Stroke(color: StrokeColor(r: 0, g: 0, b: 0), brushSize: 10)
        for i in 0..<12 {
            stroke.append(StrokePoint(x: Float(10 + i * 8), y: Float(60 + (i % 2 == 0 ? -20 : 20)),
                                      timestamp: Float(i) / 60))
        }
        session.commit(stroke)
        let image = try XCTUnwrap(renderer.makeImage(session, scale: 1))
        XCTAssertGreaterThan(pixel(image, 60, 60).a, 100) // stroke passes near the middle
    }

    /// A layer at 0.5 opacity must render at roughly half alpha (per-layer
    /// composite), matching the Core Graphics renderer.
    func testMetalLayerOpacity() throws {
        let renderer = try makeRenderer()
        var session = DrawingSession(canvasSize: SIMD2(60, 60))
        session.setOpacity(0.5, ofLayer: 0)
        session.commit(Stroke(points: [StrokePoint(x: 5 as Float, y: 30), StrokePoint(x: 55 as Float, y: 30)],
                              color: StrokeColor(r: 0, g: 0, b: 0), brushSize: 30))
        let image = try XCTUnwrap(renderer.makeImage(session, scale: 1, background: nil))
        let a = pixel(image, 30, 30).a
        XCTAssertGreaterThan(a, 100)
        XCTAssertLessThan(a, 160)
    }

    /// An eraser on the top layer must not clear the layer beneath it (per-layer
    /// isolation).
    func testMetalEraserIsLayerLocal() throws {
        let renderer = try makeRenderer()
        var session = DrawingSession(canvasSize: SIMD2(60, 60))
        session.commit(Stroke(points: [StrokePoint(x: 5 as Float, y: 30), StrokePoint(x: 55 as Float, y: 30)],
                              color: StrokeColor(r: 0, g: 180, b: 0), brushSize: 26))   // bottom: green
        session.addLayer(name: "Top")
        session.commit(Stroke(points: [StrokePoint(x: 5 as Float, y: 30), StrokePoint(x: 55 as Float, y: 30)],
                              color: .black, brushSize: 26, blendMode: .erase))          // erase in top layer
        let image = try XCTUnwrap(renderer.makeImage(session, scale: 1, background: nil))
        // Bottom green must survive the top-layer eraser.
        XCTAssertGreaterThan(pixel(image, 30, 30).g, 120)
    }

    func testMetalScaleProducesLargerImage() throws {
        let renderer = try makeRenderer()
        let session = DrawingSession(canvasSize: SIMD2(40, 30))
        let image = try XCTUnwrap(renderer.makeImage(session, scale: 2))
        XCTAssertEqual(image.width, 80)
        XCTAssertEqual(image.height, 60)
    }
}
