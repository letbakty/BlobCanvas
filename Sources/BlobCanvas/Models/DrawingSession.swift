import Foundation

/// The complete in-memory state of a drawing: a stack of layers plus the
/// undo/redo stacks for the active layer. Pure value type — undo/redo are O(1)
/// array mutations that never touch the persistent store. Serialize with
/// ``serialized()`` / ``init(serialized:)`` only on auto-save or export.
///
/// Single-layer drawings behave exactly as before: `strokes`, `commit`,
/// `undo`/`redo` all target the active layer, which for a fresh session is the
/// one and only layer.
public struct DrawingSession: Sendable {
    /// Logical canvas size in points. Fixed for the lifetime of a drawing
    /// (Sloppy Forgeries-style fixed easel).
    public var canvasSize: SIMD2<Float>

    /// Layer stack, painted bottom-up.
    public private(set) var layers: [Layer]
    public private(set) var activeLayerIndex: Int

    /// Strokes removed by undo from the active layer, most-recent last.
    /// Cleared whenever the active layer changes.
    private var redoStack: [Stroke]

    public init(canvasSize: SIMD2<Float> = SIMD2(1024, 768), strokes: [Stroke] = []) {
        self.canvasSize = canvasSize
        self.layers = [Layer(name: "Layer 1", strokes: strokes)]
        self.activeLayerIndex = 0
        self.redoStack = []
    }

    public init(canvasSize: SIMD2<Float>, layers: [Layer], activeLayerIndex: Int = 0) {
        self.canvasSize = canvasSize
        self.layers = layers.isEmpty ? [Layer(name: "Layer 1")] : layers
        self.activeLayerIndex = min(max(activeLayerIndex, 0), self.layers.count - 1)
        self.redoStack = []
    }

    // MARK: - Active layer

    public var activeLayer: Layer { layers[activeLayerIndex] }

    /// Strokes of the active layer, in paint order.
    public var strokes: [Stroke] { layers[activeLayerIndex].strokes }

    /// Every stroke across all layers in composite (bottom-up) order.
    public var allStrokes: [Stroke] { layers.flatMap(\.strokes) }

    /// Patches the pressure of one already-committed point. Used to apply Apple
    /// Pencil force estimates that arrive *after* the stroke was committed (B5),
    /// so the saved drawing keeps true pressure instead of the estimate. No-op if
    /// indices are stale.
    public mutating func updatePressure(layer li: Int, stroke si: Int, point pi: Int, to pressure: Float) {
        guard layers.indices.contains(li),
              layers[li].strokes.indices.contains(si),
              layers[li].strokes[si].points.indices.contains(pi) else { return }
        layers[li].strokes[si].points[pi].pressure = pressure
    }

    // MARK: - Layer management

    @discardableResult
    public mutating func addLayer(name: String? = nil) -> Int {
        let layerName = name ?? "Layer \(layers.count + 1)"
        layers.append(Layer(name: layerName))
        activeLayerIndex = layers.count - 1
        redoStack.removeAll(keepingCapacity: true)
        return activeLayerIndex
    }

    public mutating func setActiveLayer(_ index: Int) {
        guard layers.indices.contains(index), index != activeLayerIndex else { return }
        activeLayerIndex = index
        redoStack.removeAll(keepingCapacity: true)
    }

    /// Removes the active layer (no-op if it's the last remaining one).
    public mutating func removeActiveLayer() {
        guard layers.count > 1 else { return }
        layers.remove(at: activeLayerIndex)
        activeLayerIndex = min(activeLayerIndex, layers.count - 1)
        redoStack.removeAll(keepingCapacity: true)
    }

    /// Moves a layer within the stack (reorders paint order). The active layer
    /// follows the same layer identity.
    public mutating func moveLayer(from source: Int, to destination: Int) {
        guard layers.indices.contains(source),
              destination >= 0, destination < layers.count, source != destination else { return }
        let activeID = layers[activeLayerIndex].id
        let layer = layers.remove(at: source)
        layers.insert(layer, at: destination)
        if let newActive = layers.firstIndex(where: { $0.id == activeID }) {
            activeLayerIndex = newActive
        }
        redoStack.removeAll(keepingCapacity: true)
    }

    public mutating func setOpacity(_ opacity: Float, ofLayer index: Int) {
        guard layers.indices.contains(index) else { return }
        layers[index].opacity = min(max(opacity, 0), 1)
    }

    public mutating func setVisible(_ visible: Bool, ofLayer index: Int) {
        guard layers.indices.contains(index) else { return }
        layers[index].isVisible = visible
    }

    /// Whether committing to the active layer produces a result that can be
    /// composited by simply drawing on top of everything else — i.e. the active
    /// layer is the topmost, fully opaque, visible one. Lets the renderer skip a
    /// full re-bake on commit.
    public var activeLayerIsTopOpaque: Bool {
        activeLayerIndex == layers.count - 1
            && activeLayer.opacity >= 0.999
            && activeLayer.isVisible
    }

    // MARK: - Mutation (active layer)

    /// Commits a finished stroke to the active layer. Redo history is
    /// invalidated, matching standard editor semantics.
    public mutating func commit(_ stroke: Stroke) {
        guard !stroke.points.isEmpty else { return }
        layers[activeLayerIndex].strokes.append(stroke)
        if !redoStack.isEmpty { redoStack.removeAll(keepingCapacity: true) }
    }

    /// Clears the active layer.
    public mutating func clear() {
        layers[activeLayerIndex].strokes.removeAll(keepingCapacity: true)
        redoStack.removeAll(keepingCapacity: true)
    }

    // MARK: - Undo / Redo (active layer)

    public var canUndo: Bool { !activeLayer.strokes.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    /// Moves the active layer's newest stroke onto the redo stack. O(1).
    @discardableResult
    public mutating func undo() -> Bool {
        guard let last = layers[activeLayerIndex].strokes.popLast() else { return false }
        redoStack.append(last)
        return true
    }

    /// Restores the most recently undone stroke to the active layer. O(1).
    @discardableResult
    public mutating func redo() -> Bool {
        guard let stroke = redoStack.popLast() else { return false }
        layers[activeLayerIndex].strokes.append(stroke)
        return true
    }

    // MARK: - Stats

    public var pointCount: Int {
        layers.reduce(0) { $0 + $1.strokes.reduce(0) { $0 + $1.points.count } }
    }
}
