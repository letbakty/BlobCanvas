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
    }

    private var layers: [LayerFrames] = []

    public init(sealThreshold: Int = 48) {
        self.sealThreshold = max(sealThreshold, 1)
    }

    /// Drops all cached frames; the next `encode` re-encodes from scratch.
    public func reset() { layers.removeAll(keepingCapacity: true) }

    public func encode(_ session: DrawingSession) -> Data {
        reconcileLayerCount(session)

        var meta: [(name: String, opacity: Float, isVisible: Bool, frames: [Data])] = []
        meta.reserveCapacity(session.layers.count)

        for (i, layer) in session.layers.enumerated() {
            let strokes = layer.strokes
            let current = strokes.count

            // Undo past a seal boundary invalidates sealed frames — rebuild.
            if current < layers[i].sealedCount { layers[i] = LayerFrames() }

            // Seal full chunks that have accumulated since last time.
            while current - layers[i].sealedCount >= sealThreshold {
                let start = layers[i].sealedCount
                let slice = strokes[start..<(start + sealThreshold)]
                layers[i].sealed.append(DrawingBlobCodec.encodeFrame(slice, count: sealThreshold))
                layers[i].sealedCount += sealThreshold
            }

            // Sealed frames + a freshly-encoded (small) tail.
            var frames = layers[i].sealed
            let tailCount = current - layers[i].sealedCount
            if tailCount > 0 {
                frames.append(DrawingBlobCodec.encodeFrame(strokes[layers[i].sealedCount..<current], count: tailCount))
            }
            meta.append((name: layer.name, opacity: layer.opacity, isVisible: layer.isVisible, frames: frames))
        }

        return DrawingBlobCodec.assembleV5(canvasSize: session.canvasSize,
                                           activeLayerIndex: session.activeLayerIndex,
                                           layers: meta)
    }

    // MARK: - Private

    /// Rebuilds cache slots when layers were added/removed. Existing slots keep
    /// their sealed frames (index-stable common case: appending a layer).
    private func reconcileLayerCount(_ session: DrawingSession) {
        if layers.count == session.layers.count { return }
        if layers.count < session.layers.count {
            layers.append(contentsOf: Array(repeating: LayerFrames(), count: session.layers.count - layers.count))
        } else {
            // A layer was removed; index mapping is ambiguous, so re-seal all.
            layers = Array(repeating: LayerFrames(), count: session.layers.count)
        }
    }
}
