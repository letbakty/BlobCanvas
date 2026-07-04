import Foundation

/// The complete in-memory state of a drawing: committed strokes plus the
/// undo/redo stacks. Pure value type — undo/redo are O(1) array mutations
/// that never touch the persistent store. Serialize with
/// ``serialized()`` / ``init(serialized:)`` only on auto-save or export.
public struct DrawingSession: Sendable {
    /// Logical canvas size in points. Fixed for the lifetime of a drawing
    /// (Sloppy Forgeries-style fixed easel).
    public var canvasSize: SIMD2<Float>

    /// Strokes currently visible, in paint order.
    public private(set) var strokes: [Stroke]

    /// Strokes removed by undo, most-recently-undone last.
    private var redoStack: [Stroke]

    public init(canvasSize: SIMD2<Float> = SIMD2(1024, 768), strokes: [Stroke] = []) {
        self.canvasSize = canvasSize
        self.strokes = strokes
        self.redoStack = []
        self.strokes.reserveCapacity(max(64, strokes.count))
    }

    // MARK: - Mutation

    /// Commits a finished stroke. Any redo history is invalidated, matching
    /// standard editor semantics.
    public mutating func commit(_ stroke: Stroke) {
        guard !stroke.points.isEmpty else { return }
        strokes.append(stroke)
        if !redoStack.isEmpty { redoStack.removeAll(keepingCapacity: true) }
    }

    public mutating func clear() {
        strokes.removeAll(keepingCapacity: true)
        redoStack.removeAll(keepingCapacity: true)
    }

    // MARK: - Undo / Redo

    public var canUndo: Bool { !strokes.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    /// Moves the newest stroke onto the redo stack. O(1), allocation-free.
    /// - Returns: true if a stroke was undone.
    @discardableResult
    public mutating func undo() -> Bool {
        guard let last = strokes.popLast() else { return false }
        redoStack.append(last)
        return true
    }

    /// Restores the most recently undone stroke. O(1), allocation-free.
    /// - Returns: true if a stroke was restored.
    @discardableResult
    public mutating func redo() -> Bool {
        guard let stroke = redoStack.popLast() else { return false }
        strokes.append(stroke)
        return true
    }

    // MARK: - Stats

    public var pointCount: Int {
        strokes.reduce(0) { $0 + $1.points.count }
    }
}
