import CoreGraphics

/// Maps between canvas-point space and view space, combining the base
/// aspect-fit with a user zoom and pan. Pure value type so the transform math
/// is unit-testable independently of the view.
public struct CanvasViewport: Equatable, Sendable {
    public var canvasSize: CGSize
    public var viewBounds: CGSize
    /// User zoom multiplier on top of the fit scale (1 = fit).
    public var zoom: CGFloat
    /// Extra translation in view points.
    public var pan: CGPoint

    public var minZoom: CGFloat
    public var maxZoom: CGFloat

    public init(canvasSize: CGSize = .zero, viewBounds: CGSize = .zero,
                zoom: CGFloat = 1, pan: CGPoint = .zero,
                minZoom: CGFloat = 1, maxZoom: CGFloat = 16) {
        self.canvasSize = canvasSize
        self.viewBounds = viewBounds
        self.zoom = zoom
        self.pan = pan
        self.minZoom = minZoom
        self.maxZoom = maxZoom
    }

    /// Scale that aspect-fits the canvas into the view.
    public var fitScale: CGFloat {
        guard canvasSize.width > 0, canvasSize.height > 0 else { return 1 }
        return min(viewBounds.width / canvasSize.width, viewBounds.height / canvasSize.height)
    }

    /// Effective canvas→view scale.
    public var scale: CGFloat { fitScale * zoom }

    /// Top-left of the drawn canvas in view space.
    public var origin: CGPoint {
        let drawn = CGSize(width: canvasSize.width * scale, height: canvasSize.height * scale)
        return CGPoint(x: (viewBounds.width - drawn.width) * 0.5 + pan.x,
                       y: (viewBounds.height - drawn.height) * 0.5 + pan.y)
    }

    /// The rect the canvas occupies in view space.
    public var drawnRect: CGRect {
        CGRect(origin: origin, size: CGSize(width: canvasSize.width * scale, height: canvasSize.height * scale))
    }

    /// True once the view has a usable size (`scale > 0`). Before first layout
    /// coordinates can't be mapped — callers should ignore input until then (B6),
    /// otherwise a stroke lands in raw view space instead of canvas space.
    public var isMappable: Bool { scale > 0 }

    public func viewToCanvas(_ p: CGPoint, clamped: Bool = true) -> CGPoint {
        guard scale > 0 else { return p }
        var c = CGPoint(x: (p.x - origin.x) / scale, y: (p.y - origin.y) / scale)
        if clamped {
            c.x = min(max(c.x, 0), canvasSize.width)
            c.y = min(max(c.y, 0), canvasSize.height)
        }
        return c
    }

    public func canvasToView(_ p: CGPoint) -> CGPoint {
        CGPoint(x: origin.x + p.x * scale, y: origin.y + p.y * scale)
    }

    public func canvasRectToView(_ r: CGRect) -> CGRect {
        CGRect(x: origin.x + r.origin.x * scale, y: origin.y + r.origin.y * scale,
               width: r.width * scale, height: r.height * scale)
    }

    /// Zooms by `factor` about a focal point (view space), keeping the canvas
    /// point under the focus fixed on screen.
    public mutating func zoom(by factor: CGFloat, at focal: CGPoint) {
        let anchor = viewToCanvas(focal, clamped: false)
        zoom = min(max(zoom * factor, minZoom), maxZoom)
        let moved = canvasToView(anchor)
        pan.x += focal.x - moved.x
        pan.y += focal.y - moved.y
        clampPan()
    }

    public mutating func translate(by delta: CGPoint) {
        pan.x += delta.x
        pan.y += delta.y
        clampPan()
    }

    public mutating func reset() {
        zoom = 1
        pan = .zero
    }

    /// Keeps the canvas from being panned entirely out of view: at least the
    /// fitted content stays centered when not zoomed, and can't drift past the
    /// edges when zoomed in.
    private mutating func clampPan() {
        if zoom <= 1 {
            pan = .zero
            return
        }
        let drawn = drawnRectIgnoringPan()
        let maxX = max(drawn.width - viewBounds.width, 0) * 0.5
        let maxY = max(drawn.height - viewBounds.height, 0) * 0.5
        pan.x = min(max(pan.x, -maxX), maxX)
        pan.y = min(max(pan.y, -maxY), maxY)
    }

    private func drawnRectIgnoringPan() -> CGRect {
        CGRect(x: 0, y: 0, width: canvasSize.width * scale, height: canvasSize.height * scale)
    }
}
