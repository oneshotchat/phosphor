import Foundation
import OSCCore
import simd

/// Listed rooms you haven't joined, shown only in the overview (⌘L) as a row in front of
/// the active room. They take the same form as joined rooms (flat walls in the row layout,
/// cylinders in the ring) at the same size, but empty: you can't read a room you're not in.
/// Instead, height shows how many are present, a pulse shows recent activity, and the
/// occupants' glyphs stand inside so you can spot people you know. A room key cages it;
/// invite-only seals its top.
@MainActor
struct BrowserScene {
    let atlas: GlyphAtlas
    static let width: Float = 16           // same as a joined room's wall, or cylinder's diameter

    /// `origin` is where a joined room standing there would have its base (front middle),
    /// so joining can start the room exactly where its ghost was.
    struct Placed {
        var room: Room
        var origin: SIMD3<Float>
    }

    func build(into g: inout FrameGeometry, rooms: [Placed], selected: String?, cylinders: Bool,
               alpha: Float, theme: Theme) {
        guard alpha > 0.01 else { return }
        let now = AppClock.now
        let r = Self.width / 2
        for placed in rooms {
            let room = placed.room
            let isSelected = room.id == selected
            let people = room.occupantCount ?? room.occupants?.count ?? 0
            let recent = room.activity?.messagesLast10m ?? 0
            let height = 1.6 + min(Float(people), 20) * 0.22
            // Busier rooms pulse faster; a silent one just glows.
            let pulse = recent > 0 ? 0.75 + 0.25 * sin(now * (1 + min(Float(recent), 12) * 0.5) + placed.origin.x) : 0.85
            let color = isSelected ? theme.accent : theme.primary
            let intensity = (isSelected ? 1.7 : 0.6) * pulse * alpha
            let o = placed.origin
            let center = cylinders ? o - SIMD3(0, 0, r) : o       // walls face the camera (+z)

            if cylinders {
                func ring(_ y: Float) -> [SIMD3<Float>] {
                    (0...64).map { i in
                        let a = Float(i) / 64 * 2 * .pi
                        return center + SIMD3(sin(a) * r, y, cos(a) * r)
                    }
                }
                g.polyline(ring(0.02), color, intensity: intensity, width: 1.4)
                g.polyline(ring(height), color, intensity: intensity * 0.7, width: 1.2)
                let posts = room.access == "key" ? 32 : 8            // a key room is caged
                for i in 0..<posts {
                    let a = Float(i) / Float(posts) * 2 * .pi
                    let foot = center + SIMD3(sin(a) * r, 0, cos(a) * r)
                    g.line(foot, foot + SIMD3(0, height, 0), color, intensity: intensity * (room.access == "key" ? 0.5 : 0.3), width: 1)
                }
                if room.access == "invite" {                         // sealed top
                    for a in stride(from: Float(0), to: .pi, by: .pi / 4) {
                        let d = SIMD3(sin(a) * r, 0, cos(a) * r)
                        g.line(center - d + SIMD3(0, height, 0), center + d + SIMD3(0, height, 0), color, intensity: intensity * 0.6, width: 1)
                    }
                }
            } else {
                let x0 = o - SIMD3(r, 0, 0), x1 = o + SIMD3(r, 0, 0), up = SIMD3<Float>(0, height, 0)
                g.polyline([x0, x1, x1 + up, x0 + up, x0], color, intensity: intensity, width: 1.4)
                if room.access == "key" {                            // caged: vertical bars
                    for i in 1..<16 {
                        let p = x0 + SIMD3(Float(i), 0, 0)
                        g.line(p, p + up, color, intensity: intensity * 0.45, width: 1)
                    }
                }
                if room.access == "invite" {                         // sealed: a crossed top band
                    let band = SIMD3<Float>(0, min(0.8, height * 0.3), 0)
                    g.line(x0 + up - band, x1 + up - band, color, intensity: intensity * 0.7, width: 1)
                    g.line(x0 + up - band, x1 + up, color, intensity: intensity * 0.5, width: 1)
                    g.line(x0 + up, x1 + up - band, color, intensity: intensity * 0.5, width: 1)
                }
            }

            // Who's inside (or standing along the wall), small.
            let shown = min(people, 12)
            for (i, occupant) in (room.occupants ?? []).prefix(12).enumerated() {
                let position: SIMD3<Float>
                if cylinders {
                    let a = Float(i) / Float(max(shown, 1)) * 2 * .pi + now * 0.1
                    position = center + SIMD3(sin(a) * r * 0.55, 0.8, cos(a) * r * 0.55)
                } else {
                    position = o + SIMD3((Float(i) + 0.5) / Float(max(shown, 1)) * Self.width - r, 0.8, 0.6)
                }
                let glyph = IdentityGlyph(fingerprint: occupant.identity)
                glyph.draw(into: &g, at: position, size: 0.34, color: glyph.color(theme: theme),
                           intensity: (isSelected ? 1.2 : 0.7) * alpha, width: 1, now: now)
            }

            // Name and headcount on the floor in front.
            let label = "#" + SafeText.clean(room.name) + "  \(people) here"
            let size: Float = isSelected ? 1.3 : 1.0
            let w = FrameGeometry.textWidth(label, atlas: atlas, height: size)
            g.text(label, atlas: atlas, origin: o + SIMD3(-w / 2, 0.03, 1.6 + size), right: [1, 0, 0], up: [0, 0, -1],
                   height: size, color: color, intensity: (isSelected ? 1.6 : 0.8) * alpha)
        }
    }
}
