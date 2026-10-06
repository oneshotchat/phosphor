import Foundation
import OSCCore
import simd

/// One room drawn on a `Surface`: messages appear at the bottom and rise, fading into the
/// sky; recent speakers stand along the base in lanes, with everyone else in a dim gallery
/// behind. A new message is beamed up from its author before it's written.
///
/// The room is flat (readable) when active and can roll up into a cylinder (`curl`) for
/// the background; both use the same layout.
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
        var name: String
        var joinedAt: Float = -100
        var leftAt: Float?
        var leaveReason: String?
        /// Eased position along the wall, so lanes slide when they change.
        var s: Float?
        var galleryOffset: Float
    }

    private struct PanelVisual {
        var arrivedAt: Float = -100
        var glitchAt: Float = -100
        var sparkAt: Float = -100
        var version = -1
        var columns = 0
        var lines: [String] = []
        /// Eased bottom height, so older messages glide up as new ones arrive.
        var y: Float?
        var s: Float?
    }

    private struct Beam {
        let from: String
        let to: String
        let at: Float
    }

    // Layout, in world units.
    let wallWidth: Float = 16
    private let baseY: Float = 2.1          // bottom of the newest message
    private let skyStart: Float = 9.5       // messages start fading here…
    private let skyEnd: Float = 13.5        // …and are gone by here
    private let gap: Float = 0.28
    private let textHeight: Float = 0.34
    private let labelHeight: Float = 0.24
    private let pad: Float = 0.22
    private let maxWidthFraction: Float = 0.6
    private let maxLines = 10
    private let glyphsPerSecond: Float = 70
    private let beamTime: Float = 0.3       // author → message, before the panel draws on

    private let atlas: GlyphAtlas
    private var people: [String: PersonVisual] = [:]
    private var panels: [Int: PanelVisual] = [:]
    private var beams: [Beam] = []
    /// Other people's lanes in the order they first spoke; stable so lanes don't shuffle.
    private var laneOrder: [String] = []
    private var lastBuild: Float = 0
    private var charWidths: [Character: Float] = [:]

    /// 0 flat … 1 rolled into a cylinder. Eases toward `targetCurl`.
    private(set) var curl: Float = 0
    var targetCurl: Float = 0

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
        laneOrder = []
    }

    func handle(_ event: Event) {
        let now = AppClock.now
        switch event.payload {
        case .messageCreated(let m):
            panels[m.id] = PanelVisual(arrivedAt: now)
            for target in m.mentions ?? [] where target != m.author.identity {
                beams.append(Beam(from: m.author.identity, to: target, at: now + beamTime))
            }
        case .messageEdited(let m):
            panels[m.id, default: PanelVisual()].glitchAt = now
            panels[m.id]?.arrivedAt = now - beamTime + 0.35   // rewrite once the glitch settles
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

    func build(into g: inout FrameGeometry, state: RoomState?, theme: Theme, me: String, origin: String,
               focus: Int?, eye: SIMD3<Float>, cameraRight: SIMD3<Float>, cameraUp: SIMD3<Float>) {
        let now = AppClock.now
        let dt = min(max(now - lastBuild, 0), 0.1)
        lastBuild = now
        curl += (targetCurl - curl) * min(1, dt * 3)
        beams.removeAll { now - $0.at > 1.4 }

        let surface = Surface(origin: [0, 0, 0], right: [1, 0, 0], normal: [0, 0, 1], width: wallWidth, curl: curl)
        buildFloor(into: &g, theme: theme, surface: surface)
        guard let state else {
            panelFrames = [:]
            newestVisible = nil
            return
        }
        let labels = state.labels
        let ease = min(1, dt * 8)

        // Everyone present gets a visual; the departed linger while they animate out.
        for (fp, occupant) in state.occupants {
            if people[fp] == nil || people[fp]?.leftAt != nil {
                people[fp] = makePerson(fp, name: occupant.name, joinedAt: people[fp]?.leftAt != nil ? now : -100)
            }
            people[fp]?.name = labels[fp] ?? occupant.name
        }
        people = people.filter { fp, p in state.occupants[fp] != nil || (p.leftAt.map { now - $0 < 2.5 } ?? false) }

        let newestFirst = Array(state.orderedMessages.suffix(60).reversed())
        let lanes = layoutLanes(newestFirst: newestFirst, me: me)

        // People: speakers on their lanes at the base, everyone else in the gallery.
        var positions: [String: SIMD3<Float>] = [:]
        let inward = mix(0.9, -surface.cylinderRadius * 0.5, t: curl)   // in front when flat, inside when rolled
        for (fp, person) in people {
            var p = person
            let position: SIMD3<Float>
            let scale: Float
            if let laneS = lanes.personS[fp] {
                p.s = p.s.map { $0 + (laneS - $0) * ease } ?? laneS
                position = surface.point(p.s!, 1.05) + surface.normal(at: p.s!) * inward
                scale = fp == me ? 0.62 : 0.55
            } else {
                // Gallery: a dim arc behind the wall (inside the cylinder when rolled up).
                p.s = nil
                let gs = (p.galleryOffset - 0.5) * wallWidth * 0.9
                position = surface.point(gs * (1 - curl), 0.55) + surface.normal(at: gs) * mix(-3.2, -surface.cylinderRadius * 0.3, t: curl)
                scale = 0.32
            }
            people[fp] = p
            positions[fp] = position
            buildPerson(into: &g, fp: fp, person: p, at: position, scale: scale, speaker: lanes.personS[fp] != nil,
                        now: now, theme: theme, me: me, surface: surface, eye: eye, cameraRight: cameraRight, cameraUp: cameraUp)
        }

        // Faint rails from each speaker up into the sky tie lanes to their messages.
        for (fp, s) in lanes.personS where people[fp] != nil && lanes.isLanes {
            g.line(surface.point(s, 1.9), surface.point(s, skyStart), theme.grid, intensity: 0.18, width: 1)
        }

        buildMessages(into: &g, newestFirst: newestFirst, lanes: lanes, surface: surface, positions: positions,
                      state: state, labels: labels, theme: theme, me: me, origin: origin, focus: focus, eye: eye,
                      now: now, ease: ease)

        // Mention beams arc between people once the message has landed.
        for beam in beams where now >= beam.at {
            guard let a = positions[beam.from], let b = positions[beam.to] else { continue }
            let age = now - beam.at
            let mid = (a + b) * 0.5 + SIMD3(0, 3.5, 1.5)
            let arc = (0...32).map { k -> SIMD3<Float> in
                let t = Float(k) / 32
                return (1 - t) * (1 - t) * a + 2 * (1 - t) * t * mid + t * t * b
            }
            g.polyline(arc, beam.to == me ? theme.accent : theme.primary,
                       intensity: 2.2 * (1 - smoothstep(0.8, 1.4, age)), width: 2.5, fraction: smoothstep(0, 0.6, age))
        }

        // Room name painted on the floor in front of the wall, like a plinth.
        let floorUp = SIMD3<Float>(0, 0, -1), floorRight = SIMD3<Float>(1, 0, 0)
        let plinth = surface.point(-wallWidth / 2, 0) + SIMD3(0, 0.02, 3.2 * (1 - curl))
        g.text("#" + SafeText.clean(state.room.name), atlas: atlas, origin: plinth, right: floorRight, up: floorUp,
               height: 0.9, color: theme.primary, intensity: 1.1 * curl)
        let topic = SafeText.clean(state.room.topic ?? "").replacingOccurrences(of: "\n", with: " ")
        if !topic.isEmpty {
            g.text(topic, atlas: atlas, origin: plinth + SIMD3(0, 0, 0.75), right: floorRight, up: floorUp,
                   height: 0.32, color: theme.primary, intensity: 0.6 * curl)
        }
    }

    // MARK: lanes

    private struct Lanes {
        /// Arc position of each speaker's spot along the base.
        var personS: [String: Float] = [:]
        /// Where a message by this author is anchored, and whether it hugs a side.
        var align: [String: Align] = [:]
        var isLanes = true
        enum Align { case center(Float), left, right }
    }

    /// Up to 4 speakers (you included) get evenly spaced lanes with messages offset toward
    /// their author. More than that and it's two columns: everyone else left, you right.
    private func layoutLanes(newestFirst: [Message], me: String) -> Lanes {
        var recent: [String] = []
        for m in newestFirst.prefix(30) where m.author.identity != me && !recent.contains(m.author.identity) {
            recent.append(m.author.identity)
        }
        laneOrder.removeAll { !recent.contains($0) }
        for fp in recent.reversed() where !laneOrder.contains(fp) { laneOrder.append(fp) }

        var lanes = Lanes()
        let half = wallWidth / 2
        if laneOrder.count + 1 <= 4 {
            let all = laneOrder + [me]   // you're always on the right
            for (i, fp) in all.enumerated() {
                let s = -half + wallWidth * (Float(i) + 0.5) / Float(all.count)
                lanes.personS[fp] = s
                lanes.align[fp] = .center(s)
            }
        } else {
            lanes.isLanes = false
            let span = wallWidth * 0.72
            for (i, fp) in laneOrder.enumerated() {
                lanes.personS[fp] = -half + span * (Float(i) + 0.5) / Float(laneOrder.count)
                lanes.align[fp] = .left
            }
            lanes.personS[me] = half - wallWidth * 0.1
            lanes.align[me] = .right
        }
        return lanes
    }

    // MARK: messages

    private func buildMessages(into g: inout FrameGeometry, newestFirst: [Message], lanes: Lanes, surface: Surface,
                               positions: [String: SIMD3<Float>], state: RoomState, labels: [String: String], theme: Theme,
                               me: String, origin: String, focus: Int?, eye: SIMD3<Float>, now: Float, ease: Float) {
        var frames: [Int: PanelFrame] = [:]
        newestVisible = newestFirst.first?.id
        let half = wallWidth / 2
        let maxWidth = wallWidth * maxWidthFraction

        var cursor = baseY
        for message in newestFirst {
            guard cursor < skyEnd else { break }
            let textLines = lines(for: message, labels: labels, maxWidth: maxWidth - pad * 2)
            let label = labelLine(message, labels: labels, origin: origin)
            let height = panelHeight(lines: textLines.count, reactions: hasReactions(message))
            let width = min(maxWidth, max(textLines.map { textWidth($0, height: textHeight) }.max() ?? 0,
                                          textWidth(label, height: labelHeight)) + pad * 2)

            // Horizontal anchor from the author's lane.
            let anchor: Float = switch lanes.align[message.author.identity] ?? .left {
            case .center(let s): simd_clamp(s, -half + width / 2, half - width / 2)
            case .left: -half + width / 2
            case .right: half - width / 2
            }
            var visual = panels[message.id] ?? PanelVisual()
            visual.y = visual.y.map { $0 + (cursor - $0) * ease } ?? cursor
            visual.s = visual.s.map { $0 + (anchor - $0) * ease } ?? anchor
            panels[message.id] = visual
            cursor += height + gap

            let y0 = visual.y!, s = visual.s!
            let sky = 1 - smoothstep(skyStart, skyEnd, y0 + height * 0.5)
            guard sky > 0.01 else { continue }
            frames[message.id] = PanelFrame(center: surface.point(s, y0 + height / 2), normal: surface.normal(at: s),
                                            width: width, height: height)
            buildPanel(into: &g, message: message, lines: textLines, label: label, s0: s - width / 2, s1: s + width / 2,
                       y0: y0, y1: y0 + height, surface: surface, sky: sky, author: positions[message.author.identity],
                       theme: theme, me: me, origin: origin, focused: focus == message.id, eye: eye, now: now,
                       retention: state.room.retentionSeconds)
        }
        panelFrames = frames
    }

    private func buildPanel(into g: inout FrameGeometry, message: Message, lines textLines: [String], label: String,
                            s0: Float, s1: Float, y0: Float, y1: Float, surface: Surface, sky: Float,
                            author: SIMD3<Float>?, theme: Theme, me: String, origin: String, focused: Bool,
                            eye: SIMD3<Float>, now: Float, retention: Int?) {
        let visual = panels[message.id] ?? PanelVisual()
        let mid = (s0 + s1) / 2
        let center = surface.point(mid, (y0 + y1) / 2)
        let facing = simd_dot(surface.normal(at: mid), simd_normalize(eye - center))
        var bright = sky
        if let expires = message.expiresAt, let retention, retention > 0 {
            // Decay as the message nears its expiry.
            let left = Float(expires.timeIntervalSinceNow) / (Float(retention) * 0.1)
            if left < 1 { bright *= max(0.25, left) * (0.9 + 0.1 * sin(now * 37 + Float(message.id))) }
        }
        let outline = bright * max(smoothstep(-0.05, 0.35, facing), 0.12)

        // Arrival: beam from the author up to the panel's base, then the panel draws on,
        // then the text is written.
        let age = now - visual.arrivedAt
        let landing = surface.point(mid, y0)
        if age < beamTime + 0.3, let author {
            let head = smoothstep(0, beamTime, age)
            let tail = smoothstep(beamTime, beamTime + 0.3, age)
            let from = simd_mix(author, landing, SIMD3(repeating: tail))
            let to = simd_mix(author, landing, SIMD3(repeating: head))
            g.line(from, to, theme.accent, intensity: 2.6, width: 2.4)
            g.line(to, to + SIMD3(0, 0.001, 0), theme.accent, intensity: 4, width: 6)   // the bright head
        }
        let drawOn = smoothstep(0, 0.3, age - beamTime)
        guard drawOn > 0 || visual.arrivedAt < -50 else { return }

        let mine = message.author.identity == me
        let mentionsMe = message.mentions?.contains(me) ?? false
        let edgeColor = mine || mentionsMe ? theme.accent : theme.primary
        g.surfaceRect(surface, s0: s0, s1: s1, y0: y0, y1: y1, edgeColor,
                      intensity: (focused ? 2 : mentionsMe ? 1.3 : 0.9) * outline, width: focused ? 2.2 : 1.4,
                      fraction: visual.arrivedAt < -50 ? 1 : drawOn)
        if focused {
            for (s, y, ds, dy) in [(s0, y1, -1, 1), (s1, y1, 1, 1), (s1, y0, 1, -1), (s0, y0, -1, -1)] as [(Float, Float, Float, Float)] {
                let tip = surface.point(s + ds * 0.12, y + dy * 0.12)
                g.line(tip, surface.point(s + ds * 0.12 - ds * 0.45, y + dy * 0.12), theme.accent, intensity: 1.6 * sky, width: 2)
                g.line(tip, surface.point(s + ds * 0.12, y + dy * 0.12 - dy * 0.45), theme.accent, intensity: 1.6 * sky, width: 2)
            }
        }

        let authorColor = people[message.author.identity].map { color(hue: $0.hue, theme: theme) }
            ?? color(hue: hue(of: message.author.identity), theme: theme)
        let textS = s0 + pad
        var baseline = y1 - pad - labelHeight * 0.8
        g.surfaceText(label, atlas: atlas, surface: surface, s: textS, baseline: baseline, height: labelHeight,
                      color: message.signatureStatus(server: origin) == .invalid ? theme.accent : authorColor,
                      intensity: 0.9 * bright, eye: eye)
        baseline -= labelHeight * 0.4 + textHeight * 1.05

        let glitching = now - visual.glitchAt < 0.35
        var reveal = visual.arrivedAt < -50 ? .infinity : max(0, age - beamTime - 0.25) * glyphsPerSecond
        for line in textLines {
            let shown = glitching ? scrambled(line, seed: Int(now * 30)) : line
            g.surfaceText(shown, atlas: atlas, surface: surface, s: textS, baseline: baseline, height: textHeight,
                          color: theme.primary, intensity: bright, reveal: glitching ? .infinity : reveal, eye: eye)
            reveal -= Float(line.count)
            baseline -= textHeight * 1.25
        }
        if hasReactions(message) {
            let reactions = (message.reactions ?? []).map { "\(SafeText.clean($0.reaction)) \($0.count)" }.joined(separator: "  ")
            g.surfaceText(reactions, atlas: atlas, surface: surface, s: textS, baseline: baseline, height: labelHeight,
                          color: theme.accent, intensity: 0.9 * bright, eye: eye)
        }

        // Reaction sparks off the top-right corner.
        let sparkAge = now - visual.sparkAt
        if sparkAge < 0.6 {
            let corner = surface.point(s1, y1)
            let right = surface.tangent(at: s1), normal = surface.normal(at: s1), up = SIMD3<Float>(0, 1, 0)
            for i in 0..<10 {
                let a = Float(i) / 10 * 2 * .pi
                let dir = right * cos(a) + up * sin(a) + normal * 0.3
                let start = corner + dir * (sparkAge * 2)
                g.line(start, start + dir * 0.25, theme.accent, intensity: 2.5 * (1 - sparkAge / 0.6), width: 1.6)
            }
        }
    }

    // MARK: people

    private func buildPerson(into g: inout FrameGeometry, fp: String, person: PersonVisual, at base: SIMD3<Float>,
                             scale size: Float, speaker: Bool, now: Float, theme: Theme, me: String, surface: Surface,
                             eye: SIMD3<Float>, cameraRight: SIMD3<Float>, cameraUp: SIMD3<Float>) {
        var position = base
        let isMe = fp == me
        let color = isMe ? theme.accent : self.color(hue: person.hue, theme: theme)
        var intensity: Float = speaker ? 1.5 : 0.55
        var draw = smoothstep(0, 0.8, now - person.joinedAt)   // join: edges draw on
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
                g.polyline([position + pa, position + pb], color, intensity: intensity * gain,
                           width: speaker ? width : 1, fraction: draw)
            }
        }
        guard speaker else { return }
        let label = SafeText.clean(person.name)
        let w = FrameGeometry.textWidth(label, atlas: atlas, height: 0.28)
        g.text(label, atlas: atlas, origin: position - cameraRight * (w / 2) - cameraUp * (size + 0.45),
               right: cameraRight, up: cameraUp, height: 0.28, color: color, intensity: 0.9 * min(intensity, 1.5) * draw)
    }

    private func buildFloor(into g: inout FrameGeometry, theme: Theme, surface: Surface) {
        let extent: Float = 40
        var x = -extent
        while x <= extent {
            g.line([x, 0, -extent], [x, 0, extent], theme.grid, intensity: 0.45, width: 1)
            g.line([-extent, 0, x], [extent, 0, x], theme.grid, intensity: 0.45, width: 1)
            x += 2
        }
        // The wall's footprint and its edges rising into the sky.
        let half = wallWidth / 2
        g.surfaceLine(surface, s0: -half, s1: half, y: 0.02, theme.primary, intensity: 0.8, width: 1.4)
        g.surfaceLine(surface, s0: -half, s1: half, y: baseY - 0.25, theme.primary, intensity: 0.25, width: 1)
        for s in [-half, half] {
            let steps = 12
            for i in 0..<steps {
                let a = baseY - 0.25 + (skyEnd - baseY) * Float(i) / Float(steps)
                let b = baseY - 0.25 + (skyEnd - baseY) * Float(i + 1) / Float(steps)
                g.line(surface.point(s, a), surface.point(s, b), theme.primary,
                       intensity: 0.35 * (1 - smoothstep(skyStart, skyEnd, b)), width: 1)
            }
        }
    }

    // MARK: helpers

    private func makePerson(_ fp: String, name: String, joinedAt: Float = -100) -> PersonVisual {
        var rng = SplitMix64(string: fp)
        let solid = Wireframe.random(using: &rng, jitter: 0.18)
        let core = Wireframe.random(using: &rng, jitter: 0.1)
        let hue = Float.random(in: 0..<1, using: &rng)
        return PersonVisual(solid: solid, core: core, hue: hue, name: name, joinedAt: joinedAt,
                            galleryOffset: Float.random(in: 0..<1, using: &rng))
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

    /// Display text wrapped to `maxWidth`. Cached per message version and width.
    private func lines(for m: Message, labels: [String: String], maxWidth: Float) -> [String] {
        let columns = Int(maxWidth / max(textWidth("M", height: textHeight), 0.01))
        if let v = panels[m.id], v.version == m.version, v.columns == columns, !v.lines.isEmpty { return v.lines }
        let text = SafeText.clean(MentionText.display(m.text) { labels[$0] ?? String($0.prefix(8)) })
        let wrapped = wrap(text, columns: columns)
        panels[m.id, default: PanelVisual()].lines = wrapped
        panels[m.id]?.version = m.version
        panels[m.id]?.columns = columns
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

    private func wrap(_ text: String, columns: Int) -> [String] {
        let maxWidth = charWidth("M") * Float(max(columns, 8))
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

private func mix(_ a: Float, _ b: Float, t: Float) -> Float { a + (b - a) * t }
