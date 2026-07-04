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
public final class MetalSessionRenderer: SessionImageRenderer {

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
        } catch {
            return nil
        }
    }

    public func makeImage(_ session: DrawingSession, scale: CGFloat, background: StrokeColor?) -> CGImage? {
        let width = max(1, Int((CGFloat(session.canvasSize.x) * scale).rounded()))
        let height = max(1, Int((CGFloat(session.canvasSize.y) * scale).rounded()))

        let texDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
        texDesc.usage = [.renderTarget, .shaderRead]
        texDesc.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: texDesc) else { return nil }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        if let bg = background {
            pass.colorAttachments[0].clearColor = MTLClearColor(
                red: Double(bg.r) / 255, green: Double(bg.g) / 255,
                blue: Double(bg.b) / 255, alpha: Double(bg.a) / 255)
        } else {
            pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        }

        guard let commandBuffer = queue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return nil }

        var uniforms = Uniforms(canvasSize: SIMD2(Float(session.canvasSize.x), Float(session.canvasSize.y)))
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)

        for layer in session.layers where layer.isVisible {
            for stroke in layer.strokes {
                let verts = tessellate(stroke)
                guard !verts.isEmpty else { continue }
                encoder.setRenderPipelineState(stroke.blendMode == .erase ? erasePipeline : normalPipeline)
                verts.withUnsafeBytes { raw in
                    encoder.setVertexBytes(raw.baseAddress!, length: raw.count, index: 0)
                }
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: verts.count)
            }
        }
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        return makeCGImage(from: texture)
    }

    // MARK: - Tessellation

    private func tessellate(_ stroke: Stroke) -> [Vertex] {
        let pts = stroke.points
        guard !pts.isEmpty else { return [] }
        let c = stroke.color
        // Erasers write alpha=1 into the destination-out blend.
        let color = stroke.blendMode == .erase
            ? SIMD4<Float>(0, 0, 0, 1)
            : SIMD4<Float>(Float(c.r) / 255, Float(c.g) / 255, Float(c.b) / 255, Float(c.a) / 255)

        var verts: [Vertex] = []
        verts.reserveCapacity(pts.count * 24)

        var prev: StrokePoint?
        var prevR: CGFloat = 0
        for p in pts {
            let r = StrokeRasterizer.halfWidth(p, previous: prev, stroke)
            appendDisc(&verts, center: p.cgPoint, radius: r, color: color)
            if let a = prev {
                appendQuad(&verts, from: a.cgPoint, to: p.cgPoint, ra: prevR, rb: r, color: color)
            }
            prev = p
            prevR = r
        }
        return verts
    }

    private func appendDisc(_ verts: inout [Vertex], center: CGPoint, radius: CGFloat, color: SIMD4<Float>) {
        let segments = 12
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

    private func makeCGImage(from texture: MTLTexture) -> CGImage? {
        let width = texture.width, height = texture.height
        let bytesPerRow = width * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * height)
        bytes.withUnsafeMutableBytes { raw in
            texture.getBytes(raw.baseAddress!, bytesPerRow: bytesPerRow,
                             from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
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
    """
}
#endif
