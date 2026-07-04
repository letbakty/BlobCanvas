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

- **Incremental rendering.** Committed pixels are baked into an offscreen `CGContext` once. Each new input point strokes only its new segment and invalidates just that dirty rect; `draw(_:)` is a single bitmap blit. Per-frame cost is constant regardless of total point count — thousands of points render at 60/120 FPS.
- **No allocations on the hot path.** Points are 16-byte value types appended into pre-reserved contiguous arrays; segments are drawn with raw `CGContext` move/addLine calls (no `CGPath`/`UIBezierPath` objects). Full re-bake happens only on undo/redo/clear/load/resize.
- **Coalesced touches** on iOS deliver the full 120/240 Hz sample stream even between display refreshes.
- **Bulk binary serialization.** `[StrokePoint]` is memcpy'd directly into the payload (no per-point Codable overhead), then LZFSE-compressed. A 10k-point drawing encodes in ~1.5 ms into ~14 KB.

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
                drawing.save(session)             // re-encode blob + bump modifiedAt
                try? context.save()
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
