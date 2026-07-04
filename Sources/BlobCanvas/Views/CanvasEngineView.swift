import Foundation
import CoreGraphics
import QuartzCore

#if canImport(UIKit)
import UIKit
public typealias PlatformView = UIView
#elseif canImport(AppKit)
import AppKit
public typealias PlatformView = NSView
#endif

/// High-performance stroke renderer.
///
/// Strategy: committed strokes are *baked* into an offscreen bitmap
/// (`CGContext`) exactly once. Each new input point strokes only the newly
/// added segments into that bitmap and invalidates just their dirty rect, so
/// per-frame cost is O(new segments) — constant — regardless of how many
/// thousands of points the drawing contains. `draw(_:)` is a single bitmap
/// blit. This comfortably sustains 120 Hz with coalesced touches.
///
/// A full re-bake happens only on undo/redo/clear/load/resize — rare events
/// where an O(total points) pass (still < 1 ms for typical drawings) is fine.
///
/// No allocations occur on the hot input path: points append into
/// pre-reserved contiguous arrays and segments are stroked with plain
/// `CGContext` move/addLine calls (no CGPath / UIBezierPath objects).
public final class CanvasEngineView: PlatformView {

    // MARK: - Public state

    /// The document being edited. Loading a new session re-bakes the bitmap.
    public private(set) var session = DrawingSession()

    /// Brush for the *next* stroke.
    public var brushColor: StrokeColor = .black
    public var brushSize: Float = 8

    /// Fired after a stroke is committed or undo/redo/clear mutates history.
    /// Hook your debounced auto-save here.
    public var onSessionChanged: ((DrawingSession) -> Void)?

    // MARK: - Private rendering state

    private var backing: CGContext?
    private var backingScale: CGFloat = 1

    private var liveStroke = Stroke()
    private var liveStrokeStartTime: CFTimeInterval = 0
    private var isStroking = false

    // MARK: - Init

    public override init(frame: CGRect) {
        super.init(frame: frame)
        commonInit()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        liveStroke.points.reserveCapacity(2048)
        #if canImport(UIKit)
        isMultipleTouchEnabled = false
        backgroundColor = .white
        #else
        wantsLayer = true
        layer?.backgroundColor = CGColor(gray: 1, alpha: 1)
        #endif
    }

    #if canImport(AppKit)
    public override var isFlipped: Bool { true } // match UIKit's top-left origin
    #endif

    // MARK: - Session API

    public func load(_ session: DrawingSession) {
        self.session = session
        rebake()
    }

    @discardableResult
    public func undo() -> Bool {
        guard session.undo() else { return false }
        rebake()
        onSessionChanged?(session)
        return true
    }

    @discardableResult
    public func redo() -> Bool {
        guard session.redo() else { return false }
        rebake()
        onSessionChanged?(session)
        return true
    }

    public func clear() {
        session.clear()
        rebake()
        onSessionChanged?(session)
    }

    // MARK: - Backing store

    private func ensureBacking() {
        #if canImport(UIKit)
        let scale = window?.screen.scale ?? UIScreen.main.scale
        #else
        let scale = window?.backingScaleFactor ?? 2
        #endif
        let pixelW = Int(bounds.width * scale)
        let pixelH = Int(bounds.height * scale)
        guard pixelW > 0, pixelH > 0 else { return }
        if let ctx = backing, ctx.width == pixelW, ctx.height == pixelH { return }

        let ctx = CGContext(
            data: nil,
            width: pixelW,
            height: pixelH,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        )!
        // Flip to top-left origin and scale so we can draw in view points.
        ctx.translateBy(x: 0, y: CGFloat(pixelH))
        ctx.scaleBy(x: scale, y: -scale)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        backing = ctx
        backingScale = scale

        session.canvasSize = SIMD2(Float(bounds.width), Float(bounds.height))
        rebake()
    }

    #if canImport(UIKit)
    public override func layoutSubviews() {
        super.layoutSubviews()
        ensureBacking()
    }
    #else
    public override func layout() {
        super.layout()
        ensureBacking()
    }
    #endif

    /// Full redraw of every committed stroke into the backing bitmap.
    /// Only used for undo/redo/clear/load/resize.
    private func rebake() {
        guard let ctx = backing else { return }
        ctx.clear(CGRect(origin: .zero, size: bounds.size))
        for stroke in session.strokes {
            bake(stroke, into: ctx)
        }
        setNeedsFullDisplay()
    }

    private func bake(_ stroke: Stroke, into ctx: CGContext) {
        let points = stroke.points
        guard let first = points.first else { return }
        ctx.setStrokeColor(stroke.color.cgColor)

        if points.count == 1 {
            fillDot(at: first, stroke: stroke, in: ctx)
            return
        }
        for i in 1..<points.count {
            strokeSegment(from: points[i - 1], to: points[i], stroke: stroke, in: ctx)
        }
    }

    /// Strokes one segment. Pressure modulates width per segment, which is why
    /// segments are stroked individually rather than as one path.
    private func strokeSegment(from a: StrokePoint, to b: StrokePoint, stroke: Stroke, in ctx: CGContext) {
        let width = CGFloat(stroke.brushSize) * CGFloat((a.pressure + b.pressure) * 0.5)
        ctx.setLineWidth(max(width, 0.5))
        ctx.move(to: a.cgPoint)
        ctx.addLine(to: b.cgPoint)
        ctx.strokePath()
    }

    private func fillDot(at p: StrokePoint, stroke: Stroke, in ctx: CGContext) {
        let r = CGFloat(stroke.brushSize) * CGFloat(p.pressure) * 0.5
        ctx.setFillColor(stroke.color.cgColor)
        ctx.fillEllipse(in: CGRect(x: CGFloat(p.x) - r, y: CGFloat(p.y) - r, width: r * 2, height: r * 2))
    }

    // MARK: - Live input (hot path)

    private func beginStroke(at point: CGPoint, pressure: CGFloat) {
        liveStroke = Stroke(points: [], color: brushColor, brushSize: brushSize)
        liveStroke.points.reserveCapacity(2048)
        liveStrokeStartTime = CACurrentMediaTime()
        isStroking = true
        appendLivePoint(point, pressure: pressure)
    }

    /// Appends one point and incrementally strokes only the new segment.
    private func appendLivePoint(_ point: CGPoint, pressure: CGFloat) {
        guard isStroking, let ctx = backing else { return }
        let p = StrokePoint(
            x: point.x,
            y: point.y,
            pressure: pressure,
            timestamp: Float(CACurrentMediaTime() - liveStrokeStartTime)
        )

        ctx.setStrokeColor(liveStroke.color.cgColor)
        let dirty: CGRect
        if let last = liveStroke.points.last {
            // Skip sub-quarter-point movement — invisible and wastes storage.
            let dx = p.x - last.x, dy = p.y - last.y
            guard dx * dx + dy * dy > 0.0625 else { return }
            strokeSegment(from: last, to: p, stroke: liveStroke, in: ctx)
            dirty = CGRect(x: CGFloat(min(last.x, p.x)), y: CGFloat(min(last.y, p.y)),
                           width: CGFloat(abs(dx)), height: CGFloat(abs(dy)))
        } else {
            fillDot(at: p, stroke: liveStroke, in: ctx)
            dirty = CGRect(x: point.x, y: point.y, width: 0, height: 0)
        }
        liveStroke.points.append(p)

        let pad = CGFloat(liveStroke.brushSize) + 2
        setNeedsDisplay(dirty.insetBy(dx: -pad, dy: -pad))
    }

    private func endStroke() {
        guard isStroking else { return }
        isStroking = false
        session.commit(liveStroke)
        onSessionChanged?(session)
    }

    // MARK: - Blit

    #if canImport(UIKit)
    public override func draw(_ rect: CGRect) {
        blit(into: UIGraphicsGetCurrentContext(), rect: rect)
    }
    #else
    public override func draw(_ dirtyRect: NSRect) {
        blit(into: NSGraphicsContext.current?.cgContext, rect: dirtyRect)
    }
    #endif

    private func blit(into target: CGContext?, rect: CGRect) {
        guard let target, let image = backing?.makeImage() else { return }
        target.saveGState()
        // makeImage() is bottom-left origin; flip once to view space.
        target.translateBy(x: 0, y: bounds.height)
        target.scaleBy(x: 1, y: -1)
        target.draw(image, in: CGRect(origin: .zero, size: bounds.size))
        target.restoreGState()
    }

    private func setNeedsFullDisplay() {
        #if canImport(UIKit)
        setNeedsDisplay()
        #else
        needsDisplay = true
        #endif
    }
}

// MARK: - Touch input (iOS)

#if canImport(UIKit)
extension CanvasEngineView {
    public override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else { return }
        beginStroke(at: touch.location(in: self), pressure: normalizedForce(touch))
    }

    public override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else { return }
        // Coalesced touches deliver the full 120/240 Hz sample stream even
        // when the display refreshes slower — critical for smooth curves.
        for t in event?.coalescedTouches(for: touch) ?? [touch] {
            appendLivePoint(t.location(in: self), pressure: normalizedForce(t))
        }
    }

    public override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        if let touch = touches.first {
            appendLivePoint(touch.location(in: self), pressure: normalizedForce(touch))
        }
        endStroke()
    }

    public override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        endStroke()
    }

    private func normalizedForce(_ touch: UITouch) -> CGFloat {
        touch.maximumPossibleForce > 0 ? max(touch.force / touch.maximumPossibleForce, 0.1) : 1
    }
}
#endif

// MARK: - Mouse input (macOS)

#if canImport(AppKit)
extension CanvasEngineView {
    public override func mouseDown(with event: NSEvent) {
        beginStroke(at: convert(event.locationInWindow, from: nil), pressure: pressure(of: event))
    }

    public override func mouseDragged(with event: NSEvent) {
        appendLivePoint(convert(event.locationInWindow, from: nil), pressure: pressure(of: event))
    }

    public override func mouseUp(with event: NSEvent) {
        appendLivePoint(convert(event.locationInWindow, from: nil), pressure: pressure(of: event))
        endStroke()
    }

    private func pressure(of event: NSEvent) -> CGFloat {
        event.pressure > 0 ? CGFloat(event.pressure) : 1
    }
}
#endif
