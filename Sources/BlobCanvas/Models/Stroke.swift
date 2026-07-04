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

    /// CGColor interpreting the RGBA components in `space` — pass a Display P3
    /// space to paint into a wide-gamut context (the same encoded values then
    /// span the wider gamut). Falls back to sRGB if construction fails.
    public func cgColor(in space: CGColorSpace) -> CGColor {
        CGColor(colorSpace: space,
                components: [CGFloat(r) / 255, CGFloat(g) / 255, CGFloat(b) / 255, CGFloat(a) / 255]) ?? cgColor
    }
}

/// How a stroke composites onto what is already drawn.
public enum BlendMode: UInt8, Hashable, Sendable {
    case normal = 0
    /// Eraser: clears pixels (renders with `.clear`).
    case erase = 1
}

/// What modulates a stroke's width along its length.
public enum WidthDynamics: UInt8, Hashable, Sendable {
    /// Width follows per-point pressure (default).
    case pressure = 0
    /// Width follows drawing speed — faster is thinner (calligraphic feel).
    case velocity = 1
    /// Constant `brushSize`, ignoring pressure and speed.
    case constant = 2
}

/// One vector stroke: an ordered run of points plus its brush parameters.
public struct Stroke: Hashable, Sendable {
    public var points: [StrokePoint]
    public var color: StrokeColor
    /// Brush diameter in canvas points.
    public var brushSize: Float
    public var blendMode: BlendMode
    public var dynamics: WidthDynamics

    public init(
        points: [StrokePoint] = [],
        color: StrokeColor = .black,
        brushSize: Float = 8,
        blendMode: BlendMode = .normal,
        dynamics: WidthDynamics = .pressure
    ) {
        self.points = points
        self.color = color
        self.brushSize = brushSize
        self.blendMode = blendMode
        self.dynamics = dynamics
    }

    @inlinable
    public mutating func append(_ point: StrokePoint) {
        points.append(point)
    }
}
