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

// MARK: - Owned pixel buffer

/// A bitmap whose pixel memory we own, so it can be presented every frame as a
/// lightweight `CGImage` *without copying* (via a persistent `CGDataProvider`).
/// This is the key to avoiding a full-buffer snapshot on the hot path — unlike
/// `CGBitmapContext.makeImage()`, which copies the entire bitmap each call.
///
/// The context's user space is *canvas points* with a top-left origin, so all
/// drawing happens in device-independent canvas coordinates.
private final class CanvasBuffer {
    let canvasSize: CGSize        // logical size in points (device-independent)
    let scale: CGFloat            // backing pixels per point
    let context: CGContext
    private let provider: CGDataProvider
    private let pixelWidth: Int
    private let pixelHeight: Int
    private let bytesPerRow: Int

    init?(canvasSize: CGSize, scale: CGFloat) {
        let w = max(1, Int((canvasSize.width * scale).rounded()))
        let h = max(1, Int((canvasSize.height * scale).rounded()))
        let bpr = w * 4
        let byteCount = bpr * h
        guard let data = calloc(byteCount, 1) else { return nil }

        let space = StrokeRasterizer.colorSpace   // sRGB, matches StrokeColor
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue
        guard let ctx = CGContext(
            data: data, width: w, height: h, bitsPerComponent: 8,
            bytesPerRow: bpr, space: space, bitmapInfo: bitmapInfo
        ) else { free(data); return nil }

        // The provider owns `data` and frees it when the buffer is released.
        guard let provider = CGDataProvider(
            dataInfo: data, data: data, size: byteCount,
            releaseData: { ptr, _, _ in free(ptr) }
        ) else { free(data); return nil }

        self.canvasSize = canvasSize
        self.scale = scale
        self.context = ctx
        self.provider = provider
        self.pixelWidth = w
        self.pixelHeight = h
        self.bytesPerRow = bpr

        // Map canvas points → pixels with a top-left origin.
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: scale, y: -scale)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.setShouldAntialias(true)
    }

    /// A zero-copy image over the live pixels. Cheap enough to build per frame:
    /// it references the provider, no pixel data is duplicated.
    func makeImage() -> CGImage? {
        CGImage(
            width: pixelWidth, height: pixelHeight,
            bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
            space: StrokeRasterizer.colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
        )
    }

    func clear() {
        context.clear(CGRect(origin: .zero, size: canvasSize))
    }
}

// MARK: - Engine view

/// High-performance stroke renderer.
///
/// **Fixed logical canvas.** Strokes are stored and rendered in canvas-point
/// coordinates (`session.canvasSize`), independent of the view's size. The view
/// aspect-fits the canvas into its bounds, so a drawing made on an iPad opens
/// correctly on an iPhone — input is mapped view→canvas, output canvas→view.
///
/// **Two buffers.** `committed` holds all finished strokes; `live` holds the
/// in-progress stroke, drawn opaque and composited over `committed` with the
/// brush's alpha exactly once at present time. This gives correct translucency
/// with no double-blended "beading" at sample points.
///
/// **Zero per-frame copy.** Both buffers own their pixel memory and are
/// presented as lightweight provider-backed `CGImage`s — no `makeImage()`
/// snapshot copy on the draw path.
///
/// **No allocations on the hot input path.** Each new point fills only its new
/// joint (circle + quad) into `live`; a finished stroke is flattened into
/// `committed` as a single filled ribbon. A full re-bake happens only on
/// undo/redo/clear/load/resize.
public final class CanvasEngineView: PlatformView {

    // MARK: - Public state

    public private(set) var session = DrawingSession()

    public var brushColor: StrokeColor = .black
    public var brushSize: Float = 8
    public var brushBlendMode: BlendMode = .normal
    public var brushDynamics: WidthDynamics = .pressure

    /// When true, only Apple Pencil input draws — finger and palm touches are
    /// rejected (palm rejection).
    public var pencilOnly: Bool = false

    /// Smooth committed strokes with Catmull-Rom interpolation (live preview
    /// stays polyline for latency; commit is the smoothed authoritative render).
    public var smoothing: Bool = true

    /// Fired after a stroke is committed or undo/redo/clear mutates history.
    public var onSessionChanged: ((DrawingSession) -> Void)?

    // MARK: - Private state

    private var committed: CanvasBuffer?
    private var live: CanvasBuffer?
    /// Ephemeral forecast tail from `predictedTouches` — drawn but never
    /// committed to `liveStroke`; cleared and redrawn each input event.
    private var predicted: CanvasBuffer?
    private var predictedBBox: CGRect = .null   // canvas space; region to clear
    private var canvasSize: CGSize = CGSize(width: 1024, height: 768)

    private var liveStroke = Stroke()
    private var liveStrokeStartTime: CFTimeInterval = 0
    private var isStroking = false

    #if canImport(UIKit)
    /// Maps a touch's `estimationUpdateIndex` to the index of the point it
    /// produced in `liveStroke`, so late-arriving force values can patch it.
    private var estimationMap: [NSNumber: Int] = [:]
    /// The touch currently drawing, so mid-stroke finger touches are ignored.
    private weak var activeTouch: UITouch?
    #endif

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
        canvasSize = CGSize(width: CGFloat(session.canvasSize.x), height: CGFloat(session.canvasSize.y))
        liveStroke.points.reserveCapacity(2048)
        #if canImport(UIKit)
        isMultipleTouchEnabled = false
        backgroundColor = .white
        contentMode = .redraw
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
        canvasSize = CGSize(width: CGFloat(session.canvasSize.x), height: CGFloat(session.canvasSize.y))
        committed = nil
        live = nil
        ensureBuffers()
        setNeedsFullDisplay()
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

    // MARK: - Buffers

    private func currentScale() -> CGFloat {
        #if canImport(UIKit)
        let s = traitCollection.displayScale
        return s > 0 ? s : (window?.screen.scale ?? 2)
        #else
        return window?.backingScaleFactor ?? 2
        #endif
    }

    private func ensureBuffers() {
        let scale = currentScale()
        if let committed, committed.scale == scale, committed.canvasSize == canvasSize { return }
        committed = CanvasBuffer(canvasSize: canvasSize, scale: scale)
        live = CanvasBuffer(canvasSize: canvasSize, scale: scale)
        predicted = CanvasBuffer(canvasSize: canvasSize, scale: scale)
        predictedBBox = .null
        rebake()
    }

    #if canImport(UIKit)
    public override func layoutSubviews() {
        super.layoutSubviews()
        ensureBuffers()
    }
    #else
    public override func layout() {
        super.layout()
        ensureBuffers()
    }
    #endif

    /// Redraws every committed stroke into `committed`. Only on undo/redo/
    /// clear/load/resize.
    private func rebake() {
        guard let ctx = committed?.context else { return }
        ctx.clear(CGRect(origin: .zero, size: canvasSize))
        StrokeRasterizer.render(session, into: ctx, smoothing: smoothing)
        live?.clear()
        clearPredicted()
        setNeedsFullDisplay()
    }

    // MARK: - Canvas ↔ view transform (aspect-fit, centered)

    private func fit() -> (origin: CGPoint, scale: CGFloat) {
        guard canvasSize.width > 0, canvasSize.height > 0 else { return (.zero, 1) }
        let s = min(bounds.width / canvasSize.width, bounds.height / canvasSize.height)
        let drawn = CGSize(width: canvasSize.width * s, height: canvasSize.height * s)
        let origin = CGPoint(x: (bounds.width - drawn.width) * 0.5,
                             y: (bounds.height - drawn.height) * 0.5)
        return (origin, s)
    }

    private func viewToCanvas(_ p: CGPoint) -> CGPoint {
        let f = fit()
        guard f.scale > 0 else { return p }
        return CGPoint(
            x: min(max((p.x - f.origin.x) / f.scale, 0), canvasSize.width),
            y: min(max((p.y - f.origin.y) / f.scale, 0), canvasSize.height)
        )
    }

    private func canvasRectToView(_ r: CGRect) -> CGRect {
        let f = fit()
        return CGRect(x: r.origin.x * f.scale + f.origin.x,
                      y: r.origin.y * f.scale + f.origin.y,
                      width: r.width * f.scale, height: r.height * f.scale)
    }

    // MARK: - Live input (hot path)

    private func beginStroke(atCanvas p: CGPoint, pressure: CGFloat) {
        ensureBuffers()
        liveStroke = Stroke(points: [], color: brushColor, brushSize: brushSize,
                            blendMode: brushBlendMode, dynamics: brushDynamics)
        liveStroke.points.reserveCapacity(2048)
        liveStrokeStartTime = CACurrentMediaTime()
        isStroking = true
        #if canImport(UIKit)
        estimationMap.removeAll(keepingCapacity: true)
        #endif
        clearPredicted()
        appendLivePoint(atCanvas: p, pressure: pressure)
    }

    /// Appends one point and incrementally fills only its new joint. Normal
    /// strokes go into `live` (opaque, alpha applied at present); erasers clear
    /// straight into `committed` for real-time feedback.
    /// - Returns: `true` if the point was appended (not skipped as too close).
    @discardableResult
    private func appendLivePoint(atCanvas point: CGPoint, pressure: CGFloat) -> Bool {
        guard isStroking else { return false }
        let last = liveStroke.points.last
        if let last {
            let dx = point.x - CGFloat(last.x), dy = point.y - CGFloat(last.y)
            guard dx * dx + dy * dy > 0.0625 else { return false } // skip sub-quarter-point moves
        }
        let p = StrokePoint(
            x: point.x, y: point.y, pressure: pressure,
            timestamp: Float(CACurrentMediaTime() - liveStrokeStartTime)
        )

        let r = StrokeRasterizer.halfWidth(p, previous: last, liveStroke)
        let from = last.map { ($0.cgPoint, StrokeRasterizer.halfWidth($0, previous: nil, liveStroke)) }
        let path = CGMutablePath()
        StrokeRasterizer.addIncrementalJoint(path, from: from, to: (p.cgPoint, r))

        let isErase = liveStroke.blendMode == .erase
        guard let ctx = (isErase ? committed : live)?.context else { return false }
        ctx.saveGState()
        if isErase {
            ctx.setBlendMode(.clear)
            ctx.setFillColor(StrokeColor.black.cgColor)
        } else {
            var opaque = liveStroke.color
            opaque.a = 255
            ctx.setFillColor(opaque.cgColor)
        }
        ctx.addPath(path)
        ctx.fillPath()
        ctx.restoreGState()

        let dirty: CGRect
        if let last {
            dirty = CGRect(x: CGFloat(min(last.x, p.x)), y: CGFloat(min(last.y, p.y)),
                           width: CGFloat(abs(p.x - last.x)), height: CGFloat(abs(p.y - last.y)))
        } else {
            dirty = CGRect(x: point.x, y: point.y, width: 0, height: 0)
        }
        liveStroke.points.append(p)
        setNeedsDisplay(viewDirtyRect(canvas: dirty))
        return true
    }

    private func endStroke() {
        guard isStroking else { return }
        isStroking = false
        if !liveStroke.points.isEmpty, let committed {
            // Authoritative render (smoothed). For erasers this re-applies the
            // clear over the incremental preview — idempotent.
            StrokeRasterizer.draw(liveStroke, into: committed.context, smoothing: smoothing)
        }
        live?.clear()
        clearPredicted()
        #if canImport(UIKit)
        estimationMap.removeAll(keepingCapacity: true)
        #endif
        session.commit(liveStroke)
        setNeedsFullDisplay()
        onSessionChanged?(session)
    }

    // MARK: - Predicted tail

    /// Renders a short forecast ribbon from the last confirmed point through the
    /// predicted canvas points into the `predicted` buffer. Reduces perceived
    /// pen latency by ~1 frame; the tail is discarded on the next real event.
    private func renderPredicted(canvasPoints tail: [CGPoint]) {
        // Erasers write straight into `committed`, so there is nothing to
        // preview-and-roll-back; skip prediction for them.
        guard isStroking, liveStroke.blendMode == .normal,
              let predicted, let anchor = liveStroke.points.last else { return }
        let oldRegion = predictedBBox

        var stroke = liveStroke
        let tailPressure = anchor.pressure
        stroke.points = [anchor] + tail.map {
            StrokePoint(x: Float($0.x), y: Float($0.y), pressure: tailPressure)
        }
        predicted.context.clear(oldRegion.isNull ? CGRect(origin: .zero, size: canvasSize) : oldRegion)

        var opaque = stroke.color
        opaque.a = 255
        stroke.color = opaque
        StrokeRasterizer.draw(stroke, into: predicted.context, smoothing: false)
        predictedBBox = strokeBBox(stroke)

        var dirty = oldRegion
        dirty = dirty.isNull ? predictedBBox : dirty.union(predictedBBox)
        setNeedsDisplay(viewDirtyRect(canvas: dirty))
    }

    private func clearPredicted() {
        guard let predicted else { return }
        if !predictedBBox.isNull {
            predicted.context.clear(predictedBBox)
            setNeedsDisplay(viewDirtyRect(canvas: predictedBBox))
        }
        predictedBBox = .null
    }

    private func strokeBBox(_ stroke: Stroke) -> CGRect {
        guard let first = stroke.points.first else { return .null }
        var minX = first.x, minY = first.y, maxX = first.x, maxY = first.y
        for p in stroke.points {
            minX = min(minX, p.x); minY = min(minY, p.y)
            maxX = max(maxX, p.x); maxY = max(maxY, p.y)
        }
        let pad = stroke.brushSize + 2
        return CGRect(x: CGFloat(minX) - CGFloat(pad), y: CGFloat(minY) - CGFloat(pad),
                      width: CGFloat(maxX - minX) + CGFloat(pad) * 2,
                      height: CGFloat(maxY - minY) + CGFloat(pad) * 2)
    }

    private func viewDirtyRect(canvas rect: CGRect) -> CGRect {
        let pad = (CGFloat(liveStroke.brushSize) + 2) * fit().scale
        return canvasRectToView(rect).insetBy(dx: -pad, dy: -pad)
    }

    // MARK: - Present

    #if canImport(UIKit)
    public override func draw(_ rect: CGRect) {
        present(into: UIGraphicsGetCurrentContext())
    }
    #else
    public override func draw(_ dirtyRect: NSRect) {
        present(into: NSGraphicsContext.current?.cgContext)
    }
    #endif

    private func present(into target: CGContext?) {
        guard let target else { return }
        let f = fit()
        let rect = CGRect(origin: f.origin,
                          size: CGSize(width: canvasSize.width * f.scale,
                                       height: canvasSize.height * f.scale))
        if let image = committed?.makeImage() {
            drawUpright(image, in: rect, into: target, alpha: 1)
        }
        if isStroking {
            let alpha = CGFloat(liveStroke.color.a) / 255
            if let image = live?.makeImage() {
                drawUpright(image, in: rect, into: target, alpha: alpha)
            }
            if !predictedBBox.isNull, let image = predicted?.makeImage() {
                drawUpright(image, in: rect, into: target, alpha: alpha)
            }
        }
    }

    /// Draws a top-origin `CGImage` upright into `rect`, with `alpha`.
    private func drawUpright(_ image: CGImage, in rect: CGRect, into ctx: CGContext, alpha: CGFloat) {
        ctx.saveGState()
        ctx.setAlpha(alpha)
        ctx.translateBy(x: rect.minX, y: rect.minY + rect.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(origin: .zero, size: rect.size))
        ctx.restoreGState()
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
    /// Picks the touch to draw with: prefers an Apple Pencil, and when
    /// `pencilOnly` is set, rejects finger/palm touches entirely.
    private func drawingTouch(in touches: Set<UITouch>) -> UITouch? {
        if let pencil = touches.first(where: { $0.type == .pencil }) { return pencil }
        if pencilOnly { return nil }
        return touches.first
    }

    public override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = drawingTouch(in: touches) else { return }
        activeTouch = touch
        beginStroke(atCanvas: viewToCanvas(touch.location(in: self)), pressure: normalizedForce(touch))
    }

    public override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = activeTouch ?? drawingTouch(in: touches) else { return }
        // Coalesced touches deliver the full 120/240 Hz sample stream even
        // when the display refreshes slower — critical for smooth curves.
        for t in event?.coalescedTouches(for: touch) ?? [touch] {
            let appended = appendLivePoint(atCanvas: viewToCanvas(t.location(in: self)),
                                           pressure: normalizedForce(t))
            // Record which point to patch when a late force value arrives.
            if appended, t.estimatedPropertiesExpectingUpdates.contains(.force),
               let index = t.estimationUpdateIndex {
                estimationMap[index] = liveStroke.points.count - 1
            }
        }
        // Predicted touches forecast the next frame; drawn but not committed.
        let predictedTail = (event?.predictedTouches(for: touch) ?? []).map {
            viewToCanvas($0.location(in: self))
        }
        renderPredicted(canvasPoints: predictedTail)
    }

    /// Late-arriving precise values (notably Pencil force) for points we already
    /// recorded with an estimate. Patches the stored data so the committed
    /// render uses the true pressure.
    public override func touchesEstimatedPropertiesUpdated(_ touches: Set<UITouch>) {
        for touch in touches {
            guard let index = touch.estimationUpdateIndex,
                  let pointIndex = estimationMap[index],
                  pointIndex < liveStroke.points.count else { continue }
            liveStroke.points[pointIndex].pressure = Float(normalizedForce(touch))
            if !touch.estimatedPropertiesExpectingUpdates.contains(.force) {
                estimationMap[index] = nil
            }
        }
    }

    public override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = activeTouch, touches.contains(touch) else { return }
        appendLivePoint(atCanvas: viewToCanvas(touch.location(in: self)), pressure: normalizedForce(touch))
        activeTouch = nil
        endStroke()
    }

    public override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard activeTouch == nil || touches.contains(activeTouch!) else { return }
        activeTouch = nil
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
        beginStroke(atCanvas: viewToCanvas(convert(event.locationInWindow, from: nil)), pressure: pressure(of: event))
    }

    public override func mouseDragged(with event: NSEvent) {
        appendLivePoint(atCanvas: viewToCanvas(convert(event.locationInWindow, from: nil)), pressure: pressure(of: event))
    }

    public override func mouseUp(with event: NSEvent) {
        appendLivePoint(atCanvas: viewToCanvas(convert(event.locationInWindow, from: nil)), pressure: pressure(of: event))
        endStroke()
    }

    private func pressure(of event: NSEvent) -> CGFloat {
        event.pressure > 0 ? CGFloat(event.pressure) : 1
    }
}
#endif
