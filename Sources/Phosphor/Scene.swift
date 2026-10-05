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
    var distance: Float = 17
    var target = SIMD3<Float>(0, 3.6, 0)

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

/// A fake #lobby for the prototype. Everything here is placeholder data.
final class DemoScene {
    struct Person {
        let name: String
        let identity: Identity
        let solid: Wireframe
        let core: Wireframe
        let hue: Float
        var label = ""
    }

    struct Message {
        let author: Int
        let text: String
        var mentionsYou = false
    }

    private(set) var people: [Person]
    let messages: [Message]
    let helixRadius: Float = 5
    let helixStep: Float = 0.62
    let helixRise: Float = 0.95

    private let messageInterval: Float = 1.7
    private let glyphsPerSecond: Float = 32
    private var loopLength: Float { Float(messages.count) * messageInterval + 7 }

    init() {
        let names = ["you", "sam", "sam", "ada", "kit"]
        people = names.map { name in
            let identity = Identity.generate()
            var rng = SplitMix64(string: identity.fingerprint)
            return Person(
                name: name,
                identity: identity,
                solid: Wireframe.random(using: &rng, jitter: 0.18),
                core: Wireframe.random(using: &rng, jitter: 0.1),
                hue: Float.random(in: 0..<1, using: &rng)
            )
        }
        let labels = Tripcode.labels(for: people.map { ($0.name, $0.identity.fingerprint) })
        for i in people.indices { people[i].label = labels[people[i].identity.fingerprint] ?? people[i].name }

        messages = [
            Message(author: 1, text: "anyone else here from #conformance?"),
            Message(author: 3, text: "just passed !test 🎉"),
            Message(author: 4, text: "lobby keeps messages for seven days"),
            Message(author: 0, text: "phosphor client online. vectors all the way down"),
            Message(author: 2, text: "@you which sam do you mean? I'm the other one", mentionsYou: true),
            Message(author: 3, text: "tripcodes: check the #suffix on each sam"),
            Message(author: 4, text: "日本語もok → CoreText font fallback"),
            Message(author: 0, text: "nothing lasts forever ✦"),
        ]
    }

    func color(for person: Person, theme: Theme) -> SIMD3<Float> {
        theme.monochrome ? theme.primary : hsv(person.hue, 0.65, 1)
    }

    // MARK: layout

    func panelFrame(_ i: Int) -> (center: SIMD3<Float>, right: SIMD3<Float>, normal: SIMD3<Float>) {
        let angle = Float(i) * helixStep
        let normal = SIMD3<Float>(sin(angle), 0, cos(angle))
        let right = SIMD3<Float>(cos(angle), 0, -sin(angle))
        let center = normal * helixRadius + SIMD3(0, 0.8 + Float(i) * helixRise, 0)
        return (center, right, normal)
    }

    private static let textHeight: Float = 0.3
    private static let labelHeight: Float = 0.22
    private static let panelPad: Float = 0.22

    func panelWidth(_ i: Int, atlas: GlyphAtlas) -> Float {
        let message = messages[i]
        return max(FrameGeometry.textWidth(message.text, atlas: atlas, height: Self.textHeight),
                   FrameGeometry.textWidth(people[message.author].label, atlas: atlas, height: Self.labelHeight))
            + Self.panelPad * 2
    }

    /// The newest message the beam has started writing, for reading mode.
    func newestVisibleMessage(time: Float) -> Int {
        let t = time.truncatingRemainder(dividingBy: loopLength)
        return max(0, min(messages.count - 1, Int(t / messageInterval)))
    }

    func personPosition(_ p: Int, time: Float) -> SIMD3<Float> {
        let angle = time * 0.12 + Float(p) / Float(people.count) * 2 * .pi
        let height: Float = 1.6 + Float(p % 3) * 1.4
        return SIMD3(sin(angle) * 9, height, cos(angle) * 9)
    }

    // MARK: build

    func build(into g: inout FrameGeometry, atlas: GlyphAtlas, time: Float, theme: Theme,
               eye: SIMD3<Float>, cameraRight: SIMD3<Float>, cameraUp: SIMD3<Float>) {
        let t = time.truncatingRemainder(dividingBy: loopLength)
        let loopFade = 1 - smoothstep(loopLength - 3, loopLength - 0.5, t)

        buildFloor(into: &g, theme: theme)
        buildSpine(into: &g, theme: theme)

        for (i, message) in messages.enumerated() {
            let start = Float(i) * messageInterval
            guard t >= start else { break }
            buildPanel(into: &g, atlas: atlas, index: i, message: message, age: t - start,
                       fade: loopFade, theme: theme, eye: eye)
        }

        for (p, person) in people.enumerated() {
            buildPerson(into: &g, atlas: atlas, person: person, at: personPosition(p, time: time), time: time,
                        theme: theme, cameraRight: cameraRight, cameraUp: cameraUp)
        }

        // Mention: a beam arcs from the author's glyph to yours as the message arrives.
        for (i, message) in messages.enumerated() where message.mentionsYou {
            let age = t - Float(i) * messageInterval
            guard age > 0, age < 1.2 else { continue }
            let from = personPosition(message.author, time: time)
            let to = personPosition(0, time: time)
            let mid = (from + to) * 0.5 + SIMD3(0, 5, 0)
            let arc = (0...32).map { k -> SIMD3<Float> in
                let s = Float(k) / 32
                return (1 - s) * (1 - s) * from + 2 * (1 - s) * s * mid + s * s * to
            }
            let head = smoothstep(0, 0.6, age)
            g.polyline(arc, theme.accent, intensity: 2.2 * (1 - smoothstep(0.7, 1.2, age)), width: 2.5, fraction: head)
        }

        // Room title over the helix.
        let titleHeight: Float = 0.9
        let title = "#lobby"
        let titleWidth = FrameGeometry.textWidth(title, atlas: atlas, height: titleHeight)
        let top = SIMD3<Float>(0, 0.8 + Float(messages.count) * helixRise + 1.6, 0)
        g.text(title, atlas: atlas, origin: top - cameraRight * titleWidth / 2, right: cameraRight, up: cameraUp,
               height: titleHeight, color: theme.primary, intensity: 1.3)
        let topic = "phosphor prototype · fake data"
        let topicWidth = FrameGeometry.textWidth(topic, atlas: atlas, height: 0.32)
        g.text(topic, atlas: atlas, origin: top - cameraRight * topicWidth / 2 - cameraUp * 0.55,
               right: cameraRight, up: cameraUp, height: 0.32, color: theme.primary, intensity: 0.7)
    }

    private func buildFloor(into g: inout FrameGeometry, theme: Theme) {
        let extent: Float = 40
        var x = -extent
        while x <= extent {
            g.line([x, 0, -extent], [x, 0, extent], theme.grid, intensity: 0.55, width: 1)
            g.line([-extent, 0, x], [extent, 0, x], theme.grid, intensity: 0.55, width: 1)
            x += 2
        }
    }

    private func buildSpine(into g: inout FrameGeometry, theme: Theme) {
        let top = 0.8 + Float(messages.count) * helixRise
        g.line([0, 0, 0], [0, top, 0], theme.primary, intensity: 0.5, width: 1)
        let helix = (0...160).map { k -> SIMD3<Float> in
            let s = Float(k) / 160 * Float(messages.count - 1)
            let angle = s * helixStep
            return SIMD3(sin(angle) * helixRadius * 0.55, 0.8 + s * helixRise, cos(angle) * helixRadius * 0.55)
        }
        g.polyline(helix, theme.primary, intensity: 0.35, width: 1)
        let ring = (0...64).map { k -> SIMD3<Float> in
            let a = Float(k) / 64 * 2 * .pi
            return SIMD3(sin(a) * helixRadius, 0.01, cos(a) * helixRadius)
        }
        g.polyline(ring, theme.primary, intensity: 0.6, width: 1.2)
    }

    private func buildPanel(into g: inout FrameGeometry, atlas: GlyphAtlas, index: Int, message: Message,
                            age: Float, fade: Float, theme: Theme, eye: SIMD3<Float>) {
        let (center, right, normal) = panelFrame(index)
        let up = SIMD3<Float>(0, 1, 0)
        // Panels turned away from the camera dim to a faint outline, so text is never mirrored.
        let facing = simd_dot(normal, simd_normalize(eye - center))
        let front = smoothstep(-0.05, 0.35, facing) * fade
        let outline = max(front, 0.12 * fade)

        let author = people[message.author]
        let authorColor = color(for: author, theme: theme)
        let textHeight = Self.textHeight, labelHeight = Self.labelHeight, pad = Self.panelPad
        let width = panelWidth(index, atlas: atlas)
        let height: Float = textHeight + labelHeight + pad * 2.6

        let hw: SIMD3<Float> = right * (width / 2)
        let hh: SIMD3<Float> = up * (height / 2)
        let bottomLeft: SIMD3<Float> = center - hw - hh
        let bottomRight: SIMD3<Float> = center + hw - hh
        let topRight: SIMD3<Float> = center + hw + hh
        let topLeft: SIMD3<Float> = center - hw + hh
        let corners = [bottomLeft, bottomRight, topRight, topLeft, bottomLeft]
        g.polyline(corners, message.author == 0 ? theme.accent : theme.primary,
                   intensity: 0.9 * outline, width: 1.4, fraction: smoothstep(0, 0.35, age))

        let left = center - hw + right * pad
        let reveal = max(0, age - 0.25) * glyphsPerSecond
        g.text(author.label, atlas: atlas, origin: left + up * (height / 2 - pad - labelHeight * 0.8),
               right: right, up: up, height: labelHeight, color: authorColor, intensity: 0.9 * front)
        g.text(message.text, atlas: atlas, origin: left - up * (height / 2 - pad - textHeight * 0.1),
               right: right, up: up, height: textHeight, color: theme.primary, intensity: front, reveal: reveal)
    }

    private func buildPerson(into g: inout FrameGeometry, atlas: GlyphAtlas, person: Person, at position: SIMD3<Float>,
                             time: Float, theme: Theme, cameraRight: SIMD3<Float>, cameraUp: SIMD3<Float>) {
        let color = color(for: person, theme: theme)
        let spin = simd_quatf(angle: time * 0.7 + person.hue * 6, axis: simd_normalize(SIMD3(0.3, 1, 0.2)))
        let counter = simd_quatf(angle: -time * 1.3, axis: simd_normalize(SIMD3(1, 0.2, 0.4)))
        for (a, b) in person.solid.edges {
            g.line(position + person.solid.vertices[a].rotated(by: spin) * 0.7,
                   position + person.solid.vertices[b].rotated(by: spin) * 0.7, color, intensity: 1.5, width: 1.8)
        }
        for (a, b) in person.core.edges {
            g.line(position + person.core.vertices[a].rotated(by: counter) * 0.28,
                   position + person.core.vertices[b].rotated(by: counter) * 0.28, color, intensity: 1.1, width: 1.2)
        }
        let labelHeight: Float = 0.3
        let w = FrameGeometry.textWidth(person.label, atlas: atlas, height: labelHeight)
        g.text(person.label, atlas: atlas, origin: position - cameraRight * (w / 2) - cameraUp * 1.25,
               right: cameraRight, up: cameraUp, height: labelHeight, color: color, intensity: 0.9)
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
