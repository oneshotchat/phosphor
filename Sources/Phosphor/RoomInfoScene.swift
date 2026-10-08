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
               glow: [String: Float], selected: String?, peopleFirst: inout Int, theme: Theme) {
        let gain = g.gain
        defer { g.gain = gain }
        for i in 0...1 {
            let risen = HelpScene.rise(i, progress: progress, focus: focus)
            guard risen > 0.001 else { continue }
            g.gain = gain * max(0.35, 1 - abs(Float(i) - focus) * 0.65)     // the far wall dimmer
            drawFrame(into: &g, base: Self.base(i), risen: risen, label: i == 0 ? info.name : "PEOPLE", selected: i == page,
                      theme: theme)
            if i == 0 {
                drawRoom(into: &g, info: info, base: Self.base(0), risen: risen, glow: glow, theme: theme)
            } else {
                drawPeople(into: &g, info: info, base: Self.base(1), risen: risen, selected: selected, first: &peopleFirst,
                           theme: theme)
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
            let hint = label == "PEOPLE" ? "↑↓ pick someone  ·  ← room  ·  esc closes"
                                         : "→ people  ·  ⌘C copies fingerprint  ·  esc closes"
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
        let lineCount = 4.0 + (info.topic == nil ? 0 : 1) + Float(info.settings.count) * (showChange ? 1.75 : 1.15) + 0.6 + 4 * 1.15
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
        y -= lineH * 0.8
        // The room's fingerprint: its name can change hands, this can't.
        text("fingerprint  " + info.roomID, left, y, size * 0.6, theme.primary, 0.45)
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

    /// The people wall: one list, everyone here first. People who aren't here have a dark
    /// glyph and a dimmer name. ↑↓ move a highlight down the list; the selected person's
    /// details (fingerprint and all) show in a strip at the bottom, so the rows never move.
    /// `first` is the first row shown: the list scrolls only when the selection reaches an edge.
    private func drawPeople(into g: inout FrameGeometry, info: RoomInfo, base: SIMD3<Float>, risen: Float, selected: String?,
                            first: inout Int, theme: Theme) {
        let w = HelpScene.wallWidth / 2, h = HelpScene.wallHeight
        let sunk = (1 - risen) * h
        let now = AppClock.now
        let pad: Float = 0.65, size: Float = 0.34, lineH = size * 1.5
        func visible(_ y: Float) -> Float? {
            let above = y - sunk
            return above > 0.05 ? min(1, above / 0.8) : nil
        }
        func text(_ s: String, _ x: Float, _ y: Float, _ height: Float, _ c: SIMD3<Float>, _ intensity: Float) {
            guard let fade = visible(y) else { return }
            g.text(s, atlas: atlas, origin: base + SIMD3(x, y - sunk, 0), right: [1, 0, 0], up: [0, 1, 0], height: height,
                   color: c, intensity: intensity * fade)
        }
        func rule(_ y: Float, _ from: Float, _ to: Float) {
            guard visible(y) != nil else { return }
            g.line(base + SIMD3(from, y - sunk, 0), base + SIMD3(to, y - sunk, 0), theme.primary, intensity: 0.35, width: 1)
        }
        func width(_ s: String, _ height: Float) -> Float { FrameGeometry.textWidth(s, atlas: atlas, height: height) }

        let left = -w + pad, right = w - pad
        let nameX = left + size * 1.3, roleX = left + 4.6, spokeX = left + 6.6
        let people = info.everyone
        let here = people.filter(\.isHere).count, others = people.count - here
        let headingH = size * 0.7          // a group's heading

        // Heading.
        var y = h - pad - size * 1.5
        text("PEOPLE", left, y, size * 1.5, theme.accent, 1.5)
        text("in \(info.name)", left + width("PEOPLE", size * 1.5) + size, y, size, theme.primary, 0.7)

        // The details strip, fixed at the bottom.
        let stripTop = pad + lineH * 2.1
        rule(stripTop, left, right)
        let detailsY = stripTop - lineH * 0.95, fingerprintY = detailsY - lineH * 0.85
        if let person = people.first(where: { $0.identity == selected }) {
            drawPerson(person, &g, base: base, x: left, y: detailsY, size: size, sunk: sunk, now: now, theme: theme,
                       fade: visible(detailsY), maxWidth: roleX - nameX, bright: true, dark: !person.isHere)
            let status = info.statuses[person.identity].map { $0 == "retired" ? "retired identity" : "\($0) identity" }
            let facts = [person.isYou ? "you" : nil, person.role.isEmpty ? nil : person.role,
                         person.isHere ? "here now" : "not here", status].compactMap { $0 }.joined(separator: " · ")
            text(facts, roleX, detailsY, size * 0.8, theme.accent, 0.9)
            let small = size * 0.62
            text(person.identity, nameX, fingerprintY, small, theme.accent, 0.9)
            text("⌘C copies", right - width("⌘C copies", small), fingerprintY, small, theme.primary, 0.6)
        } else {
            text("↑↓ pick someone to see their fingerprint", nameX, detailsY, size * 0.8, theme.primary, 0.45)
        }

        // Rows, on baselines `lineH` apart, between the column headings and the strip. When
        // the list reaches the people who aren't here, it leaves a gap, a rule and their
        // heading: about one and a half rows.
        let listTop = y - lineH * 1.5                   // the column headings' baseline
        let firstRow = listTop - lineH * 1.05
        let listBottom = stripTop + lineH * 0.55        // the lowest a row's baseline may be
        let switchCost = lineH * 1.5
        let bothGroups = here > 0 && others > 0
        let roomy = max(1, Int((firstRow - listBottom) / lineH) + 1)
        let tight = max(1, Int((firstRow - listBottom - (bothGroups ? switchCost : 0)) / lineH) + 1)
        if let i = people.firstIndex(where: { $0.identity == selected }) {
            if i < first { first = i }
            if i >= first + tight { first = i - tight + 1 }
        }
        first = max(0, min(first, people.count - tight))
        // The break between the groups only costs room when it's in view.
        let breakInView = bothGroups && first < here && here < first + roomy
        let shown = people.dropFirst(first).prefix(breakInView ? tight : roomy)

        // Column headings; the first group's heading shares their line.
        let startsHere = shown.first?.isHere ?? true
        text(startsHere ? "HERE NOW · \(here)" : "NOT HERE · \(others)", nameX, listTop, headingH, theme.primary, 0.6)
        text("ROLE", roleX, listTop, headingH, theme.primary, 0.5)
        text("LAST SPOKE", spokeX, listTop, headingH, theme.primary, 0.5)
        if first > 0 { text("↑ \(first) more", right - width("↑ \(first) more", headingH), listTop, headingH, theme.primary, 0.55) }

        y = firstRow
        var group = startsHere
        for person in shown {
            if person.isHere != group {
                // A gap below the last row, a rule, then the heading with room under it.
                rule(y + lineH * 0.45, nameX, right)
                y -= lineH * 0.35
                text("NOT HERE · \(others)", nameX, y, headingH, theme.primary, 0.6)
                y -= lineH * 1.15
                group = person.isHere
            }
            let isSelected = person.identity == selected
            if isSelected { text("▸", left - size * 0.9, y, size, theme.accent, 1.5) }
            drawPerson(person, &g, base: base, x: left, y: y, size: size, sunk: sunk, now: now, theme: theme, fade: visible(y),
                       maxWidth: roleX - nameX - size * 1.8, bright: isSelected, dark: !person.isHere)
            if person.isYou {
                text("you", nameX + min(width(person.label, size), roleX - nameX - size * 1.8) + size * 0.5, y, size * 0.75,
                     theme.primary, 0.5)
            }
            let detail = isSelected ? theme.accent : theme.primary
            let dim: Float = person.isHere ? 1 : 0.6
            if !person.role.isEmpty { text(person.role, roleX, y, size * 0.85, detail, 0.8 * dim) }
            text(person.lastSpoke ?? "—", spokeX, y, size * 0.85, detail, 0.9 * dim)
            y -= lineH
        }
        let rest = people.count - first - shown.count
        if rest > 0 { text("↓ \(rest) more", right - width("↓ \(rest) more", headingH), y + lineH * 0.2, headingH, theme.primary, 0.55) }
    }

    /// A person's glyph, then their name in their colour (cut short to `maxWidth`).
    private func drawPerson(_ person: RoomInfo.Person, _ g: inout FrameGeometry, base: SIMD3<Float>, x: Float, y: Float,
                            size: Float, sunk: Float, now: Float, theme: Theme, fade: Float?, maxWidth: Float = .infinity,
                            bright: Bool = false, dark: Bool = false) {
        guard let fade else { return }
        let glyph = IdentityGlyph(fingerprint: person.identity)
        let color = glyph.color(theme: theme)
        // Someone who isn't here: a dark glyph, standing still, and a dimmer name.
        glyph.draw(into: &g, at: base + SIMD3(x + size * 0.45, y - sunk + size * 0.35, 0), size: size * 0.45,
                   color: color, intensity: (dark ? 0.16 : 1.2) * fade, width: 1.3, now: dark ? 0 : now)
        var label = person.label
        if FrameGeometry.textWidth(label, atlas: atlas, height: size) > maxWidth {
            while !label.isEmpty, FrameGeometry.textWidth(label + "…", atlas: atlas, height: size) > maxWidth { label.removeLast() }
            label += "…"
        }
        g.text(label, atlas: atlas, origin: base + SIMD3(x + size * 1.2, y - sunk, 0), right: [1, 0, 0], up: [0, 1, 0],
               height: size, color: dark && !bright ? simd_mix(color, theme.primary, SIMD3(repeating: 0.6)) : color,
               intensity: (bright ? 1.6 : dark ? 0.4 : 1.1) * fade)
    }
}
