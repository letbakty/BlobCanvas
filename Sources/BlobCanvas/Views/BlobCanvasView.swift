import SwiftUI

/// Reference-type handle for driving the canvas from SwiftUI toolbars
/// (undo/redo/clear/save) without funneling the heavy stroke arrays through
/// `Binding` value copies every frame.
@Observable
@MainActor
public final class BlobCanvasController {
    weak var engineView: CanvasEngineView?

    /// Mirrored flags for enabling/disabling toolbar buttons.
    public private(set) var canUndo = false
    public private(set) var canRedo = false
    /// Mirrored layer stack for building a layer panel.
    public private(set) var layers: [Layer] = []
    public private(set) var activeLayerIndex = 0

    /// Called whenever history changes — attach your debounced auto-save.
    public var onSessionChanged: ((DrawingSession) -> Void)?

    /// Last session observed while the view was attached (B2). A debounced
    /// autosave can fire *after* the engine view is torn down (screen dismissed);
    /// without this, `snapshot()` would return a fresh empty session and clobber
    /// the real drawing on disk. We fall back to this cache instead.
    private var lastSession: DrawingSession?

    public init() {}

    public func undo() { engineView?.undo() }
    public func redo() { engineView?.redo() }
    public func clear() { engineView?.clear() }
    public func resetZoom() { engineView?.resetZoom() }

    /// Enables O(1) undo for the most recent `depth` steps (see the engine).
    public func setUndoCheckpointDepth(_ depth: Int) { engineView?.undoCheckpointDepth = depth }

    /// Rasterizes the current drawing (all layers) to an image, e.g. for export.
    public func makeImage(scale: CGFloat = 2, background: StrokeColor? = nil) -> CGImage? {
        StrokeRasterizer.makeImage(snapshot(), scale: scale, background: background)
    }

    // Layer controls
    public func addLayer(name: String? = nil) { engineView?.addLayer(name: name) }
    public func setActiveLayer(_ index: Int) { engineView?.setActiveLayer(index) }
    public func removeActiveLayer() { engineView?.removeActiveLayer() }
    public func moveLayer(from source: Int, to destination: Int) { engineView?.moveLayer(from: source, to: destination) }
    public func setLayerOpacity(_ opacity: Float, at index: Int) { engineView?.setLayerOpacity(opacity, at: index) }
    public func setLayerVisible(_ visible: Bool, at index: Int) { engineView?.setLayerVisible(visible, at: index) }

    /// Current in-memory session, e.g. for `drawing.save(controller.snapshot())`.
    /// Falls back to the last observed session if the view is already gone, so a
    /// late autosave never writes an empty drawing over a real one (B2).
    public func snapshot() -> DrawingSession {
        if let live = engineView?.session {
            lastSession = live
            return live
        }
        return lastSession ?? DrawingSession()
    }

    /// Refreshes the mirrored toolbar/layer state from a session. Does **not**
    /// signal a change, so it's safe to call on load.
    func seed(_ session: DrawingSession) {
        lastSession = session
        canUndo = session.canUndo
        canRedo = session.canRedo
        layers = session.layers
        activeLayerIndex = session.activeLayerIndex
    }

    func sessionDidChange(_ session: DrawingSession) {
        lastSession = session
        seed(session)
        onSessionChanged?(session)
    }
}

/// SwiftUI wrapper around ``CanvasEngineView``.
///
/// ```swift
/// @State private var controller = BlobCanvasController()
///
/// BlobCanvasView(controller: controller, brushColor: .black, brushSize: 8)
///     .frame(width: 1024, height: 768)
/// Button("Undo") { controller.undo() }.disabled(!controller.canUndo)
/// ```
public struct BlobCanvasView {
    let controller: BlobCanvasController
    var brushColor: StrokeColor
    var brushSize: Float
    var brushBlendMode: BlendMode
    var brushDynamics: WidthDynamics
    var smoothing: Bool
    var pencilOnly: Bool
    var initialSession: DrawingSession?

    public init(
        controller: BlobCanvasController,
        brushColor: StrokeColor = .black,
        brushSize: Float = 8,
        blendMode: BlendMode = .normal,
        dynamics: WidthDynamics = .pressure,
        smoothing: Bool = true,
        pencilOnly: Bool = false,
        session: DrawingSession? = nil
    ) {
        self.controller = controller
        self.brushColor = brushColor
        self.brushSize = brushSize
        self.brushBlendMode = blendMode
        self.brushDynamics = dynamics
        self.smoothing = smoothing
        self.pencilOnly = pencilOnly
        self.initialSession = session
    }

    @MainActor
    func makeEngineView() -> CanvasEngineView {
        let view = CanvasEngineView()
        if let initialSession {
            view.load(initialSession)
        }
        view.onSessionChanged = { [weak controller] session in
            controller?.sessionDidChange(session)
        }
        controller.engineView = view
        // Seed the mirrored state from the (possibly loaded) session — otherwise
        // a gallery-opened drawing shows an empty layer panel and disabled undo
        // until the first edit. Uses `seed`, not `sessionDidChange`, so opening a
        // drawing doesn't fire the autosave callback and mark it dirty.
        controller.seed(view.session)
        return view
    }

    @MainActor
    func update(_ view: CanvasEngineView) {
        view.brushColor = brushColor
        view.brushSize = brushSize
        view.brushBlendMode = brushBlendMode
        view.brushDynamics = brushDynamics
        view.smoothing = smoothing
        view.pencilOnly = pencilOnly
    }
}

#if canImport(UIKit)
extension BlobCanvasView: UIViewRepresentable {
    public func makeUIView(context: Context) -> CanvasEngineView { makeEngineView() }
    public func updateUIView(_ uiView: CanvasEngineView, context: Context) { update(uiView) }
}
#elseif canImport(AppKit)
extension BlobCanvasView: NSViewRepresentable {
    public func makeNSView(context: Context) -> CanvasEngineView { makeEngineView() }
    public func updateNSView(_ nsView: CanvasEngineView, context: Context) { update(nsView) }
}
#endif
