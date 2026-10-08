import Foundation
import OSCCore
import simd

/// Listed rooms you haven't joined, shown only in the overview (⌘L) as a row in front of
/// the active room: no messages (you can't read a room you're not in), just a narrow base
/// line, pulsing with recent activity, with the people present listed above it, glyph and
/// name, and the room's name, headcount and access on the floor in front.
@MainActor
struct BrowserScene {
    let atlas: GlyphAtlas
    static let width: Float = 8            // narrower than a joined room, so more fit across

    /// `origin` is where a joined room standing there would have its base (front middle),
    /// so joining can start the room exactly where its ghost was.
    struct Placed {
        var room: Room
        var origin: SIMD3<Float>
    }

    func build(into g: inout FrameGeometry, rooms: [Placed], selected: String?, alpha: Float, theme: Theme) {
        guard alpha > 0.01 else { return }
        let now = AppClock.now
        let r = Self.width / 2
        for placed in rooms {
            let room = placed.room
            let isSelected = room.id == selected
            let people = room.occupantCount ?? room.occupants?.count ?? 0
            let recent = room.activity?.messagesLast10m ?? 0
            // Busier rooms pulse faster; a silent one just glows.
            let pulse = recent > 0 ? 0.75 + 0.25 * sin(now * (1 + min(Float(recent), 12) * 0.5) + placed.origin.x) : 0.85
            let color = isSelected ? theme.accent : theme.primary
            let intensity = (isSelected ? 1.7 : 0.6) * pulse * alpha
            let o = placed.origin

            // Just the base line, pulsing with activity; the people are listed above it.
            g.line(o - SIMD3(r, -0.02, 0), o + SIMD3(r, 0.02, 0), color, intensity: intensity * 1.8, width: 2)

            // A list rising from the line: each person's glyph on the left, their name to
            // the right, written on the wall's plane like a joined room's text.
            let occupants = Array((room.occupants ?? []).prefix(8))
            let labels = Tripcode.labels(for: occupants.map { ($0.name, $0.identity) })
            let rowHeight: Float = 1.05, personSize: Float = 0.55
            let left = o + SIMD3(-r + 0.6, 0, 0.3)
            for (i, occupant) in occupants.enumerated() {
                let y = 1.0 + Float(i) * rowHeight
                let glyph = IdentityGlyph(fingerprint: occupant.identity)
                let glyphColor = glyph.color(theme: theme)
                glyph.draw(into: &g, at: left + SIMD3(0, y, 0), size: 0.4, color: glyphColor,
                           intensity: (isSelected ? 1.5 : 1) * alpha, width: 1.5, now: now)
                // Stay within the room; a contact keeps their mark (and petname, if it fits).
                let label = SafeText.clean(labels[occupant.identity] ?? occupant.name)
                var name = ContactBook.shared.display(occupant.identity, label: label, name: SafeText.clean(occupant.name))
                if name.count > 18 {
                    let base = label.count > 14 ? label.prefix(13) + "…" : label
                    name = ContactBook.shared.isContact(occupant.identity) ? base + " ★" : base
                }
                g.text(name, atlas: atlas, origin: left + SIMD3(0.75, y - personSize * 0.35, 0), right: [1, 0, 0], up: [0, 1, 0],
                       height: personSize, color: glyphColor, intensity: (isSelected ? 1.3 : 0.85) * alpha)
            }
            if people > occupants.count {
                g.text("+\(people - occupants.count) more", atlas: atlas,
                       origin: left + SIMD3(0.75, 1.0 + Float(occupants.count) * rowHeight - personSize * 0.35, 0),
                       right: [1, 0, 0], up: [0, 1, 0], height: personSize * 0.85, color: color, intensity: 0.75 * alpha)
            }

            // Name on the floor in front, with headcount and access on a second line.
            var details = "\(people) here"
            if room.access == "key" { details += " · key" }
            if room.access == "invite" { details += " · invite only" }
            let nameSize: Float = isSelected ? 1.25 : 1.05
            let detailSize = nameSize * 0.6
            let name = "#" + SafeText.clean(room.name)
            let nw = FrameGeometry.textWidth(name, atlas: atlas, height: nameSize)
            let dw = FrameGeometry.textWidth(details, atlas: atlas, height: detailSize)
            g.text(name, atlas: atlas, origin: o + SIMD3(-nw / 2, 0.03, 1.2 + nameSize), right: [1, 0, 0], up: [0, 0, -1],
                   height: nameSize, color: color, intensity: (isSelected ? 1.6 : 0.85) * alpha)
            g.text(details, atlas: atlas, origin: o + SIMD3(-dw / 2, 0.03, 1.5 + nameSize + detailSize * 1.4), right: [1, 0, 0],
                   up: [0, 0, -1], height: detailSize, color: color, intensity: (isSelected ? 1.3 : 0.65) * alpha)
        }
    }
}
