import Foundation
import OSCCore
import simd

/// One room drawn on a `Surface`: messages appear at the bottom and rise, fading into the
/// sky; theirs on the left, yours on the right. Recent speakers stand along the base the
/// same way, with everyone else in a dim gallery behind. A new message is beamed up from
/// its author before it's written.
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
        let glyph: IdentityGlyph
        var name: String
        /// A contact: the ★ under their name, and your petname for them (if it differs).
        var isContact = false
        var petname: String?
        var joinedAt: Float = -100
        var leftAt: Float?
        var leaveReason: String?
        /// Eased position along the wall, so people slide when the speakers change.
        var s: Float?
    }

    /// Server admins by fingerprint, set each frame: they get a shield we draw, beside
    /// their name and under their glyph, which no name can imitate.
    var admins: Set<String> = []

    /// The mark for a person: an admin's shield, else a contact's star.
    private func mark(_ fp: String) -> Icon? { Icon.mark(admin: admins.contains(fp), contact: ContactBook.shared.isContact(fp)) }

    private struct PanelVisual {
        var arrivedAt: Float = -100
        var glitchAt: Float = -100
        /// Set once a message's arrival (or an edit, by version) has been animated, so the
        /// same message seen twice (your send's reply, then its live event) animates once.
        var animated = false
        var editAnimated = -1
        var sparkAt: Float = -100
        var version = -1
        var columns = 0
        var contacts = -1
        var deleted = false
        var lines: [String] = []
        /// Verifying Ed25519 every frame for every message adds up; once per version is enough.
        var signature: (version: Int, status: Message.SignatureStatus)?
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
    // Messages fade into the sky this far above where you're looking. Rooms in the
    // background stand further away with more sky in view, so theirs reaches much higher.
    private let skyFadeStart: Float = 4.6
    private let skyFadeEnd: Float = 8.3
    private let backgroundSkyFadeStart: Float = 13
    private let backgroundSkyFadeEnd: Float = 26
    private var skyStart: Float = 11.8
    private var skyEnd: Float = 15.5
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
    /// Other speakers in the order they first spoke; stable so nobody shuffles.
    private var speakerOrder: [String] = []
    private var lastBuild: Float = 0
    private var charWidths: [Character: Float] = [:]

    /// 0 flat … 1 rolled into a cylinder. Eases toward `targetCurl`.
    private(set) var curl: Float = 0
    var targetCurl: Float = 0
    /// 0 active … 1 in the background (dimmer, messages drift up with age, floor label).
    private(set) var background: Float = 0
    var targetBackground: Float = 0

    // Set by the renderer from the ring/row layout each frame.
    struct Placement {
        var origin = SIMD3<Float>(0, 0, 0)       // front middle of the base
        var normal = SIMD3<Float>(0, 0, 1)       // the way the wall faces
    }
    var placement = Placement()
    /// The middle of the room's footprint on the floor (the cylinder's axis when rolled up).
    var floorCenter: SIMD3<Float> {
        placement.origin - placement.normal * (wallWidth / 2) * curl     // rolled up, the radius is half the wall
    }
    /// Background rooms glow less.
    var dim: Float = 1
    var isActive = true

    /// Where each visible message sits this frame, for reading mode.
    private(set) var panelFrames: [Int: PanelFrame] = [:]
    private(set) var newestVisible: Int?

    // For scrollback: where each message's bottom is headed, the top of the whole stack,
    // and the message nearest the view (the renderer keeps it still while new ones arrive).
    private(set) var targetBottoms: [Int: Float] = [:]
    private(set) var stackTop: Float = 0
    private(set) var referenceMessage: Int?
    /// Set by the renderer while the view is scrolled up; messages arriving then are counted.
    var isLifted = false {
        didSet { if !isLifted { unseen = 0 } }
    }
    private(set) var unseen = 0

    init(atlas: GlyphAtlas) {
        self.atlas = atlas
    }

    /// Forget animations (room switched or reloaded). Existing people and messages just appear.
    /// A newly joined room starts where the layout wants it rather than animating there.
    func settle() {
        curl = targetCurl
        background = targetBackground
    }

    /// A room joined from the overview starts flat and dim where its line stood there, and
    /// moves into place as the active wall.
    func startAsGhost() {
        curl = 0
        background = 1
    }

    func reset() {
        people = [:]
        panels = [:]
        beams = []
        speakerOrder = []
    }

    /// Starts a message's arrival: beam from its author, draw-on, written out. Called for
    /// the live event and when your own send returns, whichever is first; the second is
    /// ignored rather than restarting it.
    func messageArrived(_ m: Message) {
        guard panels[m.id]?.animated != true else { return }
        let now = AppClock.now
        var visual = panels[m.id] ?? PanelVisual()
        visual.arrivedAt = now
        visual.animated = true
        panels[m.id] = visual
        if isLifted { unseen += 1 }
        for target in m.mentions ?? [] where target != m.author.identity {
            beams.append(Beam(from: m.author.identity, to: target, at: now + beamTime))
        }
    }

    /// Glitches and rewrites an edited message, once per version.
    func messageEdited(_ m: Message) {
        guard panels[m.id]?.editAnimated != m.version else { return }
        let now = AppClock.now
        panels[m.id, default: PanelVisual()].glitchAt = now
        panels[m.id]?.arrivedAt = now - beamTime + 0.35   // rewrite once the glitch settles
        panels[m.id]?.animated = true
        panels[m.id]?.editAnimated = m.version
    }

    func handle(_ event: Event) {
        let now = AppClock.now
        switch event.payload {
        case .messageCreated(let m):
            messageArrived(m)
        case .messageEdited(let m):
            messageEdited(m)
        case .messageDeleted(let m):
            // Scramble it out, then the tombstone line writes itself in its place.
            panels[m.id, default: PanelVisual()].glitchAt = now
            panels[m.id]?.arrivedAt = now - beamTime + 0.35
            panels[m.id]?.lines = []
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
               focus: Int?, eye: SIMD3<Float>, cameraRight: SIMD3<Float>, cameraUp: SIMD3<Float>, viewY: Float,
               index: Int, activity: ChatController.Activity) {
        let now = AppClock.now
        let savedGain = g.gain
        g.gain = dim
        defer { g.gain = savedGain }
        let dt = min(max(now - lastBuild, 0), 0.1)
        lastBuild = now
        curl += (targetCurl - curl) * min(1, dt * 3)
        background += (targetBackground - background) * min(1, dt * 3)
        skyStart = viewY + mix(skyFadeStart, backgroundSkyFadeStart, t: background)
        skyEnd = viewY + mix(skyFadeEnd, backgroundSkyFadeEnd, t: background)
        beams.removeAll { now - $0.at > 1.4 }

        let n = placement.normal
        // The surface grows as it rolls so the cylinder is as wide across as the flat wall
        // (8 grid squares): circumference π × wall width when fully rolled.
        let surface = Surface(origin: placement.origin, right: SIMD3(n.z, 0, -n.x), normal: n,
                              width: wallWidth * mix(1, .pi, t: curl), curl: curl)
        buildFloor(into: &g, theme: theme, surface: surface)
        guard let state else {
            panelFrames = [:]
            newestVisible = nil
            return
        }
        let labels = ContactBook.shared.display(state.labels)        // contacts get their petname and mark
        let ease = min(1, dt * 8)

        // Everyone present gets a visual; the departed linger while they animate out.
        for (fp, occupant) in state.occupants {
            if people[fp] == nil || people[fp]?.leftAt != nil {
                people[fp] = makePerson(fp, name: occupant.name, joinedAt: people[fp]?.leftAt != nil ? now : -100)
            }
            // Under a glyph: their chosen name, with a contact's mark, and your petname for
            // them on a line below, so you know who they are whatever they call themselves.
            let short = state.labels[fp] ?? occupant.name
            let contact = ContactBook.shared.contact(fp)
            people[fp]?.name = short
            people[fp]?.isContact = contact != nil
            people[fp]?.petname = contact?.petname.flatMap { $0.isEmpty || $0.lowercased() == occupant.name.lowercased() ? nil : $0 }
        }
        people = people.filter { fp, p in state.occupants[fp] != nil || (p.leftAt.map { now - $0 < 2.5 } ?? false) }

        let newestFirst = Array(state.orderedMessages.reversed())
        let spots = speakerSpots(newestFirst: newestFirst, me: me)

        // People: speakers at their spots along the base, everyone else in the gallery.
        var positions: [String: SIMD3<Float>] = [:]
        let inward = mix(0.9, -surface.cylinderRadius * 0.5, t: curl)   // in front when flat, inside when rolled
        for (fp, person) in people {
            var p = person
            let position: SIMD3<Float>
            let scale: Float
            if let spot = spots[fp] {
                p.s = p.s.map { $0 + (spot - $0) * ease } ?? spot
                position = surface.point(p.s!, 1.05) + surface.normal(at: p.s!) * inward
                scale = fp == me ? 0.62 : 0.55
            } else {
                // Gallery: a dim arc behind the wall (inside the cylinder when rolled up).
                p.s = nil
                let gs = (p.glyph.offset - 0.5) * wallWidth * 0.9
                position = surface.point(gs * (1 - curl), 0.55) + surface.normal(at: gs) * mix(-3.2, -surface.cylinderRadius * 0.3, t: curl)
                scale = 0.32
            }
            people[fp] = p
            positions[fp] = position
            buildPerson(into: &g, fp: fp, person: p, at: position, scale: scale, speaker: spots[fp] != nil,
                        now: now, theme: theme, me: me, surface: surface, eye: eye, cameraRight: cameraRight, cameraUp: cameraUp)
        }

        buildMessages(into: &g, newestFirst: newestFirst, surface: surface, positions: positions,
                      state: state, labels: labels, theme: theme, me: me, origin: origin, focus: focus, eye: eye,
                      viewY: viewY, now: now, ease: ease)

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

        // Rolled up in the background: its name and ⌘ number on the floor in front, a
        // brighter base while it has unread messages, and a beacon if you were mentioned.
        if background > 0.05 {
            // A side room is named for who it's with, not by its (made-up) name.
            let title = state.room.isSide
                ? "side room · " + (SideRoom.other(in: state.room, me: me).flatMap { labels[$0] } ?? "")
                : "#" + SafeText.clean(state.room.name)
            var label = "⌘\(index + 1) " + title
            if activity.unread > 0 { label += "  •\(activity.unread)" }
            if activity.mentioned { label += "  @you" }
            let height: Float = 1.1
            let w = FrameGeometry.textWidth(label, atlas: atlas, height: height)
            g.text(label, atlas: atlas, origin: placement.origin + n * 1.6 - surface.right * (w / 2) + SIMD3(0, 0.02, 0),
                   right: surface.right, up: -n, height: height,
                   color: activity.mentioned ? theme.accent : theme.primary, intensity: (activity.unread > 0 ? 1.4 : 0.8) * background)
            if activity.unread > 0 {
                g.surfaceLine(surface, s0: -surface.width / 2, s1: surface.width / 2, y: 0.05, theme.primary,
                              intensity: min(Float(activity.unread), 8) * 0.25 * background, width: 2.5)
            }
            if activity.mentioned {
                // An unread mention: the base line turns the accent colour until you visit.
                g.surfaceLine(surface, s0: -surface.width / 2, s1: surface.width / 2, y: 0.05, theme.accent,
                              intensity: 1.1 * background, width: 2)
            }
        }
    }

    // MARK: speakers

    /// Where each recent speaker stands along the base: everyone else spread across the
    /// left, in the order they first spoke (stable, so nobody shuffles), you on the right.
    /// Messages follow the same split: theirs on the left, yours on the right.
    private func speakerSpots(newestFirst: [Message], me: String) -> [String: Float] {
        var recent: [String] = []
        for m in newestFirst.prefix(30) where m.author.identity != me && !recent.contains(m.author.identity) {
            recent.append(m.author.identity)
        }
        speakerOrder.removeAll { !recent.contains($0) }
        for fp in recent.reversed() where !speakerOrder.contains(fp) { speakerOrder.append(fp) }

        let half = wallWidth / 2
        let span = wallWidth * 0.72
        var spots: [String: Float] = [:]
        for (i, fp) in speakerOrder.enumerated() {
            spots[fp] = -half + span * (Float(i) + 0.5) / Float(speakerOrder.count)
        }
        spots[me] = half - wallWidth * 0.1
        return spots
    }

    // MARK: messages

    private func buildMessages(into g: inout FrameGeometry, newestFirst: [Message], surface: Surface,
                               positions: [String: SIMD3<Float>], state: RoomState, labels: [String: String], theme: Theme,
                               me: String, origin: String, focus: Int?, eye: SIMD3<Float>, viewY: Float, now: Float, ease: Float) {
        var frames: [Int: PanelFrame] = [:]
        var targets: [Int: Float] = [:]
        newestVisible = newestFirst.first?.id
        let half = wallWidth / 2
        // The same in every state: a width that changed with curl re-wrapped messages as a
        // room rolled or unrolled, changing their heights mid-animation.
        let maxWidth = wallWidth * maxWidthFraction

        // Stack every loaded message (heights are cached), but only draw the ones in view.
        var cursor = baseY
        var nearest: (id: Int, distance: Float)?
        for message in newestFirst {
            // Long messages show their first lines and how many more; the selected one
            // unfolds in full (the panels above make room).
            let allLines = lines(for: message, labels: labels, maxWidth: maxWidth - pad * 2)
            let folded = allLines.count > maxLines && focus != message.id
            let textLines = folded ? Array(allLines.prefix(maxLines - 1)) : allLines
            let hidden = folded ? allLines.count - textLines.count : 0
            let height = panelHeight(lines: textLines.count + (hidden > 0 ? 1 : 0), reactions: hasReactions(message))
            // Same height whether the room is active or in the background, so switching
            // only moves rooms, never their messages.
            let bottom = cursor
            cursor = bottom + height + gap
            targets[message.id] = bottom
            if nearest == nil || abs(bottom - viewY) < nearest!.distance { nearest = (message.id, abs(bottom - viewY)) }

            var visual = panels[message.id] ?? PanelVisual()
            // Skip what's well below the view. Rooms in the background stand much further
            // back, so far more of them shows below the view; only cull there when it's deep.
            guard bottom + height > viewY - mix(18, 60, t: background), bottom < skyEnd + 1 else {
                // Off screen: forget where it was drawn, so it's already in place (height and
                // side) when it comes back into view rather than gliding there.
                visual.y = nil
                visual.s = nil
                panels[message.id] = visual
                continue
            }
            let label = labelLine(message, labels: labels, origin: origin)
            let labelWidth = textWidth(label.name + label.time + label.signature + label.rest, height: labelHeight)
                + (label.signed ? labelHeight * 1.3 : 0)
                + (mark(message.author.identity) != nil ? labelHeight * 1.6 : 0)
            let width = min(maxWidth, max(textLines.map { textWidth($0, height: textHeight) }.max() ?? 0,
                                          labelWidth,
                                          hidden > 0 ? textWidth(Self.moreHint(hidden), height: labelHeight) : 0) + pad * 2)

            // Theirs on the left, yours on the right.
            let sideAnchor = message.author.identity == me ? half - width / 2 : -half + width / 2
            // Around the cylinder: a stable spot per message, golden-ratio spaced so
            // neighbours spread evenly.
            let around = ((Float(message.id) * 0.618034).truncatingRemainder(dividingBy: 1) - 0.5) * surface.width
            let anchor = mix(sideAnchor, around, t: curl)
            visual.y = visual.y.map { $0 + (bottom - $0) * ease } ?? bottom
            visual.s = visual.s.map { $0 + (anchor - $0) * ease } ?? anchor
            panels[message.id] = visual

            let y0 = visual.y!, s = visual.s!
            // Messages fade into the sky by their middle; the selected one stays lit, or a
            // long one unfolding upward would vanish while its bottom is still in view.
            let sky = focus == message.id ? 1 : 1 - smoothstep(skyStart, skyEnd, y0 + height * 0.5)
            guard sky > 0.01 else { continue }
            frames[message.id] = PanelFrame(center: surface.point(s, y0 + height / 2), normal: surface.normal(at: s),
                                            width: width, height: height)
            buildPanel(into: &g, message: message, lines: textLines, hidden: hidden, label: label, s0: s - width / 2, s1: s + width / 2,
                       y0: y0, y1: y0 + height, surface: surface, sky: sky, author: positions[message.author.identity],
                       theme: theme, me: me, origin: origin, focused: focus == message.id, eye: eye, now: now,
                       retention: state.room.retentionSeconds)
        }
        panelFrames = frames
        targetBottoms = targets
        stackTop = cursor
        referenceMessage = nearest?.id
    }

    private func buildPanel(into g: inout FrameGeometry, message: Message, lines textLines: [String], hidden: Int,
                            label: (name: String, time: String, signed: Bool, signature: String, rest: String),
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

        let authorColor = (people[message.author.identity]?.glyph ?? IdentityGlyph(fingerprint: message.author.identity)).color(theme: theme)
        let textS = s0 + pad
        var baseline = y1 - pad - labelHeight * 0.8
        let labelColor = signatureStatus(message, origin: origin) == .invalid ? theme.accent : authorColor
        g.surfaceText(label.name, atlas: atlas, surface: surface, s: textS, baseline: baseline, height: labelHeight,
                      color: labelColor, intensity: 0.9 * bright, eye: eye)
        var restS = textS + textWidth(label.name, height: labelHeight)
        if let icon = mark(message.author.identity) {
            // An admin's shield or a contact's star, drawn by us right after the name.
            let at = restS + labelHeight * 0.85
            icon.draw(into: &g, at: surface.point(at, baseline + labelHeight * 0.36), size: labelHeight * 0.38,
                      right: surface.tangent(at: at), up: [0, 1, 0], color: labelColor,
                      intensity: 1.3 * bright)
            restS += labelHeight * 1.6
        }
        // How long ago it was posted, dimmer than the rest.
        g.surfaceText(label.time, atlas: atlas, surface: surface, s: restS, baseline: baseline, height: labelHeight,
                      color: labelColor, intensity: 0.5 * bright, eye: eye)
        restS += textWidth(label.time, height: labelHeight)
        // The signature: a quiet drawn tick when it checks out (most messages; a name can't
        // fake it), a dim "unsigned", or a loud warning when it doesn't verify.
        if label.signed {
            let at = restS + labelHeight * 0.75
            Icon.tick.draw(into: &g, at: surface.point(at, baseline + labelHeight * 0.36), size: labelHeight * 0.32,
                           right: surface.tangent(at: at), up: [0, 1, 0], color: labelColor, intensity: 0.6 * bright)
            restS += labelHeight * 1.3
        } else if !label.signature.isEmpty {
            let bad = signatureStatus(message, origin: origin) == .invalid
            g.surfaceText(label.signature, atlas: atlas, surface: surface, s: restS, baseline: baseline, height: labelHeight,
                          color: bad ? theme.accent : labelColor, intensity: (bad ? 1.4 : 0.45) * bright, eye: eye)
            restS += textWidth(label.signature, height: labelHeight)
        }
        g.surfaceText(label.rest, atlas: atlas, surface: surface, s: restS, baseline: baseline, height: labelHeight,
                      color: labelColor, intensity: 0.9 * bright, eye: eye)
        baseline -= labelHeight * 0.4 + textHeight * 1.05

        let glitching = now - visual.glitchAt < 0.35
        var reveal = visual.arrivedAt < -50 ? .infinity : max(0, age - beamTime - 0.25) * glyphsPerSecond
        for line in textLines {
            let shown = glitching ? scrambled(line, seed: Int(now * 30)) : line
            g.surfaceText(shown, atlas: atlas, surface: surface, s: textS, baseline: baseline, height: textHeight,
                          color: theme.primary, intensity: bright * (message.isDeleted ? 0.5 : 1),   // a tombstone, dimmer
                          reveal: glitching ? .infinity : reveal, eye: eye)
            reveal -= Float(line.count)
            baseline -= textHeight * 1.25
        }
        if hidden > 0 {
            // A folded long message says how much is left and how to read it.
            g.surfaceText(Self.moreHint(hidden), atlas: atlas, surface: surface,
                          s: textS, baseline: baseline, height: labelHeight, color: theme.accent, intensity: 0.8 * bright,
                          reveal: reveal, eye: eye)
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
        let color = isMe ? theme.accent : person.glyph.color(theme: theme)
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

        person.glyph.draw(into: &g, at: position, size: size, color: color, intensity: intensity,
                          width: speaker ? 1.8 : 1, now: now, draw: draw, scatter: scatter)
        guard speaker, background < 0.5 else { return }
        let label = SafeText.clean(person.name)
        let w = FrameGeometry.textWidth(label, atlas: atlas, height: 0.28)
        g.text(label, atlas: atlas, origin: position - cameraRight * (w / 2) - cameraUp * (size + 0.45),
               right: cameraRight, up: cameraUp, height: 0.28, color: color, intensity: 0.9 * min(intensity, 1.5) * draw)
        // Under the name, centred, in their colour: one mark, an admin's shield or else a contact's
        // star; then your petname, if you gave them one.
        guard let icon = Icon.mark(admin: admins.contains(fp), contact: person.isContact) else { return }
        icon.draw(into: &g, at: position - cameraUp * (size + 0.7), size: 0.12, right: cameraRight, up: cameraUp,
                  color: color, intensity: 1.3 * min(intensity, 1.5) * draw)
        if let pet = person.petname {
            let petLabel = SafeText.clean(pet)
            let pw = FrameGeometry.textWidth(petLabel, atlas: atlas, height: 0.24)
            g.text(petLabel, atlas: atlas, origin: position - cameraRight * (pw / 2) - cameraUp * (size + 1.17),
                   right: cameraRight, up: cameraUp, height: 0.24, color: color, intensity: 0.8 * min(intensity, 1.5) * draw)
        }
    }

    private func buildFloor(into g: inout FrameGeometry, theme: Theme, surface: Surface) {
        // The wall's footprint and its edges rising into the sky.
        let half = surface.width / 2
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
        PersonVisual(glyph: IdentityGlyph(fingerprint: fp), name: name, joinedAt: joinedAt)
    }

    private func signatureStatus(_ m: Message, origin: String) -> Message.SignatureStatus {
        if m.isDeleted { return .unsigned }          // a tombstone keeps its version, not its signature
        if let cached = panels[m.id]?.signature, cached.version == m.version { return cached.status }
        let status = m.signatureStatus(server: origin)
        panels[m.id, default: PanelVisual()].signature = (m.version, status)
        return status
    }

    /// A message's header: the author's name, then (after any mark) how long ago it was
    /// posted, then its signature mark, "(edited)" and id.
    private func labelLine(_ m: Message, labels: [String: String], origin: String)
        -> (name: String, time: String, signed: Bool, signature: String, rest: String) {
        let name = SafeText.clean(labels[m.author.identity] ?? m.author.name)
        let time = m.createdAt.map { "  " + Self.age(-$0.timeIntervalSinceNow) } ?? ""
        // A tombstone has no signature to speak of: nothing is shown for it.
        let status = m.isDeleted ? nil : signatureStatus(m, origin: origin)
        let signature = switch status {
        case .invalid: "  ✗ BAD SIGNATURE"
        case .unsigned: "  unsigned"
        case .valid, nil: ""
        }
        var rest = ""
        if m.editedAt != nil { rest += "  (edited)" }
        return (name, time, status == .valid, signature, rest + "  [\(m.id)]")
    }

    /// "now", "4m", "3h", "2d": short enough for a message header.
    static func age(_ seconds: TimeInterval) -> String {
        let s = Int(max(0, seconds))
        if s < 60 { return "now" }
        if s < 3600 { return "\(s / 60)m" }
        if s < 86400 { return "\(s / 3600)h" }
        return "\(s / 86400)d"
    }

    static func moreHint(_ hidden: Int) -> String { "… \(hidden) more line\(hidden == 1 ? "" : "s") · ↑↓ select it to read all" }

    /// Whether a message is too long to show in full unless it's selected.
    func isLong(_ id: Int) -> Bool { (panels[id]?.lines.count ?? 0) > maxLines }

    private func hasReactions(_ m: Message) -> Bool { !(m.reactions ?? []).isEmpty }

    private func panelHeight(lines: Int, reactions: Bool) -> Float {
        pad * 2 + labelHeight * 1.4 + Float(lines) * textHeight * 1.25 + (reactions ? labelHeight * 1.6 : 0)
    }

    /// Display text wrapped to `maxWidth`. Cached per message version and width.
    private func lines(for m: Message, labels: [String: String], maxWidth: Float) -> [String] {
        let columns = Int(maxWidth / max(textWidth("M", height: textHeight), 0.01))
        if let v = panels[m.id], v.version == m.version, v.columns == columns, v.contacts == ContactBook.shared.revision,
           v.deleted == m.isDeleted, !v.lines.isEmpty { return v.lines }
        // A deleted message shows who removed it, in place of its text (which is gone).
        let text = m.deleted.map { $0.line { labels[$0] } }
            ?? SafeText.clean(MentionText.display(m.text) { labels[$0] ?? String($0.prefix(8)) })
        let wrapped = wrap(text, columns: columns)
        panels[m.id, default: PanelVisual()].lines = wrapped
        panels[m.id]?.version = m.version
        panels[m.id]?.columns = columns
        panels[m.id]?.contacts = ContactBook.shared.revision        // mentions show contacts' petnames
        panels[m.id]?.deleted = m.isDeleted
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
        return out
    }

    private func scrambled(_ s: String, seed: Int) -> String {
        let glyphs = Array("!@#$%&*+=?<>/\\|0123456789ABCDEF")
        var rng = SplitMix64(seed: UInt64(truncatingIfNeeded: seed))
        return String(s.map { $0 == " " ? " " : glyphs[Int.random(in: 0..<glyphs.count, using: &rng)] })
    }
}

private func mix(_ a: Float, _ b: Float, t: Float) -> Float { a + (b - a) * t }
