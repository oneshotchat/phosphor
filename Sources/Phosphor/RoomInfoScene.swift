import simd

/// The room info walls (/room, ⌘I), where the help walls stand and rising out of the
/// floor the same way: the room, centred in front of it, with its settings in plain words
/// and an icon each (operators also see how to change them; a setting that changes while
/// it's up glows for a moment); and beside it, its people. ←→ fly between the two.
@MainActor
struct RoomInfoScene {
    let atlas: GlyphAtlas

    /// Wall 0 (the room) stands centred in front of it; wall 1 (its people) to its right.
    static func base(_ i: Int) -> SIMD3<Float> { SIMD3(Float(i) * HelpScene.pitch, 0, HelpScene.rowZ) }
    static func view(_ i: Float) -> (eye: SIMD3<Float>, target: SIMD3<Float>) {
        let x = i * HelpScene.pitch
        return (SIMD3(x, 5.4, HelpScene.rowZ + 14.5), SIMD3(x, 3.2, HelpScene.rowZ))
    }

    /// `focus` is the wall the camera is at (fractional while flying); `page` the one
    /// it's going to. `glow` is 0…1 per setting label, for ones that just changed.
    func build(into g: inout FrameGeometry, info: RoomInfo, progress: Float, focus: Float, page: Int,
               glow: [String: Float], theme: Theme) {
        let gain = g.gain
        defer { g.gain = gain }
        for i in 0...1 {
            let risen = HelpScene.rise(i, progress: progress, focus: focus)
            guard risen > 0.001 else { continue }
            g.gain = gain * max(0.35, 1 - abs(Float(i) - focus) * 0.65)     // the far wall dimmer
            let selected = i == page
            drawFrame(into: &g, base: Self.base(i), risen: risen, label: i == 0 ? info.name : "PEOPLE", selected: selected,
                      theme: theme)
            if i == 0 {
                drawRoom(into: &g, info: info, base: Self.base(0), risen: risen, glow: glow, theme: theme)
            } else {
                drawPeople(into: &g, info: info, base: Self.base(1), risen: risen, theme: theme)
            }
        }
    }

    /// The wall's frame rising from its slot in the floor, and its name on the floor in front.
    private func drawFrame(into g: inout FrameGeometry, base: SIMD3<Float>, risen: Float, label: String, selected: Bool,
                           theme: Theme) {
        let w = HelpScene.wallWidth / 2, h = HelpScene.wallHeight
        let color = selected ? theme.accent : theme.primary
        g.line(base - SIMD3(w, 0, 0), base + SIMD3(w, 0, 0), color, intensity: selected ? 1.8 : 1.1, width: 2)
        let top = risen * h
        if top > 0.02 {
            for x in [-w, w] { g.line(base + SIMD3(x, 0, 0), base + SIMD3(x, top, 0), theme.primary, intensity: 0.7, width: 1.3) }
            g.line(base + SIMD3(-w, top, 0), base + SIMD3(w, top, 0), theme.primary, intensity: 0.7, width: 1.3)
        }
        let nameSize: Float = selected ? 1.15 : 0.95
        let nameWidth = FrameGeometry.textWidth(label, atlas: atlas, height: nameSize)
        g.text(label, atlas: atlas, origin: base + SIMD3(-nameWidth / 2, 0.03, 1.1 + nameSize), right: [1, 0, 0],
               up: [0, 0, -1], height: nameSize, color: color, intensity: (selected ? 1.6 : 0.8) * max(0.3, risen))
        if selected {
            let hint = "←→ room · people  ·  esc closes"
            let hw = FrameGeometry.textWidth(hint, atlas: atlas, height: 0.5)
            g.text(hint, atlas: atlas, origin: base + SIMD3(-hw / 2, 0.03, 2.1 + nameSize + 0.5), right: [1, 0, 0],
                   up: [0, 0, -1], height: 0.5, color: theme.primary, intensity: 0.7 * risen)
        }
    }

    private func drawRoom(into g: inout FrameGeometry, info: RoomInfo, base: SIMD3<Float>, risen: Float,
                          glow: [String: Float], theme: Theme) {
        let w = HelpScene.wallWidth / 2, h = HelpScene.wallHeight
        let sunk = (1 - risen) * h
        let now = AppClock.now

        // Layout in "lines", scaled down to fit if an operator's extra lines need it.
        let showChange = info.isOperator
        let lineCount = 3.2 + (info.topic == nil ? 0 : 1) + Float(info.settings.count) * (showChange ? 1.75 : 1.15) + 0.6 + 4 * 1.15
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
        // How long the room has been and will be around, on its own line: beside the name
        // it collides with long names.
        y -= lineH * 0.95
        text(info.lifetime, left, y, size * 0.72, theme.primary, 0.6)
        y -= lineH
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
                drawPerson(person, &g, base: base, x: x, y: y, size: size, sunk: sunk, now: now, theme: theme, fade: visible(y))
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

    /// The people wall: everyone here on the left; on the right, people with a role who
    /// aren't here, then who spoke recently but isn't here.
    private func drawPeople(into g: inout FrameGeometry, info: RoomInfo, base: SIMD3<Float>, risen: Float, theme: Theme) {
        let w = HelpScene.wallWidth / 2, h = HelpScene.wallHeight
        let sunk = (1 - risen) * h
        let now = AppClock.now
        let pad: Float = 0.65, size: Float = 0.32, lineH = size * 1.42
        func visible(_ y: Float) -> Float? {
            let above = y - sunk
            return above > 0.05 ? min(1, above / 0.8) : nil
        }
        func text(_ s: String, _ x: Float, _ y: Float, _ height: Float, _ c: SIMD3<Float>, _ intensity: Float) {
            guard let fade = visible(y) else { return }
            g.text(s, atlas: atlas, origin: base + SIMD3(x, y - sunk, 0), right: [1, 0, 0], up: [0, 1, 0], height: height,
                   color: c, intensity: intensity * fade)
        }
        func width(_ s: String, _ height: Float) -> Float { FrameGeometry.textWidth(s, atlas: atlas, height: height) }

        let top = h - pad - size * 1.5
        text("PEOPLE", -w + pad, top, size * 1.5, theme.accent, 1.5)
        text("in \(info.name)", -w + pad + width("PEOPLE", size * 1.5) + size, top, size, theme.primary, 0.7)
        let bottom = pad + size * 0.3
        let columnWidth = w - pad * 1.5

        // A column of people under headings, down to the bottom of the wall; what doesn't
        // fit becomes "+N more".
        func column(_ x: Float, _ sections: [(String, [RoomInfo.Person], String)]) {
            var y = top - lineH * 1.9
            for (heading, people, empty) in sections {
                guard y > bottom else { return }
                text(heading, x, y, size * 0.75, theme.primary, 0.6)
                y -= lineH
                if people.isEmpty {
                    text(empty, x + size * 1.2, y, size * 0.9, theme.primary, 0.45)
                    y -= lineH
                }
                for (i, person) in people.enumerated() {
                    guard y - lineH > bottom || i == people.count - 1 else {
                        text("+\(people.count - i) more", x + size * 1.2, y, size * 0.9, theme.primary, 0.6)
                        y -= lineH
                        break
                    }
                    drawPerson(person, &g, base: base, x: x, y: y, size: size, sunk: sunk, now: now, theme: theme, fade: visible(y),
                               maxWidth: columnWidth - width(person.note, size * 0.8) - size * 2)
                    if !person.note.isEmpty {
                        text(person.note, x + columnWidth - width(person.note, size * 0.8), y, size * 0.8, theme.primary, 0.55)
                    }
                    y -= lineH
                }
                y -= lineH * 0.6
            }
        }
        column(-w + pad, [("HERE NOW · \(info.present.count)", info.present, "nobody")])
        column(pad * 0.5, [("NOT HERE, WITH A ROLE", info.absentRoles, "nobody"),
                           ("RECENTLY SPOKE, NOT HERE", info.recent, "nobody else in the history")])
    }

    /// A person's glyph, then their name in their colour (cut short to `maxWidth`).
    private func drawPerson(_ person: RoomInfo.Person, _ g: inout FrameGeometry, base: SIMD3<Float>, x: Float, y: Float,
                            size: Float, sunk: Float, now: Float, theme: Theme, fade: Float?, maxWidth: Float = .infinity) {
        guard let fade else { return }
        let glyph = IdentityGlyph(fingerprint: person.identity)
        let color = glyph.color(theme: theme)
        glyph.draw(into: &g, at: base + SIMD3(x + size * 0.45, y - sunk + size * 0.35, 0), size: size * 0.45,
                   color: color, intensity: 1.2 * fade, width: 1.3, now: now)
        var label = person.label
        if FrameGeometry.textWidth(label, atlas: atlas, height: size) > maxWidth {
            while !label.isEmpty, FrameGeometry.textWidth(label + "…", atlas: atlas, height: size) > maxWidth { label.removeLast() }
            label += "…"
        }
        g.text(label, atlas: atlas, origin: base + SIMD3(x + size * 1.2, y - sunk, 0), right: [1, 0, 0], up: [0, 1, 0],
               height: size, color: color, intensity: 1.1 * fade)
    }
}
