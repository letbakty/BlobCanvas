import Foundation
import CoreGraphics

/// Pure, UIKit-free stroke rendering. Shared by the interactive engine, the
/// exporters, and the tests, so ribbon geometry lives in exactly one place.
///
/// All drawing is in canvas-point coordinates; the caller sets up the context's
/// CTM (and, for export, its size and flip).
public enum StrokeRasterizer {

    /// sRGB — matches `StrokeColor.cgColor` so buffers and colors agree.
    public static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    // MARK: - Width

    /// Half-width at a point, given its neighbor for velocity. Stateless for
    /// `.pressure`/`.constant`; uses the previous point's time+distance for
    /// `.velocity`.
    static func halfWidth(_ p: StrokePoint, previous prev: StrokePoint?, _ stroke: Stroke) -> CGFloat {
        let base = CGFloat(stroke.brushSize)
        let factor: CGFloat
        switch stroke.dynamics {
        case .constant:
            factor = 1
        case .pressure:
            factor = CGFloat(p.pressure)
        case .velocity:
            factor = velocityFactor(from: prev, to: p)
        }
        return max(base * factor * 0.5, 0.25)
    }

    /// Faster strokes get thinner. Maps speed (pt/s) onto `[minFactor, 1]`.
    private static func velocityFactor(from prev: StrokePoint?, to p: StrokePoint) -> CGFloat {
        guard let prev else { return 1 }
        let dt = max(CGFloat(p.timestamp - prev.timestamp), 1e-4)
        let dx = CGFloat(p.x - prev.x), dy = CGFloat(p.y - prev.y)
        let speed = (dx * dx + dy * dy).squareRoot() / dt
        let minFactor: CGFloat = 0.35
        let speedForMin: CGFloat = 1500
        let t = min(speed / speedForMin, 1)
        return 1 - t * (1 - minFactor)
    }

    // MARK: - Path geometry

    private static func addDot(_ path: CGMutablePath, at c: CGPoint, radius r: CGFloat) {
        path.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
    }

    private static func addQuad(_ path: CGMutablePath, from a: CGPoint, to b: CGPoint, ra: CGFloat, rb: CGFloat) {
        let dx = b.x - a.x, dy = b.y - a.y
        let len = (dx * dx + dy * dy).squareRoot()
        guard len > 1e-4 else { return }
        let nx = -dy / len, ny = dx / len
        path.move(to: CGPoint(x: a.x + nx * ra, y: a.y + ny * ra))
        path.addLine(to: CGPoint(x: b.x + nx * rb, y: b.y + ny * rb))
        path.addLine(to: CGPoint(x: b.x - nx * rb, y: b.y - ny * rb))
        path.addLine(to: CGPoint(x: a.x - nx * ra, y: a.y - ny * ra))
        path.closeSubpath()
    }

    /// Adds one incremental joint (dot at `to` + quad from `from`) to `path`.
    /// Used by the live input path for O(1)-per-point drawing.
    static func addIncrementalJoint(
        _ path: CGMutablePath, from: (CGPoint, CGFloat)?, to: (CGPoint, CGFloat)
    ) {
        addDot(path, at: to.0, radius: to.1)
        if let from { addQuad(path, from: from.0, to: to.0, ra: from.1, rb: to.1) }
    }

    /// Builds the filled ribbon for a whole stroke as a single path (one fill =
    /// one coverage pass, so translucent self-overlaps never double-blend).
    static func ribbonPath(for stroke: Stroke, smoothing: Bool) -> CGPath {
        let path = CGMutablePath()
        let centers: [CGPoint]
        let radii: [CGFloat]
        if smoothing && stroke.points.count > 2 {
            (centers, radii) = smoothedSamples(for: stroke)
        } else {
            centers = stroke.points.map { $0.cgPoint }
            radii = strideRadii(for: stroke)
        }
        guard let first = centers.first else { return path }
        if centers.count == 1 {
            addDot(path, at: first, radius: radii[0])
            return path
        }
        addDot(path, at: first, radius: radii[0])
        for i in 1..<centers.count {
            addDot(path, at: centers[i], radius: radii[i])
            addQuad(path, from: centers[i - 1], to: centers[i], ra: radii[i - 1], rb: radii[i])
        }
        return path
    }

    private static func strideRadii(for stroke: Stroke) -> [CGFloat] {
        var out = [CGFloat]()
        out.reserveCapacity(stroke.points.count)
        var prev: StrokePoint?
        for p in stroke.points {
            out.append(halfWidth(p, previous: prev, stroke))
            prev = p
        }
        return out
    }

    /// Catmull-Rom interpolation of centers and radii for smooth curves.
    private static func smoothedSamples(for stroke: Stroke) -> (centers: [CGPoint], radii: [CGFloat]) {
        let pts = stroke.points
        let baseRadii = strideRadii(for: stroke)
        var centers = [CGPoint]()
        var radii = [CGFloat]()
        centers.reserveCapacity(pts.count * 4)

        func point(_ i: Int) -> CGPoint { pts[min(max(i, 0), pts.count - 1)].cgPoint }
        func radius(_ i: Int) -> CGFloat { baseRadii[min(max(i, 0), baseRadii.count - 1)] }

        for i in 0..<(pts.count - 1) {
            let p0 = point(i - 1), p1 = point(i), p2 = point(i + 1), p3 = point(i + 2)
            let r1 = radius(i), r2 = radius(i + 1)
            let segLen = hypot(p2.x - p1.x, p2.y - p1.y)
            let steps = min(max(Int(segLen / 3), 1), 24)
            for s in 0..<steps {
                let t = CGFloat(s) / CGFloat(steps)
                centers.append(catmullRom(p0, p1, p2, p3, t))
                radii.append(r1 + (r2 - r1) * t)
            }
        }
        centers.append(point(pts.count - 1))
        radii.append(radius(pts.count - 1))
        return (centers, radii)
    }

    private static func catmullRom(_ p0: CGPoint, _ p1: CGPoint, _ p2: CGPoint, _ p3: CGPoint, _ t: CGFloat) -> CGPoint {
        let t2 = t * t, t3 = t2 * t
        func axis(_ a: CGFloat, _ b: CGFloat, _ c: CGFloat, _ d: CGFloat) -> CGFloat {
            0.5 * ((2 * b) + (-a + c) * t + (2 * a - 5 * b + 4 * c - d) * t2 + (-a + 3 * b - 3 * c + d) * t3)
        }
        return CGPoint(x: axis(p0.x, p1.x, p2.x, p3.x), y: axis(p0.y, p1.y, p2.y, p3.y))
    }

    // MARK: - Drawing

    /// Draws one stroke into `ctx`, honoring blend mode and width dynamics.
    public static func draw(_ stroke: Stroke, into ctx: CGContext, smoothing: Bool = true) {
        guard !stroke.points.isEmpty else { return }
        let path = ribbonPath(for: stroke, smoothing: smoothing)
        ctx.saveGState()
        switch stroke.blendMode {
        case .normal:
            ctx.setBlendMode(.normal)
            ctx.setFillColor(stroke.color.cgColor)
        case .erase:
            ctx.setBlendMode(.clear)
            ctx.setFillColor(StrokeColor.black.cgColor)
        }
        ctx.addPath(path)
        ctx.fillPath()
        ctx.restoreGState()
    }

    /// Renders every visible layer of a session into `ctx` (canvas-point space),
    /// bottom-up. Layers that need isolation — non-opaque, or containing an
    /// eraser (so `.clear` only affects that layer, not the ones beneath) — are
    /// drawn inside a transparency group; opaque plain layers draw directly.
    public static func render(_ session: DrawingSession, into ctx: CGContext, smoothing: Bool = true) {
        for layer in session.layers where layer.isVisible && !layer.strokes.isEmpty {
            let needsGroup = layer.opacity < 0.999 || layer.strokes.contains { $0.blendMode == .erase }
            if needsGroup {
                ctx.saveGState()
                ctx.setAlpha(CGFloat(layer.opacity))
                ctx.beginTransparencyLayer(auxiliaryInfo: nil)
                for stroke in layer.strokes { draw(stroke, into: ctx, smoothing: smoothing) }
                ctx.endTransparencyLayer()
                ctx.restoreGState()
            } else {
                for stroke in layer.strokes { draw(stroke, into: ctx, smoothing: smoothing) }
            }
        }
    }

    // MARK: - Offscreen image

    /// Rasterizes a session to a `CGImage` at the given scale, optionally over a
    /// background color (nil = transparent).
    public static func makeImage(
        _ session: DrawingSession, scale: CGFloat = 1, background: StrokeColor? = nil
    ) -> CGImage? {
        let w = max(1, Int((CGFloat(session.canvasSize.x) * scale).rounded()))
        let h = max(1, Int((CGFloat(session.canvasSize.y) * scale).rounded()))
        guard let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }

        if let background {
            ctx.setFillColor(background.cgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        }
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: scale, y: -scale)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        render(session, into: ctx)
        return ctx.makeImage()
    }
}
