import Foundation
import OSCCore
import simd

/// The live room as a vector display: messages on a helix (newest at the top, older ones
/// sliding down into the floor), people as fingerprint-seeded wireframes in orbit.
/// Events trigger animations; everything else is redrawn from `RoomState` each frame.
@MainActor
final class RoomScene {
    struct PanelFrame {
        var center: SIMD3<Float>
        var normal: SIMD3<Float>
        var width: Float
        var height: Float
    }

    private struct PersonVisual {
        let solid: Wireframe
        let core: Wireframe
        let hue: Float
        let angle: Float
        let height: Float
        var name: String
        var joinedAt: Float = -100
        var leftAt: Float?
        var leaveReason: String?
    }

    private struct PanelVisual {
        var arrivedAt: Float = -100
        var glitchAt: Float = -100
        var sparkAt: Float = -100
        var version = -1
        var lines: [String] = []
    }

    private struct Beam {
        let from: String
        let to: String
        let at: Float
    }

    let topY: Float = 10
    private let radius: Float = 7.5
    private let step: Float = 0.42
    private let gap: Float = 0.35
    private let textHeight: Float = 0.26
    private let labelHeight: Float = 0.19
    private let pad: Float = 0.2
    private let maxColumns = 44
    private let maxLines = 10
    private let glyphsPerSecond: Float = 60

    private let atlas: GlyphAtlas
    private var people: [String: PersonVisual] = [:]
    private var panels: [Int: PanelVisual] = [:]
    private var beams: [Beam] = []
    private var shift: Float = 0
    /// The helix turns so the newest message faces the camera.
    private var baseAngle: Float = 0
    private var lastBuild: Float = 0
    private var charWidths: [Character: Float] = [:]

    /// Where each visible message sits this frame, for reading mode.
    private(set) var panelFrames: [Int: PanelFrame] = [:]
    private(set) var newestVisible: Int?

    init(atlas: GlyphAtlas) {
        self.atlas = atlas
    }

    /// Forget animations (room switched or reloaded). Existing people and messages just appear.
    func reset() {
        people = [:]
        panels = [:]
        beams = []
        shift = 0
    }

    func handle(_ event: Event) {
        let now = AppClock.now
        switch event.payload {
        case .messageCreated(let m):
            panels[m.id] = PanelVisual(arrivedAt: now)
            shift = min(shift + 1, 3)
            for target in m.mentions ?? [] where target != m.author.identity {
                beams.append(Beam(from: m.author.identity, to: target, at: now))
            }
        case .messageEdited(let m):
            panels[m.id, default: PanelVisual()].glitchAt = now
            panels[m.id]?.arrivedAt = now + 0.35
        case .reactionAdded(let r):
            panels[r.messageId]?.sparkAt = now
        case .memberJoined(let j):
            var person = makePerson(j.identity, name: j.name)
            person.joinedAt = now
            people[j.identity] = person
        case .memberLeft(let l):
            people[l.identity]?.leftAt = now
            people[l.identity]?.leaveReason = l.reason
        default:
            break
        }
    }

    // MARK: build

    /// `followCamera` false holds the helix still (reading mode moves the camera to a
    /// panel; turning the helix after it would chase forever).
    func build(into g: inout FrameGeometry, state: RoomState?, theme: Theme, me: String, origin: String,
               focus: Int?, eye: SIMD3<Float>, cameraRight: SIMD3<Float>, cameraUp: SIMD3<Float>, followCamera: Bool) {
        let now = AppClock.now
        let dt = min(max(now - lastBuild, 0), 0.1)
        lastBuild = now
        shift *= exp(-dt * 5)
        if followCamera {
            var delta = atan2(eye.x, eye.z) - baseAngle
            delta = atan2(sin(delta), cos(delta))   // shortest way round
            baseAngle += delta * min(1, dt * 3)
        }
        beams.removeAll { now - $0.at > 1.4 }

        buildFloor(into: &g, theme: theme)
        guard let state else {
            panelFrames = [:]
            newestVisible = nil
            return
        }
        let labels = state.labels

        // People: everyone present gets a visual; the departed linger while they animate out.
        for (fp, occupant) in state.occupants {
            if people[fp] == nil || people[fp]?.leftAt != nil {
                people[fp] = makePerson(fp, name: occupant.name, joinedAt: people[fp]?.leftAt != nil ? now : -100)
            }
            people[fp]?.name = labels[fp] ?? occupant.name
        }
        people = people.filter { fp, p in state.occupants[fp] != nil || (p.leftAt.map { now - $0 < 2.5 } ?? false) }
        for (fp, person) in people {
            buildPerson(into: &g, fp: fp, person: person, now: now, theme: theme, me: me,
                        cameraRight: cameraRight, cameraUp: cameraUp)
        }

        buildMessages(into: &g, state: state, labels: labels, theme: theme, me: me, origin: origin,
                      focus: focus, eye: eye, now: now)

        for beam in beams {
            guard let a = people[beam.from].map({ personPosition($0, now: now) }),
                  let b = people[beam.to].map({ personPosition($0, now: now) }) else { continue }
            let age = now - beam.at
            let mid = (a + b) * 0.5 + SIMD3(0, 5, 0)
            let arc = (0...32).map { k -> SIMD3<Float> in
                let s = Float(k) / 32
                return (1 - s) * (1 - s) * a + 2 * (1 - s) * s * mid + s * s * b
            }
            g.polyline(arc, beam.to == me ? theme.accent : theme.primary,
                       intensity: 2.2 * (1 - smoothstep(0.8, 1.4, age)), width: 2.5, fraction: smoothstep(0, 0.6, age))
        }

        // Room title over the helix.
        let top = SIMD3<Float>(0, topY + 2.4, 0)
        let title = "#" + SafeText.clean(state.room.name)
        let titleWidth = FrameGeometry.textWidth(title, atlas: atlas, height: 0.9)
        g.text(title, atlas: atlas, origin: top - cameraRight * titleWidth / 2, right: cameraRight, up: cameraUp,
               height: 0.9, color: theme.primary, intensity: 1.3)
        let topic = SafeText.clean(state.room.topic ?? "").replacingOccurrences(of: "\n", with: " ")
        if !topic.isEmpty {
            let w = FrameGeometry.textWidth(topic, atlas: atlas, height: 0.3)
            g.text(topic, atlas: atlas, origin: top - cameraRight * w / 2 - cameraUp * 0.55, right: cameraRight, up: cameraUp,
                   height: 0.3, color: theme.primary, intensity: 0.7)
        }
    }

    private func buildMessages(into g: inout FrameGeometry, state: RoomState, labels: [String: String], theme: Theme,
                               me: String, origin: String, focus: Int?, eye: SIMD3<Float>, now: Float) {
        let newestFirst = Array(state.orderedMessages.suffix(40).reversed())
        var frames: [Int: PanelFrame] = [:]
        newestVisible = newestFirst.first?.id

        // Spine from the floor up to the newest message.
        g.line([0, 0, 0], [0, topY + 1, 0], theme.primary, intensity: 0.45, width: 1)

        var y = topY
        if let first = newestFirst.first {
            y += shift * (panelHeight(lines: lines(for: first, labels: labels).count, reactions: hasReactions(first)) + gap)
        }
        for (k, message) in newestFirst.enumerated() {
            let textLines = lines(for: message, labels: labels)
            let height = panelHeight(lines: textLines.count, reactions: hasReactions(message))
            let centerY = y - height / 2
            y -= height + gap
            if centerY < 0.5 { break }

            let angle = baseAngle - (Float(k) - shift) * step
            let normal = SIMD3<Float>(sin(angle), 0, cos(angle))
            let right = SIMD3<Float>(cos(angle), 0, -sin(angle))
            let center = normal * radius + SIMD3(0, centerY, 0)
            let width = max(textLines.map { textWidth($0, height: textHeight) }.max() ?? 0,
                            FrameGeometry.textWidth(labelLine(message, labels: labels, origin: origin), atlas: atlas, height: labelHeight)) + pad * 2
            frames[message.id] = PanelFrame(center: center, normal: normal, width: width, height: height)
            buildPanel(into: &g, message: message, lines: textLines, labels: labels, center: center, right: right,
                       normal: normal, width: width, height: height, theme: theme, me: me, origin: origin,
                       focused: focus == message.id, eye: eye, now: now,
                       retention: state.room.retentionSeconds)
        }
        panelFrames = frames
    }

    private func buildPanel(into g: inout FrameGeometry, message: Message, lines textLines: [String], labels: [String: String],
                            center: SIMD3<Float>, right: SIMD3<Float>, normal: SIMD3<Float>, width: Float, height: Float,
                            theme: Theme, me: String, origin: String, focused: Bool, eye: SIMD3<Float>, now: Float,
                            retention: Int?) {
        let up = SIMD3<Float>(0, 1, 0)
        let visual = panels[message.id] ?? PanelVisual()

        // Turned-away panels dim to an outline; text is never drawn mirrored.
        let facing = simd_dot(normal, simd_normalize(eye - center))
        var front = smoothstep(-0.05, 0.35, facing)
        // Fade into the floor, and decay as the message nears its expiry.
        front *= smoothstep(0.5, 1.6, center.y)
        if let expires = message.expiresAt, let retention, retention > 0 {
            let left = Float(expires.timeIntervalSinceNow) / (Float(retention) * 0.1)
            if left < 1 { front *= max(0.25, left) * (0.9 + 0.1 * sin(now * 37 + Float(message.id))) }
        }
        let outline = max(front, 0.12 * smoothstep(0.5, 1.6, center.y))

        let mine = message.author.identity == me
        let mentionsMe = message.mentions?.contains(me) ?? false
        let age = now - visual.arrivedAt
        let edgeColor = mine || mentionsMe ? theme.accent : theme.primary
        let edgeIntensity: Float = (focused ? 2 : mentionsMe ? 1.3 : 0.9) * outline

        let hw = right * (width / 2)
        let hh = up * (height / 2)
        let bl: SIMD3<Float> = center - hw - hh
        let br: SIMD3<Float> = center + hw - hh
        let tr: SIMD3<Float> = center + hw + hh
        let tl: SIMD3<Float> = center - hw + hh
        g.polyline([bl, br, tr, tl, bl], edgeColor, intensity: edgeIntensity, width: focused ? 2.2 : 1.4,
                   fraction: smoothstep(0, 0.35, age))
        if focused {
            // L-shaped brackets just outside each corner.
            for (corner, sx, sy) in [(tl, -right, up), (tr, right, up), (br, right, -up), (bl, -right, -up)] {
                let tip = corner + (sx + sy) * 0.12
                g.line(tip, tip - sx * 0.45, theme.accent, intensity: 1.6, width: 2)
                g.line(tip, tip - sy * 0.45, theme.accent, intensity: 1.6, width: 2)
            }
        }

        let author = people[message.author.identity]
        let authorColor = author.map { color(hue: $0.hue, theme: theme) } ?? color(hue: hue(of: message.author.identity), theme: theme)
        let left = center - hw + right * pad
        var baseline = center + hh - up * (pad + labelHeight * 0.8)
        g.text(labelLine(message, labels: labels, origin: origin), atlas: atlas, origin: left + baseline - center,
               right: right, up: up, height: labelHeight, color: message.signatureStatus(server: origin) == .invalid ? theme.accent : authorColor,
               intensity: 0.9 * front)
        baseline -= up * (labelHeight * 0.4 + textHeight * 1.05)

        // Beam-write new messages; scramble briefly on edit.
        let glitching = now - visual.glitchAt < 0.35
        var reveal = age < 0 ? 0 : (age - 0.25) * glyphsPerSecond
        if visual.arrivedAt < -50 { reveal = .infinity }
        for line in textLines {
            let shown = glitching ? scrambled(line, seed: Int(now * 30)) : line
            g.text(shown, atlas: atlas, origin: left + baseline - center, right: right, up: up, height: textHeight,
                   color: theme.primary, intensity: front, reveal: glitching ? .infinity : reveal)
            reveal -= Float(line.count)
            baseline -= up * (textHeight * 1.25)
        }
        if hasReactions(message) {
            let reactions = (message.reactions ?? []).map { "\(SafeText.clean($0.reaction)) \($0.count)" }.joined(separator: "  ")
            g.text(reactions, atlas: atlas, origin: left + baseline - center, right: right, up: up, height: labelHeight,
                   color: theme.accent, intensity: 0.9 * front)
        }

        // Reaction sparks off the top-right corner.
        let sparkAge = now - visual.sparkAt
        if sparkAge < 0.6 {
            for i in 0..<10 {
                let a = Float(i) / 10 * 2 * .pi
                let dir = right * cos(a) + up * sin(a) + normal * 0.3
                let start = tr + dir * (sparkAge * 2)
                g.line(start, start + dir * 0.25, theme.accent, intensity: 2.5 * (1 - sparkAge / 0.6), width: 1.6)
            }
        }
    }

    private func buildPerson(into g: inout FrameGeometry, fp: String, person: PersonVisual, now: Float, theme: Theme, me: String,
                             cameraRight: SIMD3<Float>, cameraUp: SIMD3<Float>) {
        var position = personPosition(person, now: now)
        let isMe = fp == me
        let color = isMe ? theme.accent : self.color(hue: person.hue, theme: theme)
        var intensity: Float = 1.5
        var draw: Float = smoothstep(0, 0.8, now - person.joinedAt)   // join: edges draw on
        var scatter: Float = 0

        if let leftAt = person.leftAt {
            let t = now - leftAt
            switch person.leaveReason {
            case "kicked":
                scatter = t * 3
                intensity *= max(0, 1 - t / 1.2)
            case "banned":
                scatter = t * 6
                intensity *= t < 0.1 ? 4 : max(0, 1 - t / 0.8)
            case "timeout":
                intensity *= max(0, 1 - t / 2.5)            // phosphor decay
            default:
                draw = 1 - smoothstep(0, 0.8, t)            // edges draw off
            }
            position.y += scatter * 0.2
        }
        guard intensity > 0.01, draw > 0.001 else { return }

        let spin = simd_quatf(angle: now * 0.7 + person.hue * 6, axis: simd_normalize(SIMD3(0.3, 1, 0.2)))
        let counter = simd_quatf(angle: -now * 1.3, axis: simd_normalize(SIMD3(1, 0.2, 0.4)))
        let size: Float = isMe ? 0.85 : 0.7
        for (shape, scale, rotation, width, gain) in [(person.solid, size, spin, Float(1.8), Float(1)),
                                                      (person.core, size * 0.4, counter, Float(1.2), Float(0.75))] {
            for (a, b) in shape.edges {
                var pa = shape.vertices[a].rotated(by: rotation) * scale
                var pb = shape.vertices[b].rotated(by: rotation) * scale
                if scatter > 0 {
                    let push = simd_normalize(pa + pb + SIMD3(0.001, 0, 0)) * scatter
                    pa += push
                    pb += push
                }
                g.polyline([position + pa, position + pb], color, intensity: intensity * gain, width: width, fraction: draw)
            }
        }
        let label = SafeText.clean(person.name)
        let w = FrameGeometry.textWidth(label, atlas: atlas, height: 0.3)
        g.text(label, atlas: atlas, origin: position - cameraRight * (w / 2) - cameraUp * 1.3,
               right: cameraRight, up: cameraUp, height: 0.3, color: color, intensity: 0.9 * min(intensity, 1.5) * draw)
    }

    private func buildFloor(into g: inout FrameGeometry, theme: Theme) {
        let extent: Float = 40
        var x = -extent
        while x <= extent {
            g.line([x, 0, -extent], [x, 0, extent], theme.grid, intensity: 0.5, width: 1)
            g.line([-extent, 0, x], [extent, 0, x], theme.grid, intensity: 0.5, width: 1)
            x += 2
        }
        let ring = (0...64).map { k -> SIMD3<Float> in
            let a = Float(k) / 64 * 2 * .pi
            return SIMD3(sin(a) * radius, 0.01, cos(a) * radius)
        }
        g.polyline(ring, theme.primary, intensity: 0.6, width: 1.2)
    }

    // MARK: helpers

    private func makePerson(_ fp: String, name: String, joinedAt: Float = -100) -> PersonVisual {
        var rng = SplitMix64(string: fp)
        return PersonVisual(
            solid: Wireframe.random(using: &rng, jitter: 0.18),
            core: Wireframe.random(using: &rng, jitter: 0.1),
            hue: Float.random(in: 0..<1, using: &rng),
            angle: Float.random(in: 0..<(2 * .pi), using: &rng),
            height: Float.random(in: 1.6...7, using: &rng),
            name: name,
            joinedAt: joinedAt
        )
    }

    private func personPosition(_ p: PersonVisual, now: Float) -> SIMD3<Float> {
        let a = p.angle + now * 0.05
        return SIMD3(sin(a) * 12, p.height, cos(a) * 12)
    }

    private func hue(of fp: String) -> Float {
        var rng = SplitMix64(string: fp)
        _ = Wireframe.random(using: &rng, jitter: 0.18)
        _ = Wireframe.random(using: &rng, jitter: 0.1)
        return Float.random(in: 0..<1, using: &rng)
    }

    private func color(hue: Float, theme: Theme) -> SIMD3<Float> {
        theme.monochrome ? theme.primary : hsv(hue, 0.65, 1)
    }

    private func labelLine(_ m: Message, labels: [String: String], origin: String) -> String {
        var line = SafeText.clean(labels[m.author.identity] ?? m.author.name)
        switch m.signatureStatus(server: origin) {
        case .valid: line += " ✓signed"
        case .invalid: line += " ✗ BAD SIGNATURE"
        case .unsigned: break
        }
        if m.editedAt != nil { line += " (edited)" }
        return line + "  [\(m.id)]"
    }

    private func hasReactions(_ m: Message) -> Bool { !(m.reactions ?? []).isEmpty }

    private func panelHeight(lines: Int, reactions: Bool) -> Float {
        pad * 2 + labelHeight * 1.4 + Float(lines) * textHeight * 1.25 + (reactions ? labelHeight * 1.6 : 0)
    }

    /// Display text, wrapped to the panel width. Cached per message version.
    private func lines(for m: Message, labels: [String: String]) -> [String] {
        if let v = panels[m.id], v.version == m.version, !v.lines.isEmpty { return v.lines }
        let text = SafeText.clean(MentionText.display(m.text) { labels[$0] ?? String($0.prefix(8)) })
        let wrapped = wrap(text)
        panels[m.id, default: PanelVisual()].lines = wrapped
        panels[m.id]?.version = m.version
        return wrapped
    }

    private func charWidth(_ c: Character) -> Float {
        if let w = charWidths[c] { return w }
        let w = atlas.layout(String(c)).width
        charWidths[c] = w
        return w
    }

    private func textWidth(_ s: String, height: Float) -> Float {
        s.reduce(0) { $0 + charWidth($1) } * height / Float(atlas.bakeSize)
    }

    private func wrap(_ text: String) -> [String] {
        let maxWidth = charWidth("M") * Float(maxColumns)
        var out: [String] = []
        for paragraph in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = ""
            var lineWidth: Float = 0
            for word in paragraph.split(separator: " ", omittingEmptySubsequences: false) {
                let w = word.reduce(0) { $0 + charWidth($1) }
                let space = line.isEmpty ? 0 : charWidth(" ")
                if lineWidth + space + w <= maxWidth {
                    if !line.isEmpty { line += " " }
                    line += word
                    lineWidth += space + w
                    continue
                }
                if !line.isEmpty { out.append(line) }
                line = ""
                lineWidth = 0
                for ch in word {   // a word longer than a line breaks anywhere
                    let cw = charWidth(ch)
                    if lineWidth + cw > maxWidth, !line.isEmpty {
                        out.append(line)
                        line = ""
                        lineWidth = 0
                    }
                    line.append(ch)
                    lineWidth += cw
                }
            }
            out.append(line)
        }
        if out.count > maxLines {
            out = Array(out.prefix(maxLines))
            out[maxLines - 1] += " …"
        }
        return out
    }

    private func scrambled(_ s: String, seed: Int) -> String {
        let glyphs = Array("!@#$%&*+=?<>/\\|0123456789ABCDEF")
        var rng = SplitMix64(seed: UInt64(truncatingIfNeeded: seed))
        return String(s.map { $0 == " " ? " " : glyphs[Int.random(in: 0..<glyphs.count, using: &rng)] })
    }
}
