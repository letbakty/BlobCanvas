import Foundation
import CoreGraphics

/// Platform-neutral sRGB color, 4 bytes when serialized.
public struct StrokeColor: Hashable, Sendable {
    public var r: UInt8
    public var g: UInt8
    public var b: UInt8
    public var a: UInt8

    @inlinable
    public init(r: UInt8, g: UInt8, b: UInt8, a: UInt8 = 255) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    public static let black = StrokeColor(r: 0, g: 0, b: 0)
    public static let white = StrokeColor(r: 255, g: 255, b: 255)

    /// CGColor in sRGB. Created lazily at draw time, never inside the point loop.
    public var cgColor: CGColor {
        CGColor(
            srgbRed: CGFloat(r) / 255,
            green: CGFloat(g) / 255,
            blue: CGFloat(b) / 255,
            alpha: CGFloat(a) / 255
        )
    }
}

/// One vector stroke: an ordered run of points plus its brush parameters.
public struct Stroke: Hashable, Sendable {
    public var points: [StrokePoint]
    public var color: StrokeColor
    /// Brush diameter in canvas points.
    public var brushSize: Float

    public init(points: [StrokePoint] = [], color: StrokeColor = .black, brushSize: Float = 8) {
        self.points = points
        self.color = color
        self.brushSize = brushSize
    }

    @inlinable
    public mutating func append(_ point: StrokePoint) {
        points.append(point)
    }
}
