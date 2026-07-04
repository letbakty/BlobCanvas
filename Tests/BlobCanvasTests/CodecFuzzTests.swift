import XCTest
@testable import BlobCanvas

/// Robustness tests: the decoder must never crash on hostile/garbage input, and
/// the encode→decode round trip must hold for randomized sessions.
final class CodecFuzzTests: XCTestCase {

    func testDecodeNeverCrashesOnRandomBytes() {
        var rng = SeededRNG(seed: 0xB10B_CA11)
        for _ in 0..<2000 {
            let count = Int(rng.next() % 512)
            var bytes = [UInt8](repeating: 0, count: count)
            for i in 0..<count { bytes[i] = UInt8(rng.next() & 0xFF) }
            // Must throw or return — never trap.
            _ = try? DrawingBlobCodec.decode(Data(bytes))
        }
    }

    func testDecodeNeverCrashesOnCorruptedValidBlob() {
        var rng = SeededRNG(seed: 42)
        let base = randomSession(&rng, maxStrokes: 6, maxPoints: 40).serialized()
        for _ in 0..<1000 {
            var bytes = Array(base)
            // Flip a handful of random bytes.
            for _ in 0..<Int(1 + rng.next() % 8) where !bytes.isEmpty {
                let i = Int(rng.next() % UInt64(bytes.count))
                bytes[i] = UInt8(rng.next() & 0xFF)
            }
            _ = try? DrawingBlobCodec.decode(Data(bytes))
        }
    }

    func testRandomizedRoundTripWithinTolerance() throws {
        var rng = SeededRNG(seed: 7)
        for _ in 0..<50 {
            let session = randomSession(&rng, maxStrokes: 8, maxPoints: 120)
            let decoded = try DrawingSession(serialized: session.serialized())
            XCTAssertEqual(decoded.layers.count, session.layers.count)

            let coordTol: Float = 1 / 32 / 2 + 1e-3
            for (la, lb) in zip(session.layers, decoded.layers) {
                XCTAssertEqual(la.strokes.count, lb.strokes.count)
                for (a, b) in zip(la.strokes, lb.strokes) {
                    XCTAssertEqual(a.color, b.color)
                    XCTAssertEqual(a.blendMode, b.blendMode)
                    XCTAssertEqual(a.dynamics, b.dynamics)
                    for (p, q) in zip(a.points, b.points) {
                        XCTAssertEqual(p.x, q.x, accuracy: coordTol)
                        XCTAssertEqual(p.y, q.y, accuracy: coordTol)
                    }
                }
            }
        }
    }

    func testRandomizedReencodeIsStable() throws {
        var rng = SeededRNG(seed: 99)
        for _ in 0..<50 {
            let blob1 = randomSession(&rng, maxStrokes: 6, maxPoints: 80).serialized()
            let blob2 = try DrawingSession(serialized: blob1).serialized()
            XCTAssertEqual(blob1, blob2)
        }
    }

    // MARK: - Helpers

    private func randomSession(_ rng: inout SeededRNG, maxStrokes: Int, maxPoints: Int) -> DrawingSession {
        var session = DrawingSession(canvasSize: SIMD2(Float(400 + rng.next() % 800), Float(300 + rng.next() % 600)))
        let layerCount = 1 + Int(rng.next() % 3)
        for l in 0..<layerCount {
            if l > 0 { session.addLayer(name: "L\(l)") }
            let strokeCount = Int(rng.next() % UInt64(maxStrokes + 1))
            for _ in 0..<strokeCount {
                let blend: BlendMode = rng.next() % 5 == 0 ? .erase : .normal
                let dyn = WidthDynamics(rawValue: UInt8(rng.next() % 3)) ?? .pressure
                var stroke = Stroke(color: StrokeColor(r: UInt8(rng.next() & 0xFF), g: UInt8(rng.next() & 0xFF),
                                                       b: UInt8(rng.next() & 0xFF), a: UInt8(rng.next() & 0xFF)),
                                    brushSize: Float(1 + rng.next() % 40), blendMode: blend, dynamics: dyn)
                let pointCount = 1 + Int(rng.next() % UInt64(maxPoints))
                var x = Float(rng.next() % 400), y = Float(rng.next() % 400)
                for p in 0..<pointCount {
                    x += Float(Int(rng.next() % 9)) - 4
                    y += Float(Int(rng.next() % 9)) - 4
                    stroke.append(StrokePoint(x: x, y: y,
                                              pressure: Float(rng.next() % 256) / 255,
                                              timestamp: Float(p) / 90))
                }
                session.commit(stroke)
            }
        }
        return session
    }
}

/// Deterministic SplitMix64 — reproducible fuzzing without SystemRandom flakiness.
struct SeededRNG {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
