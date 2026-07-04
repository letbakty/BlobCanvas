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

    public init() {}

    public func undo() { engineView?.undo() }
    public func redo() { engineView?.redo() }
    public func clear() { engineView?.clear() }

    // Layer controls
    public func addLayer(name: String? = nil) { engineView?.addLayer(name: name) }
    public func setActiveLayer(_ index: Int) { engineView?.setActiveLayer(index) }
    public func removeActiveLayer() { engineView?.removeActiveLayer() }
    public func moveLayer(from source: Int, to destination: Int) { engineView?.moveLayer(from: source, to: destination) }
    public func setLayerOpacity(_ opacity: Float, at index: Int) { engineView?.setLayerOpacity(opacity, at: index) }
    public func setLayerVisible(_ visible: Bool, at index: Int) { engineView?.setLayerVisible(visible, at: index) }

    /// Current in-memory session, e.g. for `drawing.save(controller.snapshot())`.
    public func snapshot() -> DrawingSession {
        engineView?.session ?? DrawingSession()
    }

    func sessionDidChange(_ session: DrawingSession) {
        canUndo = session.canUndo
        canRedo = session.canRedo
        layers = session.layers
        activeLayerIndex = session.activeLayerIndex
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
    var initialSession: DrawingSession?

    public init(
        controller: BlobCanvasController,
        brushColor: StrokeColor = .black,
        brushSize: Float = 8,
        session: DrawingSession? = nil
    ) {
        self.controller = controller
        self.brushColor = brushColor
        self.brushSize = brushSize
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
        return view
    }

    @MainActor
    func update(_ view: CanvasEngineView) {
        view.brushColor = brushColor
        view.brushSize = brushSize
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
