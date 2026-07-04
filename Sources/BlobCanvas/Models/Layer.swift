import Foundation

/// A named, independently-composited group of strokes. Layers paint bottom-up
/// in array order; each has its own opacity and visibility.
public struct Layer: Hashable, Sendable {
    public var name: String
    public var strokes: [Stroke]
    /// Group opacity 0…1, applied to the whole layer at composite time.
    public var opacity: Float
    public var isVisible: Bool

    public init(name: String = "Layer", strokes: [Stroke] = [], opacity: Float = 1, isVisible: Bool = true) {
        self.name = name
        self.strokes = strokes
        self.opacity = opacity
        self.isVisible = isVisible
    }
}
