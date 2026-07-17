import Foundation

/// Stateful encoder that avoids re-serializing the whole drawing on every save.
///
/// The one-shot `DrawingSession.serialized()` re-encodes and re-compresses every
/// stroke each call — O(all strokes) per save, which is O(n²) across a long
/// drawing session that autosaves after each stroke. This encoder keeps each
/// layer's strokes as a list of compressed **frames** and, on `encode`, only
/// compresses the strokes appended since the last save, appending a new frame.
///
/// Structural edits (undo, clearing, layer add/remove) re-compact the affected
/// layer(s) into a single frame — correct, just not incremental for that save.
///
/// Output is a v5 blob, decodable by the normal `DrawingBlobCodec.decode`.
///
/// Usage: keep one encoder per open drawing and call `encode(session)` from your
/// debounced auto-save instead of `session.serialized()`.
///
/// - Important: **Not thread-safe** (B7). `cache` is mutated without
///   synchronization, so drive one encoder from a single executor (the main
///   actor, or one serial queue). Calling `encode` concurrently races the cache.
public final class IncrementalDrawingEncoder {

    /// Strokes are sealed into an immutable frame once this many accumulate,
    /// amortizing per-frame LZFSE overhead. Below the threshold, the open tail
    /// is cheap to re-encode each save.
    public let sealThreshold: Int

    private struct LayerFrames {
        /// Immutable, already-compressed frames of `sealThreshold` strokes each.
        var sealed: [Data] = []
        /// Number of strokes captured in `sealed`.
        var sealedCount: Int = 0
        /// The strokes of the LAST sealed frame (up to `sealThreshold`). An undo
        /// past the seal boundary + redraw can restore the count between saves;
        /// the count alone can't detect it. Comparing only the single boundary
        /// stroke missed the case where a *programmatic* redraw reproduces a
        /// byte-identical boundary stroke over a changed prefix (B4). Comparing
        /// the whole last frame catches any change within the last sealed chunk.
        var boundary: [Stroke] = []
    }

    /// Keyed by `Layer.id`, so sealed frames follow their layer across
    /// insertion, reordering, and removal — never misaligned by index.
    private var cache: [UUID: LayerFrames] = [:]

    public init(sealThreshold: Int = 48) {
        self.sealThreshold = max(sealThreshold, 1)
    }

    /// Drops all cached frames; the next `encode` re-encodes from scratch.
    public func reset() { cache.removeAll(keepingCapacity: true) }

    public func encode(_ session: DrawingSession) -> Data {
        var meta: [(name: String, opacity: Float, isVisible: Bool, frames: [Data])] = []
        meta.reserveCapacity(session.layers.count)
        var live = Set<UUID>()

        for layer in session.layers {
            live.insert(layer.id)
            var state = cache[layer.id] ?? LayerFrames()
            let strokes = layer.strokes
            let current = strokes.count

            // Undo past a seal boundary invalidates sealed frames — rebuild.
            // The count comparison alone misses undo + redraw sequences that
            // restore the count between saves, so also verify the LAST sealed
            // frame is byte-identical to what we sealed (B4): redo restores it,
            // a changed prefix won't match even if the final stroke coincides.
            if current < state.sealedCount {
                state = LayerFrames()
            } else if state.sealedCount > 0 {
                let lo = state.sealedCount - state.boundary.count
                if lo < 0 || Array(strokes[lo..<state.sealedCount]) != state.boundary {
                    state = LayerFrames()
                }
            }

            // Seal full chunks that have accumulated since last time.
            while current - state.sealedCount >= sealThreshold {
                let start = state.sealedCount
                let slice = strokes[start..<(start + sealThreshold)]
                state.sealed.append(DrawingBlobCodec.encodeFrame(slice, count: sealThreshold))
                state.sealedCount += sealThreshold
            }
            if state.sealedCount > 0 {
                let lo = max(0, state.sealedCount - sealThreshold)
                state.boundary = Array(strokes[lo..<state.sealedCount])
            }
            cache[layer.id] = state

            // Sealed frames + a freshly-encoded (small) tail.
            var frames = state.sealed
            let tailCount = current - state.sealedCount
            if tailCount > 0 {
                frames.append(DrawingBlobCodec.encodeFrame(strokes[state.sealedCount..<current], count: tailCount))
            }
            meta.append((name: layer.name, opacity: layer.opacity, isVisible: layer.isVisible, frames: frames))
        }

        // Forget layers that were removed.
        cache = cache.filter { live.contains($0.key) }

        return DrawingBlobCodec.assembleV5(canvasSize: session.canvasSize,
                                           activeLayerIndex: session.activeLayerIndex,
                                           layers: meta)
    }
}
