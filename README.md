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
| `DrawingBlobCodec` | [DrawingBlobCodec.swift](Sources/BlobCanvas/Serialization/DrawingBlobCodec.swift) | Flat little-endian binary + LZFSE compression |
| `Drawing` | [Drawing.swift](Sources/BlobCanvas/Persistence/Drawing.swift) | SwiftData `@Model` holding the blob + metadata |
| `CanvasEngineView` | [CanvasEngineView.swift](Sources/BlobCanvas/Views/CanvasEngineView.swift) | Bitmap-backed renderer, UIKit/AppKit input |
| `BlobCanvasView` | [BlobCanvasView.swift](Sources/BlobCanvas/Views/BlobCanvasView.swift) | SwiftUI wrapper + `BlobCanvasController` |

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

## Binary format

```
"BLBC" | version u16 | algorithm u8 (0 raw, 1 LZFSE) | payload…
payload: canvasW f32 | canvasH f32 | strokeCount u32
  per stroke: rgba 4×u8 | brushSize f32 | pointCount u32 | points pointCount×16B
  per point:  x f32 | y f32 | pressure f32 | timestamp f32
```

All little-endian. Versioned header allows future migration.

## Building & testing

Requires the Xcode toolchain for SwiftData macros:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```
