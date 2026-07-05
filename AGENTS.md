# AGENTS.md — BlobCanvas

Map of this repo for coding agents. Read this before editing. Human-facing overview is in [README.md](README.md); deep architecture in [Documentation/ARCHITECTURE.md](Documentation/ARCHITECTURE.md).

## What this is

A high-performance, stroke-based vector drawing engine (Swift Package) for **iOS 17+ / macOS 14+**, inspired by *Sloppy Forgeries*. The whole drawing history is persisted as **one compressed binary blob** in a SwiftData `@Model` — no relational stroke/point rows. Rendering is bitmap-backed Core Graphics with a GPU (Metal) offscreen path behind a protocol.

## Build & test (required env)

SwiftData macros + Swift 6 language mode need the Xcode toolchain. **Always prefix with `DEVELOPER_DIR`:**

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
# iOS compile check:
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -scheme BlobCanvas -destination 'generic/platform=iOS Simulator' build
```

- Plain `swift build` (command-line toolchain) **fails** — SwiftData macro plugin is missing.
- `Package.swift` is `swift-tools-version: 6.0`, `swiftLanguageMode(.v6)` — keep it concurrency-clean (value types are `Sendable`; the view/controller are `@MainActor`).
- 71 tests must stay green. Metal tests `XCTSkip` when no GPU is present (CI runners), so a skip is not a failure.

## Module layout

```
Sources/BlobCanvas/
  Models/          value types, no platform deps
    StrokePoint    16-byte POD (x,y,pressure,timestamp)
    Stroke         points + StrokeColor + brushSize + BlendMode + WidthDynamics
    Layer          named [Stroke] + opacity + isVisible
    DrawingSession the whole document: [Layer] + activeLayerIndex + redo stack
  Serialization/
    DrawingBlobCodec         binary <-> DrawingSession. Versions v1–v5, delta+quantized+LZFSE
    IncrementalDrawingEncoder append-only save (v5 sealed frames), one per open drawing
  Rendering/       pure, UIKit-free (except nothing) — safe to unit-test headless
    StrokeRasterizer     THE geometry: ribbon paths, smoothing, velocity width, blend, layers
    SessionImageRenderer protocol + CoreGraphicsRenderer (default)
    MetalSessionRenderer GPU offscreen rasterizer (tessellated ribbons -> MTLTexture)
    CanvasViewport       canvas<->view transform (zoom/pan), pure & tested
    DrawingExporter      PNG / PDF / SVG / thumbnail
    DrawingPlayer        timestamp-driven replay
  Persistence/
    Drawing        @Model: compressedData + thumbnailData + metadata; save()/makeSession()
  Views/
    CanvasEngineView   UIView/NSView: input, 3 CanvasBuffers (committed/live/predicted), present
    BlobCanvasView     SwiftUI UI/NSViewRepresentable + @MainActor BlobCanvasController
Tests/BlobCanvasTests/  codec, fuzz, incremental, rasterizer/Metal golden, layers, viewport, export, player
```

## Where to change what

- **New stroke property** → add to `Stroke`, then bump codec: extend the flags byte in `DrawingBlobCodec.flags/decodeFlags` or add a new version branch. Update `encodeFrame`/`readStrokes`. Add a round-trip test.
- **New blob format** → bump `DrawingBlobCodec.version`, add a `case N:` in `decode`, keep old decoders. Never remove a decoder (migration). Add a `testDecodesLegacy…` test.
- **Rendering/brush behavior** → edit `StrokeRasterizer` only (single source of geometry). `CanvasEngineView` and exporters delegate to it. Mirror in `MetalSessionRenderer` if GPU parity matters.
- **Input/latency/gestures** → `CanvasEngineView` platform extensions (`#if canImport(UIKit)` / `AppKit`).
- **Transform/zoom math** → `CanvasViewport` (pure, add a test there, not in the view).

## Invariants & gotchas

- **Coordinates:** strokes are stored in *canvas points* (device-independent). The view aspect-fits + zoom/pans via `CanvasViewport`. Never store view-space coords.
- **Codec is lossy by design (v2+):** points quantized to 1/32 pt, pressure 8-bit, timestamp 1 ms. Round-trip tests must use **tolerance**, not `==` against a raw session; compare against a decoded one-shot for exact equality.
- **`decode` is hostile-input-hardened — keep it that way.** It takes arbitrary `Data`. Don't remove: `sanitize`/`sanitizedCanvas`/`fixed` on untrusted floats (NaN/Inf → `Int()` trap), `min(count, reserveCap)` on every `reserveCapacity` (amplification OOM), the `len <= Int.max` guard before `readBytes`, or `&+=`/`&-` on the Int64 delta accumulators (overflow trap). Any Float→pixel-int must go through `StrokeRasterizer.pixelDimension`. Add a `CodecSafetyTests` case for new decode paths.
- **`Data` slices keep parent indices** — never subscript a slice with `[0]`; use the codec `Reader`.
- **Live vs committed:** the live preview is approximate (polyline, no smoothing, top-layer assumption); the authoritative render happens on commit / `rebake()` via `StrokeRasterizer`. Don't "fix" a preview mismatch by changing committed logic.
- **Eraser** draws straight into `committed` for live feedback; `endStroke`/`rebake` make it layer-local. It's a real `Stroke` with `blendMode == .erase` (undoable).
- **Metal:** uses a real `MTLBuffer` (never `setVertexBytes` — 4 KB limit fails real strokes). Reuse one `MetalSessionRenderer` instance (it compiles shaders in `init`). It renders per-layer (group opacity + layer-local erase) with Catmull-Rom smoothing; the only remaining gap vs CG is per-stroke single-coverage translucency (self-overlaps of one translucent stroke double-blend).
- **Rendering tests are headless golden-pixel:** render to a `CGImage`, read a pixel, assert channel values. Copy the `pixel(_:_:_:)` helper pattern from `RenderingTests`.
- **No `Co-Authored-By` trailers** in commits; author is the user. Commit/branch only when asked.

## Known limitations (see ARCHITECTURE.md "Improvements")

Remaining, all inherently device-bound: Metal is offscreen-only (no live `CAMetalLayer` view path); no IOSurface presentation or canvas tiling for very large canvases. The Metal renderer's one remaining gap vs CG is per-stroke single-coverage translucency (smoothing, layer opacity, layer-local erase, blend all match now). Display P3 is export-only; the live view renders sRGB.

Already addressed (don't re-report): crisp zoom (re-bake at zoom resolution, pixel-budget capped), O(1) undo via opt-in `undoCheckpointDepth`, Intel-safe Metal blit read-back, layer frames keyed by `Layer.id`, Metal Catmull-Rom smoothing + radius-scaled caps, multi-layer eraser preview safety.
