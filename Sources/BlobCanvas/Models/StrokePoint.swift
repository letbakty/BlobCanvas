import Foundation

/// A single sampled input point.
///
/// Deliberately a trivially-copyable value type (`Float` fields only) so that
/// arrays of points are contiguous, cache-friendly, and can be serialized with
/// straight memory copies — no per-point object allocations anywhere.
public struct StrokePoint: Hashable, Sendable {
    /// Position in canvas coordinate space (points, not pixels).
    public var x: Float
    public var y: Float
    /// Normalized pressure 0...1. Defaults to 1 for devices without pressure.
    public var pressure: Float
    /// Seconds since the start of the stroke. Float32 gives sub-millisecond
    /// precision for any realistic stroke duration and halves storage vs Double.
    public var timestamp: Float

    @inlinable
    public init(x: Float, y: Float, pressure: Float = 1.0, timestamp: Float = 0) {
        self.x = x
        self.y = y
        self.pressure = pressure
        self.timestamp = timestamp
    }

    @inlinable
    public init(x: CGFloat, y: CGFloat, pressure: CGFloat = 1.0, timestamp: Float = 0) {
        self.init(x: Float(x), y: Float(y), pressure: Float(pressure), timestamp: timestamp)
    }

    @inlinable
    public var cgPoint: CGPoint { CGPoint(x: CGFloat(x), y: CGFloat(y)) }
}
