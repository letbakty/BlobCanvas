import Foundation

/// Time-based replay of how a drawing was made, using the per-point timestamps
/// captured during input. Pure value logic — drive it from a display link or
/// `Timer` and feed each `snapshot(at:)` into a renderer/exporter.
///
/// Timestamps are stored per stroke (relative to that stroke's start), and only
/// per-stroke relative timing is retained, so the player lays each layer's
/// strokes end-to-end (layer by layer, bottom-up) with a small pause between
/// strokes. **Layers, their opacity and visibility are preserved**, so a replay
/// composites the same way the finished drawing does.
public struct DrawingPlayer: Sendable {

    /// Pause inserted between consecutive strokes, in seconds.
    public var interStrokeGap: Double

    private let session: DrawingSession
    /// Per layer, per stroke: absolute start time, end time, and the stroke's
    /// first-point timestamp (the base to subtract).
    private let timings: [[(start: Double, end: Double, base: Double)]]
    /// Per layer: the time range its strokes occupy on the timeline.
    private let layerRange: [(start: Double, end: Double)]

    public let duration: Double

    public init(_ session: DrawingSession, interStrokeGap: Double = 0.12) {
        self.session = session
        self.interStrokeGap = interStrokeGap

        var timings: [[(start: Double, end: Double, base: Double)]] = []
        var layerRange: [(start: Double, end: Double)] = []
        var cursor = 0.0

        for layer in session.layers {
            var layerTimings: [(start: Double, end: Double, base: Double)] = []
            let layerStart = cursor
            for stroke in layer.strokes {
                let base = Double(stroke.points.first?.timestamp ?? 0)
                let d = Double(stroke.points.last?.timestamp ?? 0) - base
                layerTimings.append((start: cursor, end: cursor + max(d, 0), base: base))
                cursor += max(d, 0) + interStrokeGap
            }
            timings.append(layerTimings)
            layerRange.append((start: layerStart, end: max(cursor - interStrokeGap, layerStart)))
        }
        self.timings = timings
        self.layerRange = layerRange
        self.duration = max(cursor - interStrokeGap, 0)
    }

    /// The drawing as it looked `time` seconds into its creation: earlier layers
    /// complete, the layer being drawn partially, later layers empty.
    public func snapshot(at time: Double) -> DrawingSession {
        var outLayers: [Layer] = []
        outLayers.reserveCapacity(session.layers.count)

        for (li, layer) in session.layers.enumerated() {
            let range = layerRange[li]
            let strokes: [Stroke]
            if time <= range.start || layer.strokes.isEmpty {
                strokes = []                                   // not started
            } else if time >= range.end {
                strokes = layer.strokes                        // fully drawn (COW, no copy)
            } else {
                strokes = partialStrokes(layerIndex: li, layer: layer, time: time)
            }
            outLayers.append(Layer(id: layer.id, name: layer.name, strokes: strokes,
                                   opacity: layer.opacity, isVisible: layer.isVisible))
        }
        return DrawingSession(canvasSize: session.canvasSize, layers: outLayers,
                              activeLayerIndex: session.activeLayerIndex)
    }

    // MARK: - Private

    private func partialStrokes(layerIndex li: Int, layer: Layer, time: Double) -> [Stroke] {
        var out: [Stroke] = []
        for (si, stroke) in layer.strokes.enumerated() {
            let t = timings[li][si]
            if t.start >= time { break }                        // this + later not started
            if t.end <= time { out.append(stroke); continue }   // complete
            // In progress: keep points whose absolute time has elapsed. Point
            // timestamps are monotonic, so binary-search the cut-off.
            let cutoff = Float(time - t.start + t.base)
            let count = elapsedPointCount(stroke.points, cutoff: cutoff)
            if count > 0 {
                var partial = stroke
                partial.points = Array(stroke.points.prefix(count))
                out.append(partial)
            }
            break                                               // only one in-progress stroke
        }
        return out
    }

    /// Number of leading points with `timestamp <= cutoff` (points are ordered).
    private func elapsedPointCount(_ points: [StrokePoint], cutoff: Float) -> Int {
        var lo = 0, hi = points.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if points[mid].timestamp <= cutoff { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }
}
