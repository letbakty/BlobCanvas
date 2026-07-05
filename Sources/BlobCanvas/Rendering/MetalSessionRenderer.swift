#if canImport(Metal)
import Metal
import CoreGraphics
import simd

/// GPU rasterizer: tessellates stroke ribbons into triangle meshes and renders
/// them to an offscreen `MTLTexture`, read back as a `CGImage`. This is the
/// foundation for a live `CAMetalLayer` path; used today for offscreen/export.
///
/// Supported: per-stroke color, `.normal` and `.erase` blend, width dynamics,
/// visible layers. **Not yet matched to the CG path:** Catmull-Rom smoothing,
/// per-stroke single-coverage translucency (translucent self-overlaps double-
/// blend), and group opacity — so translucent brushes and layer opacity differ
/// slightly from `CoreGraphicsRenderer`. Opaque strokes match closely.
/// Thread-safe: all stored properties are immutable, internally-synchronized
/// Metal objects; `makeImage` allocates only transient per-call resources.
public final class MetalSessionRenderer: SessionImageRenderer, @unchecked Sendable {

    private struct Vertex {
        var position: SIMD2<Float>
        var color: SIMD4<Float>
    }

    private struct Uniforms {
        var canvasSize: SIMD2<Float>
    }

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let normalPipeline: MTLRenderPipelineState
    private let erasePipeline: MTLRenderPipelineState
    /// Composites a rendered layer texture over the accumulator, scaled by the
    /// layer's opacity (fullscreen quad, premultiplied over).
    private let compositePipeline: MTLRenderPipelineState

    /// Shared instance — reuse it, since `init` compiles the shader library
    /// (tens of ms). `nil` when no Metal device is available.
    public static let shared: MetalSessionRenderer? = MetalSessionRenderer()

    /// Fails if no Metal device is available (e.g. some CI runners).
    public init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.queue = queue

        do {
            let library = try device.makeLibrary(source: Self.shaderSource, options: nil)
            guard let vfn = library.makeFunction(name: "blob_vertex"),
                  let ffn = library.makeFunction(name: "blob_fragment") else { return nil }

            let vd = MTLVertexDescriptor()
            vd.attributes[0].format = .float2
            vd.attributes[0].offset = MemoryLayout<Vertex>.offset(of: \.position)!
            vd.attributes[0].bufferIndex = 0
            vd.attributes[1].format = .float4
            vd.attributes[1].offset = MemoryLayout<Vertex>.offset(of: \.color)!
            vd.attributes[1].bufferIndex = 0
            vd.layouts[0].stride = MemoryLayout<Vertex>.stride

            func makePipeline(erase: Bool) throws -> MTLRenderPipelineState {
                let desc = MTLRenderPipelineDescriptor()
                desc.vertexFunction = vfn
                desc.fragmentFunction = ffn
                desc.vertexDescriptor = vd
                let att = desc.colorAttachments[0]!
                att.pixelFormat = .rgba8Unorm
                att.isBlendingEnabled = true
                if erase {
                    // dst *= (1 - srcAlpha) — destination-out.
                    att.sourceRGBBlendFactor = .zero
                    att.destinationRGBBlendFactor = .oneMinusSourceAlpha
                    att.sourceAlphaBlendFactor = .zero
                    att.destinationAlphaBlendFactor = .oneMinusSourceAlpha
                } else {
                    // Premultiplied source-over.
                    att.sourceRGBBlendFactor = .sourceAlpha
                    att.destinationRGBBlendFactor = .oneMinusSourceAlpha
                    att.sourceAlphaBlendFactor = .one
                    att.destinationAlphaBlendFactor = .oneMinusSourceAlpha
                }
                return try device.makeRenderPipelineState(descriptor: desc)
            }
            self.normalPipeline = try makePipeline(erase: false)
            self.erasePipeline = try makePipeline(erase: true)

            guard let cvfn = library.makeFunction(name: "composite_vertex"),
                  let cffn = library.makeFunction(name: "composite_fragment") else { return nil }
            let cdesc = MTLRenderPipelineDescriptor()
            cdesc.vertexFunction = cvfn
            cdesc.fragmentFunction = cffn
            let catt = cdesc.colorAttachments[0]!
            catt.pixelFormat = .rgba8Unorm
            catt.isBlendingEnabled = true
            catt.sourceRGBBlendFactor = .one            // source is premultiplied
            catt.destinationRGBBlendFactor = .oneMinusSourceAlpha
            catt.sourceAlphaBlendFactor = .one
            catt.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            self.compositePipeline = try device.makeRenderPipelineState(descriptor: cdesc)
        } catch {
            return nil
        }
    }

    public func makeImage(_ session: DrawingSession, scale: CGFloat, background: StrokeColor?) -> CGImage? {
        let width = StrokeRasterizer.pixelDimension(CGFloat(session.canvasSize.x), scale: scale)
        let height = StrokeRasterizer.pixelDimension(CGFloat(session.canvasSize.y), scale: scale)

        // Render targets live in .private memory so this works on Intel Macs
        // with a discrete GPU (where .shared render targets are disallowed).
        func makeTarget(read: Bool) -> MTLTexture? {
            let d = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
            d.usage = read ? [.renderTarget, .shaderRead] : [.renderTarget]
            d.storageMode = .private
            return device.makeTexture(descriptor: d)
        }
        // `accumulator` holds the composited result; each visible layer is drawn
        // into `layerTex` then composited over the accumulator scaled by the
        // layer's opacity — giving group opacity and layer-local erase.
        guard let accumulator = makeTarget(read: false), let layerTex = makeTarget(read: true) else { return nil }

        let bytesPerRow = width * 4
        guard let readback = device.makeBuffer(length: bytesPerRow * height, options: .storageModeShared),
              let commandBuffer = queue.makeCommandBuffer() else { return nil }

        var uniforms = Uniforms(canvasSize: SIMD2(Float(session.canvasSize.x), Float(session.canvasSize.y)))

        // Clear the accumulator to the background.
        clearPass(accumulator, background: background, on: commandBuffer)

        for layer in session.layers where layer.isVisible {
            // Tessellate this layer's strokes.
            var vertices: [Vertex] = []
            var ranges: [(start: Int, count: Int, erase: Bool)] = []
            for stroke in layer.strokes {
                let start = vertices.count
                appendTessellation(of: stroke, into: &vertices)
                let count = vertices.count - start
                if count > 0 { ranges.append((start, count, stroke.blendMode == .erase)) }
            }
            guard !vertices.isEmpty,
                  let buffer = device.makeBuffer(bytes: vertices,
                                                 length: vertices.count * MemoryLayout<Vertex>.stride,
                                                 options: .storageModeShared) else { continue }

            // Render the layer into a cleared texture.
            let lp = MTLRenderPassDescriptor()
            lp.colorAttachments[0].texture = layerTex
            lp.colorAttachments[0].loadAction = .clear
            lp.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
            lp.colorAttachments[0].storeAction = .store
            guard let le = commandBuffer.makeRenderCommandEncoder(descriptor: lp) else { return nil }
            le.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
            le.setVertexBuffer(buffer, offset: 0, index: 0)
            for range in ranges {
                le.setRenderPipelineState(range.erase ? erasePipeline : normalPipeline)
                le.drawPrimitives(type: .triangle, vertexStart: range.start, vertexCount: range.count)
            }
            le.endEncoding()

            // Composite the layer over the accumulator with its opacity.
            let cp = MTLRenderPassDescriptor()
            cp.colorAttachments[0].texture = accumulator
            cp.colorAttachments[0].loadAction = .load
            cp.colorAttachments[0].storeAction = .store
            guard let ce = commandBuffer.makeRenderCommandEncoder(descriptor: cp) else { return nil }
            ce.setRenderPipelineState(compositePipeline)
            ce.setFragmentTexture(layerTex, index: 0)
            var opacity = max(min(layer.opacity, 1), 0)
            ce.setFragmentBytes(&opacity, length: MemoryLayout<Float>.stride, index: 0)
            ce.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
            ce.endEncoding()
        }

        // Blit the accumulator into the shared read-back buffer.
        guard let blit = commandBuffer.makeBlitCommandEncoder() else { return nil }
        blit.copy(from: accumulator, sourceSlice: 0, sourceLevel: 0,
                  sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: width, height: height, depth: 1),
                  to: readback, destinationOffset: 0,
                  destinationBytesPerRow: bytesPerRow, destinationBytesPerImage: bytesPerRow * height)
        blit.endEncoding()

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        return makeCGImage(from: readback, width: width, height: height, bytesPerRow: bytesPerRow)
    }

    /// A render pass that just clears `texture` to `background` (or transparent).
    private func clearPass(_ texture: MTLTexture, background: StrokeColor?, on commandBuffer: MTLCommandBuffer) {
        let p = MTLRenderPassDescriptor()
        p.colorAttachments[0].texture = texture
        p.colorAttachments[0].loadAction = .clear
        p.colorAttachments[0].storeAction = .store
        if let bg = background {
            p.colorAttachments[0].clearColor = MTLClearColor(
                red: Double(bg.r) / 255, green: Double(bg.g) / 255,
                blue: Double(bg.b) / 255, alpha: Double(bg.a) / 255)
        } else {
            p.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        }
        commandBuffer.makeRenderCommandEncoder(descriptor: p)?.endEncoding()
    }

    // MARK: - Tessellation

    private func appendTessellation(of stroke: Stroke, into verts: inout [Vertex]) {
        // Smoothed samples match the Core Graphics ribbon (Catmull-Rom).
        let (centers, radii) = StrokeRasterizer.ribbonSamples(for: stroke, smoothing: true)
        guard !centers.isEmpty else { return }
        let c = stroke.color
        // Erasers write alpha=1 into the destination-out blend.
        let color = stroke.blendMode == .erase
            ? SIMD4<Float>(0, 0, 0, 1)
            : SIMD4<Float>(Float(c.r) / 255, Float(c.g) / 255, Float(c.b) / 255, Float(c.a) / 255)

        // Body = quads; round caps only at the ends and sharp turns (matching
        // the CG outline). Avoids a full disc fan at every sample — far fewer
        // triangles.
        let n = centers.count
        appendDisc(&verts, center: centers[0], radius: radii[0], color: color)
        if n > 1 { appendDisc(&verts, center: centers[n - 1], radius: radii[n - 1], color: color) }
        for i in 1..<n {
            appendQuad(&verts, from: centers[i - 1], to: centers[i], ra: radii[i - 1], rb: radii[i], color: color)
            if i < n - 1, StrokeRasterizer.isSharpTurn(centers, i) {
                appendDisc(&verts, center: centers[i], radius: radii[i], color: color)
            }
        }
    }

    private func appendDisc(_ verts: inout [Vertex], center: CGPoint, radius: CGFloat, color: SIMD4<Float>) {
        // Guard against non-finite geometry (e.g. a caller-built NaN brush size)
        // so the Int() below can't trap.
        guard radius.isFinite, center.x.isFinite, center.y.isFinite else { return }
        // Segment count scales with radius so large brushes stay round.
        let segments = min(max(Int((radius * 1.5).rounded()), 8), 64)
        let cx = Float(center.x), cy = Float(center.y), rr = Float(radius)
        for s in 0..<segments {
            let a0 = Float(s) / Float(segments) * 2 * .pi
            let a1 = Float(s + 1) / Float(segments) * 2 * .pi
            verts.append(Vertex(position: SIMD2(cx, cy), color: color))
            verts.append(Vertex(position: SIMD2(cx + cos(a0) * rr, cy + sin(a0) * rr), color: color))
            verts.append(Vertex(position: SIMD2(cx + cos(a1) * rr, cy + sin(a1) * rr), color: color))
        }
    }

    private func appendQuad(_ verts: inout [Vertex], from a: CGPoint, to b: CGPoint,
                            ra: CGFloat, rb: CGFloat, color: SIMD4<Float>) {
        let dx = b.x - a.x, dy = b.y - a.y
        let len = (dx * dx + dy * dy).squareRoot()
        guard len > 1e-4 else { return }
        let nx = Float(-dy / len), ny = Float(dx / len)
        let ax = Float(a.x), ay = Float(a.y), bx = Float(b.x), by = Float(b.y)
        let raf = Float(ra), rbf = Float(rb)
        let a0 = SIMD2(ax + nx * raf, ay + ny * raf)
        let a1 = SIMD2(ax - nx * raf, ay - ny * raf)
        let b0 = SIMD2(bx + nx * rbf, by + ny * rbf)
        let b1 = SIMD2(bx - nx * rbf, by - ny * rbf)
        for pos in [a0, b0, b1, a0, b1, a1] {
            verts.append(Vertex(position: pos, color: color))
        }
    }

    // MARK: - Read-back

    private func makeCGImage(from buffer: MTLBuffer, width: Int, height: Int, bytesPerRow: Int) -> CGImage? {
        let data = Data(bytes: buffer.contents(), count: bytesPerRow * height)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        // rgba8Unorm with premultiplied source-over → premultipliedLast.
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: bytesPerRow, space: StrokeRasterizer.colorSpace,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    // MARK: - Shaders

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct VertexIn {
        float2 position [[attribute(0)]];
        float4 color    [[attribute(1)]];
    };
    struct VertexOut {
        float4 position [[position]];
        float4 color;
    };
    struct Uniforms {
        float2 canvasSize;
    };

    vertex VertexOut blob_vertex(VertexIn in [[stage_in]],
                                 constant Uniforms& u [[buffer(1)]]) {
        float2 ndc = float2(in.position.x / u.canvasSize.x * 2.0 - 1.0,
                            1.0 - in.position.y / u.canvasSize.y * 2.0);
        VertexOut out;
        out.position = float4(ndc, 0.0, 1.0);
        // Straight alpha; the .sourceAlpha blend produces a premultiplied
        // destination (cleared to 0), read back as premultipliedLast.
        out.color = in.color;
        return out;
    }

    fragment float4 blob_fragment(VertexOut in [[stage_in]]) {
        return in.color;
    }

    // Fullscreen-triangle composite: sample the layer texture at this pixel and
    // scale by the layer opacity (premultiplied → multiply all channels).
    struct QuadOut { float4 position [[position]]; };

    vertex QuadOut composite_vertex(uint vid [[vertex_id]]) {
        float2 corners[6] = { float2(-1,-1), float2(1,-1), float2(1,1),
                              float2(-1,-1), float2(1,1), float2(-1,1) };
        QuadOut out;
        out.position = float4(corners[vid], 0.0, 1.0);
        return out;
    }

    fragment float4 composite_fragment(QuadOut in [[stage_in]],
                                       texture2d<float, access::read> layerTex [[texture(0)]],
                                       constant float& opacity [[buffer(0)]]) {
        uint2 coord = uint2(in.position.xy);
        return layerTex.read(coord) * opacity;
    }
    """
}
#endif
