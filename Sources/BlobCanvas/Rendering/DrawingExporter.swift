import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Renders a `DrawingSession` to shareable formats. PNG/thumbnail are raster;
/// PDF and SVG are vector (the ribbon fills are emitted as paths).
public enum DrawingExporter {

    // MARK: - Raster

    /// PNG at the given scale, optionally over a background (nil = transparent).
    /// Set `wideGamut` to render into Display P3 for wide-gamut displays.
    public static func pngData(_ session: DrawingSession, scale: CGFloat = 2,
                               background: StrokeColor? = nil, wideGamut: Bool = false) -> Data? {
        let space = wideGamut ? StrokeRasterizer.displayP3 : StrokeRasterizer.colorSpace
        guard let image = StrokeRasterizer.makeImage(session, scale: scale, background: background, colorSpace: space)
        else { return nil }
        return pngData(from: image)
    }

    /// A PNG thumbnail whose longest side is `maxDimension` points.
    public static func thumbnailPNG(_ session: DrawingSession, maxDimension: CGFloat = 256,
                                    background: StrokeColor? = .white) -> Data? {
        let longest = max(CGFloat(session.canvasSize.x), CGFloat(session.canvasSize.y), 1)
        let scale = min(maxDimension / longest, 1)
        guard let image = StrokeRasterizer.makeImage(session, scale: scale, background: background) else { return nil }
        return pngData(from: image)
    }

    private static func pngData(from image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    // MARK: - PDF (vector)

    public static func pdfData(_ session: DrawingSession, background: StrokeColor? = nil) -> Data? {
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data) else { return nil }
        var mediaBox = CGRect(x: 0, y: 0,
                              width: CGFloat(session.canvasSize.x), height: CGFloat(session.canvasSize.y))
        guard let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { return nil }

        ctx.beginPDFPage(nil)
        if let background {
            ctx.setFillColor(background.cgColor)
            ctx.fill(mediaBox)
        }
        // PDF is bottom-left origin; strokes are top-left. Flip once.
        ctx.translateBy(x: 0, y: mediaBox.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        StrokeRasterizer.render(session, into: ctx)
        ctx.endPDFPage()
        ctx.closePDF()
        return data as Data
    }

    // MARK: - SVG (vector)

    /// SVG document. Normal strokes become filled paths; erasers are painted in
    /// `background` (SVG has no destructive erase without masks), so pass an
    /// opaque background if the drawing uses the eraser.
    public static func svgString(_ session: DrawingSession, background: StrokeColor? = nil) -> String {
        let w = CGFloat(session.canvasSize.x), h = CGFloat(session.canvasSize.y)
        var svg = #"<svg xmlns="http://www.w3.org/2000/svg" width="\#(fmt(w))" height="\#(fmt(h))" "#
        svg += #"viewBox="0 0 \#(fmt(w)) \#(fmt(h))">"# + "\n"
        if let background {
            svg += #"<rect width="100%" height="100%" fill="\#(rgb(background))" fill-opacity="\#(alpha(background))"/>"# + "\n"
        }
        // All visible layers, bottom-up, each in a group carrying its opacity —
        // matching the PNG/PDF renderers (which composite every layer).
        for layer in session.layers where layer.isVisible && !layer.strokes.isEmpty {
            let grouped = layer.opacity < 0.999
            if grouped { svg += #"<g opacity="\#(String(format: "%.3f", layer.opacity))">"# + "\n" }
            for stroke in layer.strokes {
                let path = StrokeRasterizer.ribbonPath(for: stroke, smoothing: true)
                let color = stroke.blendMode == .erase ? (background ?? .white) : stroke.color
                svg += #"<path d="\#(svgPathData(path))" fill="\#(rgb(color))" "#
                svg += #"fill-opacity="\#(alpha(color))" fill-rule="nonzero"/>"# + "\n"
            }
            if grouped { svg += "</g>\n" }
        }
        svg += "</svg>\n"
        return svg
    }

    private static func svgPathData(_ path: CGPath) -> String {
        var d = ""
        path.applyWithBlock { element in
            let e = element.pointee
            let p = e.points
            switch e.type {
            case .moveToPoint:       d += "M\(fmt(p[0].x)) \(fmt(p[0].y)) "
            case .addLineToPoint:    d += "L\(fmt(p[0].x)) \(fmt(p[0].y)) "
            case .addQuadCurveToPoint:
                d += "Q\(fmt(p[0].x)) \(fmt(p[0].y)) \(fmt(p[1].x)) \(fmt(p[1].y)) "
            case .addCurveToPoint:
                d += "C\(fmt(p[0].x)) \(fmt(p[0].y)) \(fmt(p[1].x)) \(fmt(p[1].y)) \(fmt(p[2].x)) \(fmt(p[2].y)) "
            case .closeSubpath:      d += "Z "
            @unknown default:        break
            }
        }
        return d
    }

    // MARK: - Formatting

    private static func fmt(_ v: CGFloat) -> String { String(format: "%.2f", v) }
    private static func rgb(_ c: StrokeColor) -> String { "rgb(\(c.r),\(c.g),\(c.b))" }
    private static func alpha(_ c: StrokeColor) -> String { String(format: "%.3f", Double(c.a) / 255) }
}
