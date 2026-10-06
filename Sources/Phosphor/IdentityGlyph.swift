import simd

/// A person's shape: two nested wireframe solids and a hue, all derived from their
/// fingerprint, so the same person looks the same in every room (and in the browser) and
/// two people who share a name don't.
struct IdentityGlyph {
    let solid: Wireframe
    let core: Wireframe
    let hue: Float
    /// A stable 0…1 value for placing them (e.g. in a room's gallery).
    let offset: Float

    init(fingerprint: String) {
        var rng = SplitMix64(string: fingerprint)
        solid = Wireframe.random(using: &rng, jitter: 0.18)
        core = Wireframe.random(using: &rng, jitter: 0.1)
        hue = Float.random(in: 0..<1, using: &rng)
        offset = Float.random(in: 0..<1, using: &rng)
    }

    func color(theme: Theme) -> SIMD3<Float> {
        theme.monochrome ? theme.primary : hsv(hue, 0.65, 1)
    }

    /// Draws the spinning glyph. `draw` traces the edges on (0…1); `scatter` pushes them
    /// apart, for being kicked or banned.
    func draw(into g: inout FrameGeometry, at position: SIMD3<Float>, size: Float, color: SIMD3<Float>,
              intensity: Float, width: Float, now: Float, draw: Float = 1, scatter: Float = 0) {
        let spin = simd_quatf(angle: now * 0.7 + hue * 6, axis: simd_normalize(SIMD3(0.3, 1, 0.2)))
        let counter = simd_quatf(angle: -now * 1.3, axis: simd_normalize(SIMD3(1, 0.2, 0.4)))
        for (shape, scale, rotation, lineWidth, gain) in [(solid, size, spin, width, Float(1)),
                                                          (core, size * 0.4, counter, width * 0.67, Float(0.75))] {
            for (a, b) in shape.edges {
                var pa = shape.vertices[a].rotated(by: rotation) * scale
                var pb = shape.vertices[b].rotated(by: rotation) * scale
                if scatter > 0 {
                    let push = simd_normalize(pa + pb + SIMD3(0.001, 0, 0)) * scatter
                    pa += push
                    pb += push
                }
                g.polyline([position + pa, position + pb], color, intensity: intensity * gain, width: lineWidth, fraction: draw)
            }
        }
    }
}
