import simd

/// A room you've left, vaporising: its last frame (every line and glyph) breaks into
/// pieces that ignite, flare toward the accent colour, and drift up into the sky, the
/// dissolve sweeping from the base to the top.
struct Vapor {
    static let duration: Float = 1.7

    private struct Piece<T> {
        var item: T
        var velocity: SIMD3<Float>
        var delay: Float
    }

    private var lines: [Piece<LineInstance>] = []
    private var glyphs: [Piece<GlyphInstance>] = []
    private let startedAt: Float

    var isFinished: Bool { AppClock.now - startedAt > Self.duration + 0.6 }

    init(lines source: ArraySlice<LineInstance>, glyphs sourceGlyphs: ArraySlice<GlyphInstance>, seed: String) {
        startedAt = AppClock.now
        var rng = SplitMix64(string: seed)
        var top: Float = 1
        for l in source { top = max(top, l.a.y, l.b.y) }
        for g in sourceGlyphs { top = max(top, g.origin.y) }
        let top_ = top

        func velocity() -> SIMD3<Float> {
            SIMD3(Float.random(in: -1.2...1.2, using: &rng), Float.random(in: 1.5...4.5, using: &rng),
                  Float.random(in: -1.2...1.2, using: &rng))
        }
        // Lower pieces let go first; a little randomness keeps the front ragged.
        func delay(_ y: Float) -> Float {
            min(1, max(0, y / top_)) * 0.45 + Float.random(in: 0...0.12, using: &rng)
        }

        // Each line breaks into a few dashes with gaps between them. Very large rooms are
        // thinned so the effect stays cheap.
        let stride = max(1, source.count / 6000)
        for (k, line) in source.enumerated() where k % stride == 0 {
            let a = SIMD3(line.a.x, line.a.y, line.a.z), b = SIMD3(line.b.x, line.b.y, line.b.z)
            let pieces = min(4, max(1, Int(simd_distance(a, b) / 0.7)))
            for i in 0..<pieces {
                let t0 = Float(i) / Float(pieces), t1 = (Float(i) + 0.7) / Float(pieces)
                let p0 = simd_mix(a, b, SIMD3(repeating: t0)), p1 = simd_mix(a, b, SIMD3(repeating: t1))
                var dash = line
                dash.a = SIMD4(p0, line.a.w)
                dash.b = SIMD4(p1, line.b.w)
                lines.append(Piece(item: dash, velocity: velocity(), delay: delay((p0.y + p1.y) / 2)))
            }
        }
        for g in sourceGlyphs {
            glyphs.append(Piece(item: g, velocity: velocity(), delay: delay(g.origin.y)))
        }
    }

    func draw(into g: inout FrameGeometry, theme: Theme) {
        let now = AppClock.now - startedAt
        // Rise fast, then slow, like smoke.
        func lift(_ t: Float) -> Float { (1 - exp(-t * 1.6)) / 1.6 }
        func glow(_ t: Float) -> Float { 1 + 2.2 * exp(-t * 7) }                 // the flare as it ignites
        func life(_ t: Float) -> Float { let p = min(1, t / Self.duration); return (1 - p) * (1 - p) }

        for piece in lines {
            var line = piece.item
            let t = now - piece.delay
            guard t > 0 else {
                g.lines.append(line)
                continue
            }
            let alive = life(t)
            guard alive > 0.005 else { continue }
            let offset = piece.velocity * lift(t)
            let a = SIMD3(line.a.x, line.a.y, line.a.z) + offset
            let b = SIMD3(line.b.x, line.b.y, line.b.z) + offset
            let mid = (a + b) / 2, shrink = SIMD3<Float>(repeating: max(0.08, alive))   // dashes shrink to sparks
            line.a = SIMD4(mid + (a - mid) * shrink, line.a.w)
            line.b = SIMD4(mid + (b - mid) * shrink, line.b.w)
            let heat = min(1, t * 3)
            let rgb = simd_mix(SIMD3(line.color.x, line.color.y, line.color.z), theme.accent, SIMD3(repeating: heat * 0.8))
            line.color = SIMD4(rgb, line.color.w * glow(t) * alive)
            g.lines.append(line)
        }
        for piece in glyphs {
            var glyph = piece.item
            let t = now - piece.delay
            guard t > 0 else {
                g.glyphs.append(glyph)
                continue
            }
            let alive = life(t)
            guard alive > 0.005 else { continue }
            let center = SIMD3(glyph.origin.x, glyph.origin.y, glyph.origin.z)
                + (SIMD3(glyph.right.x, glyph.right.y, glyph.right.z) + SIMD3(glyph.up.x, glyph.up.y, glyph.up.z)) / 2
            let scale = max(0.1, alive)
            let right = SIMD3(glyph.right.x, glyph.right.y, glyph.right.z) * scale
            let up = SIMD3(glyph.up.x, glyph.up.y, glyph.up.z) * scale
            let moved = center + piece.velocity * lift(t)
            glyph.origin = SIMD4(moved - (right + up) / 2, 0)
            glyph.right = SIMD4(right, 0)
            glyph.up = SIMD4(up, 0)
            let rgb = simd_mix(SIMD3(glyph.color.x, glyph.color.y, glyph.color.z), theme.accent, SIMD3(repeating: min(1, t * 3) * 0.8))
            glyph.color = SIMD4(rgb, glyph.color.w * glow(t) * alive)
            g.glyphs.append(glyph)
        }
    }
}
