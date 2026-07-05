# BlobCanvas — Architecture

Deep reference for the drawing engine. For the quick map see [AGENTS.md](../AGENTS.md); for usage see [README.md](../README.md).

## Layers of the system

```
Input (touch / pencil / mouse, 120 Hz coalesced + predicted)
        │  view point ──► CanvasViewport.viewToCanvas ──► canvas point
        ▼
CanvasEngineView ── incremental joint ──► live buffer (opaque)
        │            predicted tail ────► predicted buffer
        │            eraser ────────────► committed buffer (destination-out)
        ▼  commit
DrawingSession  (layers → strokes; O(1) undo/redo on active layer)
        │  StrokeRasterizer.draw  (smoothed ribbon, single fillPath)
        ▼
committed buffer ──► present() blits committed + live + predicted (zoom/pan)
        │
        │  auto-save (debounced, off-main)
        ▼
DrawingBlobCodec / IncrementalDrawingEncoder  (delta+quantized, LZFSE)
        ▼
Drawing.compressedData  (SwiftData @Model, .externalStorage — one row per drawing)
```

Data-flow one-liner: **input → canvas-space points → DrawingSession (layers of strokes) → StrokeRasterizer geometry → pixel buffers on screen, and → binary blob on disk.**

## Code graph (module dependencies)

Grouped by directory; arrows mean "uses / depends on". Foundation value types at the bottom, UI at the top. Generated from the actual imports/type references.

```mermaid
graph TD
    subgraph Views
        BlobCanvasView
        BlobCanvasController
        CanvasEngineView
    end
    subgraph Persistence
        Drawing["Drawing (@Model)"]
    end
    subgraph Rendering
        StrokeRasterizer
        SessionImageRenderer["SessionImageRenderer (protocol)"]
        CoreGraphicsRenderer
        MetalSessionRenderer
        CanvasViewport
        DrawingExporter
        DrawingPlayer
    end
    subgraph Serialization
        DrawingBlobCodec
        IncrementalDrawingEncoder
    end
    subgraph Models
        DrawingSession
        Layer
        Stroke
        StrokePoint
        StrokeColor
        BlendMode
        WidthDynamics
    end

    BlobCanvasView --> BlobCanvasController
    BlobCanvasView --> CanvasEngineView
    BlobCanvasController --> CanvasEngineView
    CanvasEngineView --> StrokeRasterizer
    CanvasEngineView --> CanvasViewport
    CanvasEngineView --> DrawingSession

    Drawing --> DrawingBlobCodec
    Drawing --> DrawingExporter
    Drawing --> DrawingSession

    DrawingExporter --> StrokeRasterizer
    DrawingExporter --> DrawingSession
    DrawingPlayer --> DrawingSession
    CoreGraphicsRenderer --> StrokeRasterizer
    CoreGraphicsRenderer -.implements.-> SessionImageRenderer
    MetalSessionRenderer -.implements.-> SessionImageRenderer
    MetalSessionRenderer --> StrokeRasterizer
    MetalSessionRenderer --> DrawingSession
    StrokeRasterizer --> Stroke
    StrokeRasterizer --> DrawingSession

    IncrementalDrawingEncoder --> DrawingBlobCodec
    DrawingBlobCodec --> DrawingSession
    DrawingBlobCodec --> Layer

    DrawingSession --> Layer
    Layer --> Stroke
    Stroke --> StrokePoint
    Stroke --> StrokeColor
    Stroke --> BlendMode
    Stroke --> WidthDynamics
```

Key property: **`Models` and `Rendering` have no UIKit/AppKit dependency**, so they're unit-tested headlessly (the golden-pixel render tests run without a view). Only `Views/` touches UIKit/AppKit.

## Rendering pipeline (Core Graphics)

`CanvasEngineView` owns three `CanvasBuffer`s, each an owned pixel buffer presented as a zero-copy `CGImage` over a persistent `CGDataProvider` (no per-frame `makeImage()` snapshot copy):

| Buffer | Holds | Written by |
|---|---|---|
| `committed` | all finished strokes, flattened | `rebake()` / `endStroke` fast-path / live eraser |
| `live` | current in-progress stroke (opaque) | `appendLivePoint` incremental joint |
| `predicted` | forecast tail from `predictedTouches` | `renderPredicted`, cleared each event |

`present()` blits `committed` (α=1) + `live` (α=brush alpha) + `predicted` (α=brush alpha) into the `CanvasViewport.drawnRect`. Translucency is correct because a whole stroke is one `fillPath` (single coverage) and the live overlay is composited once with its alpha.

`StrokeRasterizer` is the single source of ribbon geometry: circles at points + trapezoids between them, Catmull-Rom smoothing on commit, width from pressure/velocity/constant, `.normal`/`.erase` blend, and per-layer compositing (transparency groups so erasers stay layer-local).

## Persistence & format

`DrawingBlobCodec` encodes a `DrawingSession` to `Drawing.compressedData` (`.externalStorage`). Points are quantized (1/32 pt, 8-bit pressure, 1 ms) and zig-zag-varint delta-coded, then LZFSE-compressed — several× smaller than raw `Float32` on real input.

Versions (all still decodable — `decode` dispatches per version):

| Version | Points | Structure |
|---|---|---|
| v1 | raw `Float32×4` | flat strokes |
| v2 | delta-varint | flat strokes, no flags |
| v3 | delta-varint | flat strokes + per-stroke flags |
| v4 | delta-varint | **layers** (current one-shot format) |
| v5 | delta-varint | **incremental**: per-layer sealed frames |

`IncrementalDrawingEncoder` (one per open drawing) seals strokes into compressed frames of `sealThreshold` (48) each; a save re-encodes only the small open tail, so autosave-per-stroke is not O(n²). Undo past a seal or layer removal re-compacts.

## Testing strategy

- **Codec:** round-trip (tolerance), stable re-encode (idempotent), legacy v1/v2 decode, implausible-count rejection, **fuzzing** (3000 hostile/corrupted decodes must never trap) via a seeded SplitMix64 RNG, and **safety hardening** (`CodecSafetyTests`: NaN/Inf canvas & brush, amplified counts, huge frame lengths, Int64 accumulator overflow — none may trap or OOM).
- **Incremental:** matches one-shot, undo recompacts, multi-layer, sealed frames reused.
- **Rendering (headless golden-pixel):** render session → `CGImage` → read a pixel → assert channels. Covers CG and Metal (skipped without a GPU), eraser clears, background fill, scale, layer opacity/visibility, and CG↔Metal agreement for opaque strokes.
- **Viewport:** fit centering, round-trip mapping, focal-point-preserving zoom, clamping.

## Improvements / known gaps

Recently closed: crisp zoom (canvas re-baked at the zoom's resolution, capped by `maxBackingPixels`), O(1) undo (opt-in `undoCheckpointDepth` pixel-checkpoint ring, rebake fallback), Intel-safe Metal read-back (render `.private` → blit → shared buffer), incremental encoder keyed by `Layer.id` (insert/reorder-safe), Metal smoothing + radius-scaled caps, Display P3 export.

Still open, all device-bound: live `CAMetalLayer` view path (offscreen `MetalSessionRenderer` is the foundation), IOSurface presentation, canvas tiling. The Metal path also lacks per-stroke single-coverage translucency and layer group opacity — opaque strokes match the CG renderer; translucent ones can double-blend.
