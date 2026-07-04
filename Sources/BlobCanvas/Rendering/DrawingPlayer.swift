import Foundation

/// Time-based replay of how a drawing was made, using the per-point timestamps
/// captured during input. Pure value logic — drive it from a display link or
/// `Timer` and feed each `snapshot(at:)` into a renderer/exporter.
///
/// Timestamps are stored per stroke (relative to that stroke's start), so the
/// player lays strokes end-to-end with a small pause between them.
public struct DrawingPlayer: Sendable {

    /// Pause inserted between consecutive strokes, in seconds.
    public var interStrokeGap: Double

    private let session: DrawingSession
    /// Absolute start time of each stroke on the replay timeline.
    private let starts: [Double]
    /// Duration of each stroke (last minus first point timestamp).
    private let durations: [Double]

    public let duration: Double

    public init(_ session: DrawingSession, interStrokeGap: Double = 0.12) {
        self.session = session
        self.interStrokeGap = interStrokeGap

        var starts = [Double]()
        var durations = [Double]()
        starts.reserveCapacity(session.strokes.count)
        durations.reserveCapacity(session.strokes.count)

        var cursor = 0.0
        for stroke in session.strokes {
            let d = Double(stroke.points.last.map { $0.timestamp - (stroke.points.first?.timestamp ?? 0) } ?? 0)
            starts.append(cursor)
            durations.append(d)
            cursor += d + interStrokeGap
        }
        self.starts = starts
        self.durations = durations
        self.duration = max(cursor - interStrokeGap, 0)
    }

    /// The drawing as it looked `time` seconds into its creation: all earlier
    /// strokes complete, plus the partially-drawn current stroke.
    public func snapshot(at time: Double) -> DrawingSession {
        var out = DrawingSession(canvasSize: session.canvasSize)
        guard time > 0 else { return out }

        for (i, stroke) in session.strokes.enumerated() {
            let start = starts[i]
            if start >= time { break }                      // not started yet
            if start + durations[i] <= time {
                out.commit(stroke)                          // fully drawn
                continue
            }
            // In progress: include points whose absolute time has elapsed.
            let base = Double(stroke.points.first?.timestamp ?? 0)
            var partial = stroke
            partial.points = stroke.points.filter { start + (Double($0.timestamp) - base) <= time }
            if !partial.points.isEmpty { out.commit(partial) }
        }
        return out
    }

    /// Fraction 0…1 of the replay complete at `time`.
    public func progress(at time: Double) -> Double {
        guard duration > 0 else { return 1 }
        return min(max(time / duration, 0), 1)
    }
}
