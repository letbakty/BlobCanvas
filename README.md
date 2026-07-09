# BlobCanvas

A high-performance, stroke-based vector drawing engine for iOS 17+ and macOS 14+, inspired by *Sloppy Forgeries*. Fast-paced drawing on a fixed-size canvas, with the entire drawing history persisted as a **single compressed binary blob** in SwiftData — no relational stroke/point models, near-zero store overhead.

## Architecture

```
Input (touch/mouse, 120 Hz coalesced)
        │ appendLivePoint — O(1), allocation-free
        ▼
CanvasEngineView ──── incremental segment strokes ───▶ offscreen CGBitmapContext
        │                                                    │ blit (dirty rect only)
        ▼                                                    ▼
DrawingSession (in-memory [Stroke] + redo stack)        on-screen layer
        │ serialize on auto-save / export only
        ▼
DrawingBlobCodec (flat binary + LZFSE)
        ▼
@Model Drawing { compressedData: Data }   ← one row per drawing, .externalStorage
```

| Component | File | Role |
|---|---|---|
| `StrokePoint` | [StrokePoint.swift](Sources/BlobCanvas/Models/StrokePoint.swift) | 16-byte POD point (x, y, pressure, timestamp) |
| `Stroke` / `StrokeColor` | [Stroke.swift](Sources/BlobCanvas/Models/Stroke.swift) | Point run + RGBA color + brush size |
| `DrawingSession` | [DrawingSession.swift](Sources/BlobCanvas/Models/DrawingSession.swift) | In-memory state, O(1) undo/redo stacks |
| `DrawingBlobCodec` | [DrawingBlobCodec.swift](Sources/BlobCanvas/Serialization/DrawingBlobCodec.swift) | Delta+quantized binary (v4, layers) + LZFSE; v1–v3 & v5 decode |
| `IncrementalDrawingEncoder` | [IncrementalDrawingEncoder.swift](Sources/BlobCanvas/Serialization/IncrementalDrawingEncoder.swift) | Append-only save (v5 sealed frames) — no O(n²) re-encode |
| `Drawing` | [Drawing.swift](Sources/BlobCanvas/Persistence/Drawing.swift) | SwiftData `@Model`: blob + thumbnail + metadata |
| `Layer` | [Layer.swift](Sources/BlobCanvas/Models/Layer.swift) | Named group of strokes with opacity + visibility |
| `StrokeRasterizer` | [StrokeRasterizer.swift](Sources/BlobCanvas/Rendering/StrokeRasterizer.swift) | Pure CG geometry: smoothing, velocity width, blend modes, layer compositing |
| `SessionImageRenderer` | [SessionImageRenderer.swift](Sources/BlobCanvas/Rendering/SessionImageRenderer.swift) | Renderer protocol; `CoreGraphicsRenderer` default |
| `MetalSessionRenderer` | [MetalSessionRenderer.swift](Sources/BlobCanvas/Rendering/MetalSessionRenderer.swift) | GPU offscreen rasterizer (tessellated ribbons → texture) |
| `CanvasViewport` | [CanvasViewport.swift](Sources/BlobCanvas/Rendering/CanvasViewport.swift) | Testable canvas↔view transform with zoom/pan |
| `DrawingExporter` | [DrawingExporter.swift](Sources/BlobCanvas/Rendering/DrawingExporter.swift) | PNG / PDF / SVG / thumbnail export |
| `DrawingPlayer` | [DrawingPlayer.swift](Sources/BlobCanvas/Rendering/DrawingPlayer.swift) | Timestamp-driven replay of drawing creation |
| `CanvasEngineView` | [CanvasEngineView.swift](Sources/BlobCanvas/Views/CanvasEngineView.swift) | Bitmap-backed renderer, UIKit/AppKit input |
| `BlobCanvasView` | [BlobCanvasView.swift](Sources/BlobCanvas/Views/BlobCanvasView.swift) | SwiftUI wrapper + `BlobCanvasController` |

## Brushes & features

- **Layers.** `controller.addLayer()` / `setLayerOpacity` / `setLayerVisible` / `setActiveLayer`. Undo/redo is per active layer; erasers are layer-local (they only clear within their own layer).
- **Blend modes.** `brushBlendMode = .erase` clears pixels in real time; erasers persist as strokes (undoable).
- **Width dynamics.** `brushDynamics` is `.pressure` (default), `.velocity` (faster = thinner, calligraphic), or `.constant`.
- **Smoothing.** Committed strokes are Catmull-Rom interpolated (`smoothing`), while the live preview stays polyline for latency.
- **Palm rejection.** `pencilOnly = true` draws only from Apple Pencil, ignoring finger/palm touches.
- **Zoom & pan.** Pinch + two-finger pan (iOS), trackpad magnify + scroll (macOS), or programmatic `zoom(by:at:)` / `pan(by:)` / `resetZoom()`.
- **Export.** `DrawingExporter.pngData / pdfData / svgString / thumbnailPNG` — all composite every visible layer (with layer opacity).
- **Replay.** `DrawingPlayer(session).snapshot(at:)` reconstructs the drawing at any point in its creation from the captured timestamps, preserving the layer stack (opacity/visibility) so the animation composites like the finished drawing.

## Persistence performance

- **Incremental save.** Keep one `IncrementalDrawingEncoder` per open drawing and call `encoder.encode(session)` from your debounced auto-save. Strokes are sealed into compressed frames in chunks; each save re-encodes only the small open tail, so a long session doesn't pay O(n) per stroke. Structural edits (undo past a seal, layer removal) re-compact automatically. Output is a normal blob decoded by `DrawingSession(serialized:)`.
- **Off-main encode.** `await drawing.save(session)` / `save(_:thumbnailMaxDimension:)` compress on a background task.

## Not yet (needs on-device verification)

The offscreen Metal renderer above is done and GPU-tested (smoothing, per-layer group opacity, layer-local erase). What remains is inherently device-bound:

- **Live `CAMetalLayer` view path** — driving `CanvasEngineView` on the GPU at 120 Hz (vs the current Core Graphics buffers) needs real-device frame validation; the offscreen `MetalSessionRenderer` is the foundation.
- **IOSurface presentation & canvas tiling** — for very large canvases; the current owned-buffer + provider path already avoids per-frame copies at normal sizes.
- **Per-stroke single-coverage translucency in Metal** — a translucent stroke's self-overlaps can double-blend on the GPU (the Core Graphics renderer handles this via a single fill).

## Testing

`swift test` runs 81 tests: codec round-trip/fuzz (3000 hostile-input decodes) and safety hardening (NaN/Inf, amplified counts, overflow), incremental-encoder correctness (incl. undo-then-redraw at a seal boundary), headless golden-pixel checks for both renderers (including Metal layer opacity & layer-local erase), stroke coverage vs a `CGContext.strokePath` reference (no winding holes), layer compositing, undo-checkpoint restore (incl. cross-layer invalidation), controller state seeding on load, viewport/zoom math (incl. the pixel-budget ceiling), all-layer export, and layer-preserving replay. Requires the Xcode 16 toolchain (Swift 6):

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

## Why it's fast

- **Two-buffer incremental rendering.** `committed` holds all finished strokes; `live` holds the in-progress stroke. Each new point fills only its new joint into `live` and invalidates just that dirty rect. On commit the stroke is flattened into `committed` as a single filled ribbon. Per-frame cost is constant regardless of total point count.
- **Zero per-frame copy.** Both buffers own their pixel memory and are presented as lightweight `CGImage`s over a persistent `CGDataProvider` — no `makeImage()` snapshot copy on the draw path.
- **Correct translucency.** A stroke is rendered as one `fillPath`, so self-overlaps never double-blend; translucent brushes stay uniform with no beading at sample points. The live stroke is drawn opaque and composited once with the brush's alpha at present time.
- **Fixed logical canvas.** Strokes live in device-independent canvas coordinates; the view aspect-fits them into its bounds, so a drawing opens identically on any screen size.
- **Low-latency Pencil input** on iOS: coalesced touches capture the full 120/240 Hz sample stream, predicted touches draw a forecast tail (~1 frame less perceived lag), and late-arriving estimated force values patch already-recorded points so pressure is correct from the first sample.
- **Compact delta encoding.** Points are quantized (1/32 pt, 8-bit pressure, 1 ms) and stored as zig-zag varint deltas, then LZFSE-compressed off the main actor via `drawing.save(session)` — several times smaller than raw `Float32` on real input. Legacy v1 blobs still decode.

## Usage

```swift
import SwiftUI
import SwiftData
import BlobCanvas

struct EaselView: View {
    @Environment(\.modelContext) private var context
    @State private var controller = BlobCanvasController()
    let drawing: Drawing

    var body: some View {
        BlobCanvasView(
            controller: controller,
            brushColor: StrokeColor(r: 30, g: 30, b: 30),
            brushSize: 10,
            session: try? drawing.makeSession()   // decode blob once on open
        )
        .toolbar {
            Button("Undo") { controller.undo() }.disabled(!controller.canUndo)
            Button("Redo") { controller.redo() }.disabled(!controller.canRedo)
        }
        .onAppear {
            // Debounced auto-save: history changes never touch the store directly.
            controller.onSessionChanged = { session in
                Task {
                    await drawing.save(session)   // encode blob off-main, bump modifiedAt
                    try? context.save()
                }
            }
        }
    }
}
```

Container setup:

```swift
.modelContainer(for: Drawing.self)
```

## Binary format (v4)

```
"BLBC" | version u16 | algorithm u8 (0 raw, 1 LZFSE) | payload…
payload: canvasW f32 | canvasH f32 | activeLayer varint | layerCount varint
  per layer: name(varint len + utf8) | opacity f32 | visible u8 | strokeCount varint | strokes…
    per stroke: rgba 4×u8 | flags u8 (erase bit + dynamics) | brushSize f32 | pointCount varint | points…
      per point: Δx zig-zag varint | Δy zig-zag varint | pressure u8 | Δt zig-zag varint
```

Header scalars little-endian; points quantized (1/32 pt, 8-bit pressure, 1 ms) and delta-coded. `decode` dispatches per version — v1 (raw f32), v2 (delta, no flags), v3 (delta + flags), v4 (layers), v5 (incremental frames) — so old blobs keep loading.

`decode` accepts arbitrary bytes and is hardened against hostile input: untrusted floats are sanitized (NaN/Inf → defaults, canvas clamped ≤ 16384), `reserveCapacity` is capped so an inflated count can't pre-allocate gigabytes, varint lengths are bounds-checked before `Int()` conversion, and delta accumulation wraps instead of trapping on overflow.
