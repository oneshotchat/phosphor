import OSCCore
import simd

// GPU instance layouts; must match Shaders.swift.
struct LineInstance {
    var a: SIMD4<Float>      // xyz, w = width in pixels
    var b: SIMD4<Float>
    var color: SIMD4<Float>  // rgb, a = intensity
}

struct GlyphInstance {
    var origin: SIMD4<Float>
    var right: SIMD4<Float>
    var up: SIMD4<Float>
    var uvRect: SIMD4<Float>
    var color: SIMD4<Float>
}

struct Theme {
    var name: String
    var primary: SIMD3<Float>
    var accent: SIMD3<Float>
    var grid: SIMD3<Float>
    /// Color-vector themes give each identity its own hue; monochrome ones don't.
    var monochrome: Bool

    static let all: [Theme] = [
        Theme(name: "vector", primary: [0.25, 0.9, 1.0], accent: [1.0, 0.45, 0.12], grid: [0.12, 0.45, 0.7], monochrome: false),
        Theme(name: "amber", primary: [1.0, 0.62, 0.16], accent: [1.0, 0.8, 0.45], grid: [0.6, 0.32, 0.06], monochrome: true),
        Theme(name: "green", primary: [0.3, 1.0, 0.38], accent: [0.7, 1.0, 0.7], grid: [0.1, 0.5, 0.15], monochrome: true),
        Theme(name: "white", primary: [0.85, 0.9, 1.0], accent: [1.0, 1.0, 1.0], grid: [0.35, 0.4, 0.5], monochrome: true),
    ]
}

struct Camera {
    var yaw: Float = 0.5
    var pitch: Float = 0.22
    var distance: Float = 23
    var target = SIMD3<Float>(0, 6, 0)

    mutating func orbit(dx: Float, dy: Float) {
        yaw -= dx * 0.005
        pitch = simd_clamp(pitch + dy * 0.005, -0.15, 1.35)
    }

    mutating func zoom(by amount: Float) {
        distance = simd_clamp(distance * (1 - amount), 4, 60)
    }

    var eye: SIMD3<Float> {
        target + SIMD3(sin(yaw) * cos(pitch), sin(pitch), cos(yaw) * cos(pitch)) * distance
    }
}

/// Accumulates lines and glyphs for one frame.
struct FrameGeometry {
    var lines: [LineInstance] = []
    var glyphs: [GlyphInstance] = []
    var pixelScale: Float = 1

    mutating func line(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ color: SIMD3<Float>, intensity: Float = 1, width: Float = 1.5) {
        guard intensity > 0.001 else { return }
        lines.append(LineInstance(a: SIMD4(a, width * pixelScale), b: SIMD4(b, 0), color: SIMD4(color, intensity)))
    }

    /// Draws the first `fraction` of the polyline's length: the beam drawing it on.
    mutating func polyline(_ points: [SIMD3<Float>], _ color: SIMD3<Float>, intensity: Float = 1,
                           width: Float = 1.5, fraction: Float = 1) {
        guard points.count > 1 else { return }
        var segments: [(SIMD3<Float>, SIMD3<Float>, Float)] = []
        var total: Float = 0
        for i in 1..<points.count {
            let l = simd_distance(points[i - 1], points[i])
            segments.append((points[i - 1], points[i], l))
            total += l
        }
        var remaining = total * simd_clamp(fraction, 0, 1)
        for (a, b, l) in segments {
            if remaining <= 0 { break }
            let end = remaining >= l ? b : simd_mix(a, b, SIMD3(repeating: remaining / l))
            line(a, end, color, intensity: intensity, width: width)
            remaining -= l
        }
    }

    /// Lays out `string` on a baseline starting at `origin`. `reveal` is how many glyphs
    /// the beam has written so far; the glyph under the beam burns brightest.
    mutating func text(_ string: String, atlas: GlyphAtlas, origin: SIMD3<Float>, right: SIMD3<Float>, up: SIMD3<Float>,
                       height: Float, color: SIMD3<Float>, intensity: Float = 1, reveal: Float = .infinity) {
        guard intensity > 0.001 else { return }
        let line = atlas.layout(string)
        let scale = height / Float(atlas.bakeSize)
        for (i, g) in line.glyphs.enumerated() {
            let ahead = reveal - Float(i)
            if ahead <= 0 { break }
            let burn: Float = ahead < 1 ? 2.8 : 1 + 1.8 * max(0, 1 - (ahead - 1) / 6)
            let e = g.entry
            let o = origin + right * ((g.x + e.offset.x) * scale) + up * (e.offset.y * scale)
            glyphs.append(GlyphInstance(
                origin: SIMD4(o, 0),
                right: SIMD4(right * (e.size.x * scale), 0),
                up: SIMD4(up * (e.size.y * scale), 0),
                uvRect: e.uvRect,
                color: SIMD4(color, intensity * burn)
            ))
        }
    }

    static func textWidth(_ string: String, atlas: GlyphAtlas, height: Float) -> Float {
        atlas.layout(string).width * height / Float(atlas.bakeSize)
    }
}

/// A wireframe solid: platonic base shape with per-vertex radial jitter, unit-ish radius.
struct Wireframe {
    var vertices: [SIMD3<Float>]
    var edges: [(Int, Int)]

    static func random<R: RandomNumberGenerator>(using rng: inout R, jitter: Float) -> Wireframe {
        let phi: Float = (1 + Float(5).squareRoot()) / 2
        let bases: [[SIMD3<Float>]] = [
            [[1, 1, 1], [1, -1, -1], [-1, 1, -1], [-1, -1, 1]],                                   // tetrahedron
            [[1, 0, 0], [-1, 0, 0], [0, 1, 0], [0, -1, 0], [0, 0, 1], [0, 0, -1]],                 // octahedron
            signs3.map { $0 },                                                                    // cube
            signs2.flatMap { s in [[0, s.x, s.y * phi], [s.x, s.y * phi, 0], [s.y * phi, 0, s.x]] }, // icosahedron
            signs3 + signs2.flatMap { s in                                                        // dodecahedron
                [[0, s.x / phi, s.y * phi], [s.x / phi, s.y * phi, 0], [s.y * phi, 0, s.x / phi]]
            },
        ]
        let base = bases[Int.random(in: 0..<bases.count, using: &rng)].map { simd_normalize($0) }

        // Edges join nearest neighbours, which holds for every platonic solid.
        var minDistance = Float.infinity
        for i in base.indices { for j in base.indices where j > i { minDistance = min(minDistance, simd_distance(base[i], base[j])) } }
        var edges: [(Int, Int)] = []
        for i in base.indices {
            for j in base.indices where j > i && simd_distance(base[i], base[j]) < minDistance * 1.01 {
                edges.append((i, j))
            }
        }
        let vertices = base.map { $0 * (1 + Float.random(in: -jitter...jitter, using: &rng)) }
        return Wireframe(vertices: vertices, edges: edges)
    }

    private static let signs2: [SIMD2<Float>] = [[1, 1], [1, -1], [-1, 1], [-1, -1]]
    private static let signs3: [SIMD3<Float>] = [-1, 1].flatMap { x in [-1, 1].flatMap { y in [-1, 1].map { z in SIMD3<Float>(x, y, z) } } }
}

func smoothstep(_ e0: Float, _ e1: Float, _ x: Float) -> Float {
    let t = simd_clamp((x - e0) / (e1 - e0), 0, 1)
    return t * t * (3 - 2 * t)
}
