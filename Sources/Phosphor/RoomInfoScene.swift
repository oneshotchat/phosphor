import simd

/// The room info wall (/room, ⌘I): one wall where the help walls stand, centred in front
/// of the room, rising out of the floor the same way. Settings get an icon each, in plain
/// words; operators also see how to change them. A setting that changes while it's up
/// glows for a moment.
@MainActor
struct RoomInfoScene {
    let atlas: GlyphAtlas

    static let base = SIMD3<Float>(0, 0, HelpScene.rowZ)
    static let view = (eye: SIMD3<Float>(0, 5.4, HelpScene.rowZ + 14.5), target: SIMD3<Float>(0, 3.2, HelpScene.rowZ))

    /// `glow` is 0…1 per setting label, for ones that just changed.
    func build(into g: inout FrameGeometry, info: RoomInfo, progress: Float, glow: [String: Float], theme: Theme) {
        let risen = smoothstep(0, 1, simd_clamp(progress, 0, 1))
        guard risen > 0.001 else { return }
        let w = HelpScene.wallWidth / 2, h = HelpScene.wallHeight
        let base = Self.base
        let sunk = (1 - risen) * h
        let now = AppClock.now

        // Frame and floor slot, as the help walls.
        g.line(base - SIMD3(w, 0, 0), base + SIMD3(w, 0, 0), theme.accent, intensity: 1.8, width: 2)
        let top = h - sunk
        if top > 0.02 {
            for x in [-w, w] { g.line(base + SIMD3(x, 0, 0), base + SIMD3(x, top, 0), theme.primary, intensity: 0.7, width: 1.3) }
            g.line(base + SIMD3(-w, top, 0), base + SIMD3(w, top, 0), theme.primary, intensity: 0.7, width: 1.3)
        }
        let nameSize: Float = 1.15
        let nameWidth = FrameGeometry.textWidth(info.name, atlas: atlas, height: nameSize)
        g.text(info.name, atlas: atlas, origin: base + SIMD3(-nameWidth / 2, 0.03, 1.1 + nameSize), right: [1, 0, 0],
               up: [0, 0, -1], height: nameSize, color: theme.accent, intensity: 1.6 * max(0.3, risen))
        let hint = "esc closes  ·  ⌘I"
        let hw = FrameGeometry.textWidth(hint, atlas: atlas, height: 0.5)
        g.text(hint, atlas: atlas, origin: base + SIMD3(-hw / 2, 0.03, 2.1 + nameSize + 0.5), right: [1, 0, 0],
               up: [0, 0, -1], height: 0.5, color: theme.primary, intensity: 0.7 * risen)

        // Layout in "lines", scaled down to fit if an operator's extra lines need it.
        let showChange = info.isOperator
        let lineCount = 2.3 + (info.topic == nil ? 0 : 1) + Float(info.settings.count) * (showChange ? 1.75 : 1.15) + 0.6 + 4 * 1.15
        let pad: Float = 0.65
        let size = min(0.38, (h - pad * 2) / lineCount / 1.3)
        let lineH = size * 1.3
        func visible(_ y: Float) -> Float? {
            let above = y - sunk
            return above > 0.05 ? min(1, above / 0.8) : nil
        }
        func text(_ s: String, _ x: Float, _ y: Float, _ height: Float, _ c: SIMD3<Float>, _ intensity: Float) {
            guard let fade = visible(y) else { return }
            g.text(s, atlas: atlas, origin: base + SIMD3(x, y - sunk, 0), right: [1, 0, 0], up: [0, 1, 0], height: height,
                   color: c, intensity: intensity * fade)
        }
        func icon(_ icon: Icon, _ x: Float, _ y: Float, _ intensity: Float) {
            guard let fade = visible(y) else { return }
            icon.draw(into: &g, at: base + SIMD3(x, y - sunk + size * 0.35, 0), size: size * 0.55, right: [1, 0, 0], up: [0, 1, 0],
                      color: theme.accent, intensity: intensity * fade)
        }
        func width(_ s: String, _ height: Float) -> Float { FrameGeometry.textWidth(s, atlas: atlas, height: height) }

        let left = -w + pad
        let iconX = left + size * 0.55, labelX = left + size * 1.9, valueX = labelX + width("VISIBILITY", size * 0.75) + size * 1.2

        // Name and lifetime, then the topic; the whole block centred on the wall.
        let used = lineCount * lineH
        var y = min(h - pad, (h + used) / 2) - size * 1.5
        text(info.name, left, y, size * 1.5, theme.accent, 1.5)
        let lifeSize = size * 0.7
        text(info.lifetime, w - pad - width(info.lifetime, lifeSize), y, lifeSize, theme.primary, 0.6)
        y -= lineH * 1.1
        if let topic = info.topic {
            var shown = topic
            while width(shown, size * 0.8) > w * 2 - pad * 2, !shown.isEmpty { shown.removeLast() }
            text(shown == topic ? topic : shown.dropLast() + "…", left, y, size * 0.8, theme.primary, 0.75)
            y -= lineH
        }
        y -= lineH * 0.5

        for row in info.settings {
            let lit = glow[row.label] ?? 0
            let pulse = 1 + lit * 1.6
            icon(row.icon, iconX, y, 1.3 * pulse)
            text(row.label, labelX, y + size * 0.08, size * 0.75, theme.primary, 0.55)
            text(row.value, valueX, y, size, lit > 0 ? theme.accent : theme.primary, 1.2 * pulse)
            y -= lineH * 1.15
            if showChange, let change = row.change {
                text(change, valueX, y + lineH * 0.45, size * 0.72, theme.primary, 0.5)
                y -= lineH * 0.6
            }
        }
        y -= lineH * 0.6

        // People: how many, the operators here by glyph and name, then you.
        icon(.person, iconX, y, 1.3)
        text("PEOPLE", labelX, y + size * 0.08, size * 0.75, theme.primary, 0.55)
        text("\(info.here) here", valueX, y, size, theme.primary, 1.2)
        y -= lineH * 1.15

        icon(.crown, iconX, y, 1.3)
        text("OPERATORS", labelX, y + size * 0.08, size * 0.75, theme.primary, 0.55)
        if info.operators.isEmpty {
            text("none here", valueX, y, size, theme.primary, 0.7)
        } else {
            var x = valueX
            for (i, person) in info.operators.enumerated() {
                let label = person.label
                guard x + size * 1.2 + width(label, size) < w - pad else {
                    text("+\(info.operators.count - i)", x, y, size, theme.primary, 0.8)
                    break
                }
                drawPerson(person, &g, x: x, y: y, size: size, sunk: sunk, now: now, theme: theme, fade: visible(y))
                x += size * 1.2 + width(label, size) + size * 1.1
            }
        }
        y -= lineH * 1.15

        text("YOU", labelX, y + size * 0.08, size * 0.75, theme.primary, 0.55)
        // Your own glyph stands in the icon column.
        let mine = IdentityGlyph(fingerprint: info.you.identity), myColor = mine.color(theme: theme)
        if let fade = visible(y) {
            mine.draw(into: &g, at: base + SIMD3(iconX, y - sunk + size * 0.35, 0), size: size * 0.5, color: myColor,
                      intensity: 1.2 * fade, width: 1.3, now: now)
        }
        text(info.you.label, valueX, y, size, myColor, 1.1)
        text("  ·  \(info.youAre)", valueX + width(info.you.label, size), y, size, theme.primary, 0.9)
        y -= lineH * 1.15

        icon(info.signing ? .pen : .penCrossed, iconX, y, 1.3)
        text("SIGNING", labelX, y + size * 0.08, size * 0.75, theme.primary, 0.55)
        text(info.signing ? "your messages are signed" : "not signing: /sign signs one", valueX, y, size, theme.primary, 1.0)
    }

    /// A person's glyph, then their name in their colour.
    private func drawPerson(_ person: RoomInfo.Person, _ g: inout FrameGeometry, x: Float, y: Float, size: Float, sunk: Float,
                            now: Float, theme: Theme, fade: Float?) {
        guard let fade else { return }
        let glyph = IdentityGlyph(fingerprint: person.identity)
        let color = glyph.color(theme: theme)
        glyph.draw(into: &g, at: Self.base + SIMD3(x + size * 0.45, y - sunk + size * 0.35, 0), size: size * 0.45,
                   color: color, intensity: 1.2 * fade, width: 1.3, now: now)
        g.text(person.label, atlas: atlas, origin: Self.base + SIMD3(x + size * 1.2, y - sunk, 0), right: [1, 0, 0], up: [0, 1, 0],
               height: size, color: color, intensity: 1.1 * fade)
    }
}
