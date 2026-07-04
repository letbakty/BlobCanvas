import Foundation

/// A named, independently-composited group of strokes. Layers paint bottom-up
/// in array order; each has its own opacity and visibility.
public struct Layer: Hashable, Sendable, Identifiable {
    /// Stable in-memory identity, preserved across mutations (opacity/visibility
    /// edits, reordering). Used to key incremental-save caches so frames follow
    /// their layer even when layers are inserted/moved. Not serialized —
    /// equality and the blob format compare content only.
    public let id: UUID
    public var name: String
    public var strokes: [Stroke]
    /// Group opacity 0…1, applied to the whole layer at composite time.
    public var opacity: Float
    public var isVisible: Bool

    public init(id: UUID = UUID(), name: String = "Layer", strokes: [Stroke] = [],
                opacity: Float = 1, isVisible: Bool = true) {
        self.id = id
        self.name = name
        self.strokes = strokes
        self.opacity = opacity
        self.isVisible = isVisible
    }

    // Equality/hashing ignore `id` — two layers with the same content are equal,
    // so round-trip decode (which mints fresh ids) still compares equal.
    public static func == (lhs: Layer, rhs: Layer) -> Bool {
        lhs.name == rhs.name && lhs.strokes == rhs.strokes
            && lhs.opacity == rhs.opacity && lhs.isVisible == rhs.isVisible
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(name)
        hasher.combine(strokes)
        hasher.combine(opacity)
        hasher.combine(isVisible)
    }
}
