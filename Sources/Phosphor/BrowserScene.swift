import Foundation
import OSCCore
import simd

/// Listed rooms you haven't joined, shown only in the overview (⌘L) as a row in front of
/// the active room, at the same size as joined rooms and without messages (you can't read
/// a room you're not in). In the row layout each is just its base line with the people
/// present listed above it, glyph and name. In the ring they're
/// cylinders: height from headcount, occupants inside, a cage for a key and a sealed top
/// for invite-only. Either way a pulse shows recent activity.
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
               alpha: Float, theme: Theme, cameraRight: SIMD3<Float>, cameraUp: SIMD3<Float>) {
        guard alpha > 0.01 else { return }
        let now = AppClock.now
        let r = Self.width / 2
        for placed in rooms {
            let room = placed.room
            let isSelected = room.id == selected
            let people = room.occupantCount ?? room.occupants?.count ?? 0
            let recent = room.activity?.messagesLast10m ?? 0
            let height = 1.6 + min(Float(people), 20) * 0.22      // cylinders only
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
                // Flat: just the base line, pulsing with activity; the people stand on it.
                g.line(o - SIMD3(r, -0.02, 0), o + SIMD3(r, 0.02, 0), color, intensity: intensity * 1.8, width: 2)
            }

            if cylinders {
                // Who's inside, small.
                let shown = min(people, 12)
                for (i, occupant) in (room.occupants ?? []).prefix(12).enumerated() {
                    let a = Float(i) / Float(max(shown, 1)) * 2 * .pi + now * 0.1
                    let glyph = IdentityGlyph(fingerprint: occupant.identity)
                    glyph.draw(into: &g, at: center + SIMD3(sin(a) * r * 0.55, 0.8, cos(a) * r * 0.55), size: 0.34,
                               color: glyph.color(theme: theme), intensity: (isSelected ? 1.2 : 0.7) * alpha, width: 1, now: now)
                }
            } else {
                // A list rising from the line: each person's glyph on the left, their name to
                // the right, written on the wall's plane like a joined room's text.
                let occupants = Array((room.occupants ?? []).prefix(6))
                let labels = Tripcode.labels(for: occupants.map { ($0.name, $0.identity) })
                let rowHeight: Float = 1.35, nameSize: Float = 0.62
                let left = o + SIMD3(-r + 1.1, 0, 0.3)
                for (i, occupant) in occupants.enumerated() {
                    let y = 1.0 + Float(i) * rowHeight
                    let glyph = IdentityGlyph(fingerprint: occupant.identity)
                    let glyphColor = glyph.color(theme: theme)
                    glyph.draw(into: &g, at: left + SIMD3(0, y, 0), size: 0.48, color: glyphColor,
                               intensity: (isSelected ? 1.5 : 1) * alpha, width: 1.6, now: now)
                    let name = SafeText.clean(labels[occupant.identity] ?? occupant.name)
                    g.text(name, atlas: atlas, origin: left + SIMD3(0.95, y - nameSize * 0.35, 0), right: [1, 0, 0], up: [0, 1, 0],
                           height: nameSize, color: glyphColor, intensity: (isSelected ? 1.3 : 0.85) * alpha)
                }
                if people > occupants.count {
                    g.text("+\(people - occupants.count) more", atlas: atlas,
                           origin: left + SIMD3(0.95, 1.0 + Float(occupants.count) * rowHeight - nameSize * 0.35, 0),
                           right: [1, 0, 0], up: [0, 1, 0], height: nameSize * 0.85, color: color, intensity: 0.75 * alpha)
                }
            }

            // Name, headcount and access on the floor in front.
            var label = "#" + SafeText.clean(room.name) + "  \(people) here"
            if room.access == "key" { label += " · key" }
            if room.access == "invite" { label += " · invite only" }
            let size: Float = isSelected ? 1.3 : 1.0
            let w = FrameGeometry.textWidth(label, atlas: atlas, height: size)
            g.text(label, atlas: atlas, origin: o + SIMD3(-w / 2, 0.03, 1.6 + size), right: [1, 0, 0], up: [0, 0, -1],
                   height: size, color: color, intensity: (isSelected ? 1.6 : 0.8) * alpha)
        }
    }
}
