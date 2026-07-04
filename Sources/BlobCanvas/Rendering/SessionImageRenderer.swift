import CoreGraphics

/// Abstraction over "rasterize a session to an image", so the Core Graphics and
/// Metal backends are interchangeable (`CG as default, Metal as option`).
public protocol SessionImageRenderer {
    func makeImage(_ session: DrawingSession, scale: CGFloat, background: StrokeColor?) -> CGImage?
}

public extension SessionImageRenderer {
    func makeImage(_ session: DrawingSession, scale: CGFloat = 1) -> CGImage? {
        makeImage(session, scale: scale, background: nil)
    }
}

/// Default CPU renderer, backed by `StrokeRasterizer` (full feature set:
/// smoothing, per-stroke single-coverage translucency, layer groups).
public struct CoreGraphicsRenderer: SessionImageRenderer {
    public init() {}
    public func makeImage(_ session: DrawingSession, scale: CGFloat, background: StrokeColor?) -> CGImage? {
        StrokeRasterizer.makeImage(session, scale: scale, background: background)
    }
}
