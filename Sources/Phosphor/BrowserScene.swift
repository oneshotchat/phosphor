import Foundation
import OSCCore
import simd

/// Listed rooms you haven't joined, as faint empty cylinders: no messages (you can't read
/// a room you're not in), but height from how many are present, a pulse as fast as its
/// recent activity, and the occupants' identity glyphs inside so you can spot people you
/// know. A room key cages it; invite-only seals its top.
@MainActor
struct BrowserScene {
    let atlas: GlyphAtlas
    static let radius: Float = 5

    func build(into g: inout FrameGeometry, rooms: [(room: Room, center: SIMD3<Float>)], selected: String?,
               browsing: Bool, theme: Theme, eye: SIMD3<Float>) {
        let now = AppClock.now
        let r = Self.radius
        for (room, center) in rooms {
            let isSelected = room.id == selected
            let people = room.occupantCount ?? room.occupants?.count ?? 0
            let recent = room.activity?.messagesLast10m ?? 0
            let height = 2.5 + min(Float(people), 20) * 0.45
            // Busier rooms pulse faster; a silent one just glows.
            let pulse = recent > 0 ? 0.75 + 0.25 * sin(now * (1 + min(Float(recent), 12) * 0.5) + center.x) : 0.85
            let base: Float = browsing ? 0.75 : 0.35
            let color = isSelected ? theme.accent : theme.primary
            let intensity = (isSelected ? 1.8 : base) * pulse

            func ring(_ y: Float) -> [SIMD3<Float>] {
                (0...48).map { i in
                    let a = Float(i) / 48 * 2 * .pi
                    return center + SIMD3(sin(a) * r, y, cos(a) * r)
                }
            }
            g.polyline(ring(0.02), color, intensity: intensity, width: 1.4)
            g.polyline(ring(height), color, intensity: intensity * 0.7, width: 1.2)
            let posts = room.access == "key" ? 24 : 6          // a key room is caged
            for i in 0..<posts {
                let a = Float(i) / Float(posts) * 2 * .pi
                let foot = center + SIMD3(sin(a) * r, 0, cos(a) * r)
                g.line(foot, foot + SIMD3(0, height, 0), color, intensity: intensity * (room.access == "key" ? 0.5 : 0.35), width: 1)
            }
            if room.access == "invite" {                     // sealed top
                for a in stride(from: Float(0), to: .pi, by: .pi / 4) {
                    let d = SIMD3(sin(a) * r, 0, cos(a) * r)
                    g.line(center - d + SIMD3(0, height, 0), center + d + SIMD3(0, height, 0), color, intensity: intensity * 0.6, width: 1)
                }
            }

            // Who's inside, small and dim.
            for (i, occupant) in (room.occupants ?? []).prefix(12).enumerated() {
                let a = Float(i) / Float(min(people, 12)) * 2 * .pi + now * 0.1
                let glyph = IdentityGlyph(fingerprint: occupant.identity)
                glyph.draw(into: &g, at: center + SIMD3(sin(a) * r * 0.5, 0.9, cos(a) * r * 0.5), size: 0.32,
                           color: glyph.color(theme: theme), intensity: browsing ? 0.9 : 0.4, width: 1, now: now)
            }

            // Name on the floor in front, facing the camera.
            let toEye = simd_normalize(SIMD3(eye.x - center.x, 0, eye.z - center.z))
            let right = SIMD3(toEye.z, 0, -toEye.x)
            var label = "#" + SafeText.clean(room.name)
            if browsing || isSelected { label += "  \(people) here" }
            let size: Float = isSelected ? 1.2 : 0.9
            let w = FrameGeometry.textWidth(label, atlas: atlas, height: size)
            g.text(label, atlas: atlas, origin: center + toEye * (r + 1.2) - right * (w / 2) + SIMD3(0, 0.03, 0),
                   right: right, up: -toEye, height: size, color: color, intensity: isSelected ? 1.6 : base * 1.3)
        }
    }
}
