import Foundation
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
                           theme: Theme, hint customHint: String? = nil) {
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
            let hint = customHint ?? (label == "PEOPLE" ? "↑↓ pick  ·  ⏎ save / rename  ·  ← room  ·  esc closes"
                                                        : "→ people  ·  ⌘C copies fingerprint  ·  esc closes")
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

        // One text size for every room, whoever you are there: sized for the fullest wall
        // (an operator's change lines and a topic wrapped to three lines), so moving
        // between rooms never resizes it.
        let showChange = info.isOperator
        let fullest = 4.0 + 3 * 0.9 + Float(info.settings.count) * 1.75 + 0.6 + 4 * 1.15
        let pad: Float = 0.65
        let size = min(0.38, (h - pad * 2) / fullest / 1.3)
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
        // Anchored to the top, so the name and settings start in the same place every time.
        var y = h - pad - size * 1.5
        text(info.name, left, y, fitted(info.name, size * 1.5, w * 2 - pad * 2), theme.accent, 1.5)
        // How long the room has been and will be around, on its own line: beside the name
        // it collides with long names.
        y -= lineH * 0.95
        text(info.lifetime, left, y, size * 0.72, theme.primary, 0.6)
        y -= lineH * 0.8
        // The room's fingerprint: its name can change hands, this can't.
        text("fingerprint  " + info.roomID, left, y, size * 0.6, theme.primary, 0.45)
        y -= lineH
        // The topic always gets room for three lines, used or not, so the settings below
        // start in the same place in every room.
        let topicTop = y
        for line in info.topic.map({ wrapped($0, height: size * 0.8, width: w * 2 - pad * 2) }) ?? [] {
            text(line, left, y, size * 0.8, theme.primary, 0.75)
            y -= lineH * 0.9
        }
        y = topicTop - lineH * (3 * 0.9 + 0.1) - lineH * 0.5

        for row in info.settings {
            let lit = glow[row.label] ?? 0
            let pulse = 1 + lit * 1.6
            icon(row.icon, iconX, y, 1.3 * pulse)
            text(row.label, labelX, y + size * 0.08, size * 0.75, theme.primary, 0.55)
            text(row.value, valueX, y, size, lit > 0 ? theme.accent : theme.primary, 1.2 * pulse)
            y -= lineH * 1.15
            // An operator sees how to change it; everyone else gets the same gap.
            if showChange, let change = row.change {
                text(change, valueX, y + lineH * 0.45, size * 0.72, theme.primary, 0.5)
            }
            y -= lineH * 0.6
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
        let youAre = "  ·  \(info.youAre)"
        let myLabel = cut(info.you.label, size, w - pad - valueX - width(youAre, size))
        text(myLabel, valueX, y, size, myColor, 1.1)
        text(youAre, valueX + width(myLabel, size), y, size, theme.primary, 0.9)
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
        let inX = left + width("PEOPLE", size * 1.5) + size
        text("in \(info.name)", inX, y, fitted("in \(info.name)", size, right - inX), theme.primary, 0.7)

        // The details strip, fixed at the bottom.
        let stripTop = pad + lineH * 2.1
        rule(stripTop, left, right)
        let detailsY = stripTop - lineH * 0.95, fingerprintY = detailsY - lineH * 0.85
        if let person = people.first(where: { $0.identity == selected }) {
            // Name on the left, facts right-aligned; the facts get at least the right half
            // and shrink to fit it, and the name is cut short to fit what's left.
            let status = info.statuses[person.identity].map { $0 == "retired" ? "retired identity" : $0 }
            let facts = [person.isYou ? "you" : nil, person.role.isEmpty ? nil : person.role,
                         person.isHere ? "here now" : "not here", status].compactMap { $0 }.joined(separator: " · ")
            let factsRoom = max(right - roleX, right - nameX - width(person.label, size) - size)
            let factsSize = min(size * 0.8, size * 0.8 * factsRoom / max(0.01, width(facts, size * 0.8)))
            let factsWidth = width(facts, factsSize)
            drawPerson(person, &g, base: base, x: left, y: detailsY, size: size, sunk: sunk, now: now, theme: theme,
                       fade: visible(detailsY), maxWidth: right - factsWidth - nameX - size, bright: true, dark: !person.isHere)
            text(facts, right - factsWidth, detailsY, factsSize, theme.accent, 0.9)
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
            // The name stops short of the role column, leaving room for "you" after yours.
            let youWidth = person.isYou ? width("you", size * 0.75) + size * 0.5 : 0
            let nameRoom = roleX - nameX - size * 0.6 - youWidth
            drawPerson(person, &g, base: base, x: left, y: y, size: size, sunk: sunk, now: now, theme: theme, fade: visible(y),
                       maxWidth: nameRoom, bright: isSelected, dark: !person.isHere)
            if person.isYou {
                text("you", nameX + min(width(person.label, size), nameRoom) + size * 0.4, y, size * 0.75, theme.primary, 0.5)
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

    /// The text height at which `s` fits in `room`, no bigger than `height`.
    private func fitted(_ s: String, _ height: Float, _ room: Float) -> Float {
        let w = FrameGeometry.textWidth(s, atlas: atlas, height: height)
        return w > room ? height * room / w : height
    }

    /// `s` broken into lines no wider than `width`, at word boundaries (a word too long
    /// for a line is cut), at most `limit` lines with the last ending "…" if it runs over.
    private func wrapped(_ s: String, height: Float, width: Float, limit: Int = 3) -> [String] {
        func w(_ t: String) -> Float { FrameGeometry.textWidth(t, atlas: atlas, height: height) }
        var lines: [String] = [], line = ""
        for word in s.split(separator: " ") {
            let candidate = line.isEmpty ? String(word) : line + " " + word
            if w(candidate) <= width || line.isEmpty {
                line = w(candidate) <= width ? candidate : cut(candidate, height, width)
            } else {
                lines.append(line)
                line = w(String(word)) <= width ? String(word) : cut(String(word), height, width)
            }
        }
        if !line.isEmpty { lines.append(line) }
        if lines.count > limit {
            lines = Array(lines.prefix(limit))
            lines[limit - 1] = cut(lines[limit - 1] + " …", height, width)
        }
        return lines
    }

    /// `s`, cut short with "…" to fit in `room`.
    private func cut(_ s: String, _ height: Float, _ room: Float) -> String {
        guard FrameGeometry.textWidth(s, atlas: atlas, height: height) > room else { return s }
        var t = s
        while !t.isEmpty, FrameGeometry.textWidth(t + "…", atlas: atlas, height: height) > room { t.removeLast() }
        return t + "…"
    }

    /// "in #a · #b · #c", or as many as fit then "… +N more".
    private func roomList(_ rooms: [String], height: Float, room: Float) -> String {
        let all = "in " + rooms.joined(separator: " · ")
        guard FrameGeometry.textWidth(all, atlas: atlas, height: height) > room else { return all }
        var shown = rooms.count - 1
        while shown > 1 {
            let line = "in " + rooms.prefix(shown).joined(separator: " · ") + " · … +\(rooms.count - shown) more"
            if FrameGeometry.textWidth(line, atlas: atlas, height: height) <= room { return line }
            shown -= 1
        }
        return "in " + rooms[0] + " · … +\(rooms.count - 1) more"
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
        // One mark goes right after the name, drawn by us: an admin's shield, else a
        // contact's star (room for it is taken from the name, which is cut short first).
        let icon = Icon.mark(admin: person.isAdmin, contact: person.isContact)
        let markW = icon != nil ? size * 1.1 : 0
        let label = cut(person.label, size, maxWidth - markW)
        g.text(label, atlas: atlas, origin: base + SIMD3(x + size * 1.2, y - sunk, 0), right: [1, 0, 0], up: [0, 1, 0],
               height: size, color: dark && !bright ? simd_mix(color, theme.primary, SIMD3(repeating: 0.6)) : color,
               intensity: (bright ? 1.6 : dark ? 0.4 : 1.1) * fade)
        if let icon {
            let at = x + size * 1.2 + FrameGeometry.textWidth(label, atlas: atlas, height: size) + size * 0.6
            icon.draw(into: &g, at: base + SIMD3(at, y - sunk + size * 0.36, 0), size: size * 0.38, right: [1, 0, 0],
                      up: [0, 1, 0], color: color, intensity: (dark ? 0.7 : 1.3) * fade)
        }
    }
}

// MARK: - contacts

extension RoomInfoScene {
    /// The contacts wall (⌘K): your saved people, not the room's, standing alone where the
    /// room info stands. Those visible somewhere now come first, with a bright glyph and
    /// the rooms they're in (yours, and listed rooms); the rest have a dark glyph and when
    /// you last saw them. ↑↓ pick someone for the details strip at the bottom.
    /// The picked contact's own wall: who they are, and every room they're in.
    struct Card {
        var row: ChatController.ContactRow
        var added: Date
        var status: String?
        var places: [ChatController.Place]
    }

    /// Two walls: your contacts, and beside it the picked contact's own wall (→).
    func buildContacts(into g: inout FrameGeometry, rows: [ChatController.ContactRow], card: Card?, progress: Float,
                       focus: Float, page: Int, selected: String?, selectedPlace: String?, statuses: [String: String],
                       first: inout Int, placesFirst: inout Int, theme: Theme) {
        let gain = g.gain
        defer { g.gain = gain }
        for i in 0...1 {
            let risen = HelpScene.rise(i, progress: progress, focus: focus)
            guard risen > 0.001 else { continue }
            g.gain = gain * max(0.35, 1 - abs(Float(i) - focus) * 0.65)
            if i == 0 {
                drawContactList(into: &g, rows: rows, risen: risen, isPage: page == 0, selected: selected, statuses: statuses,
                                first: &first, theme: theme)
            } else {
                drawCard(into: &g, card: card, risen: risen, isPage: page == 1, selectedPlace: selectedPlace,
                         first: &placesFirst, theme: theme)
            }
        }
    }

    private func drawContactList(into g: inout FrameGeometry, rows: [ChatController.ContactRow], risen: Float, isPage: Bool,
                                 selected: String?, statuses: [String: String], first: inout Int, theme: Theme) {
        let base = Self.base(0)
        drawFrame(into: &g, base: base, risen: risen, label: "CONTACTS", selected: isPage, theme: theme,
                  hint: "↑↓ pick  ·  → their rooms  ·  ⏎ rename  ·  ⌘⌫ remove  ·  esc")

        let w = HelpScene.wallWidth / 2, h = HelpScene.wallHeight
        let sunk = (1 - risen) * h
        let now = AppClock.now
        let pad: Float = 0.65, size: Float = 0.34, lineH = size * 1.5, headingH = size * 0.7
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
        let left = -w + pad, right = w - pad
        let nameX = left + size * 1.3, whereX = left + 4.2, seenX = left + 8.25

        var y = h - pad - size * 1.5
        text("CONTACTS", left, y, size * 1.5, theme.accent, 1.5)
        let note = "saved on this Mac only"
        text(note, right - width(note, size * 0.7), y, size * 0.7, theme.primary, 0.45)

        // The details strip, fixed at the bottom: who and when, every room they're in, and
        // their fingerprint.
        let stripTop = pad + lineH * 2.75
        g.line(base + SIMD3(left, stripTop - sunk, 0), base + SIMD3(right, stripTop - sunk, 0), theme.primary,
               intensity: visible(stripTop) == nil ? 0 : 0.35, width: 1)
        let detailsY = stripTop - lineH * 0.95, roomsY = detailsY - lineH * 0.8, fingerprintY = roomsY - lineH * 0.75
        if let row = rows.first(where: { $0.identity == selected }) {
            let status = statuses[row.identity].map { $0 == "retired" ? "retired identity" : $0 }
            let seen = row.whereNow.isEmpty
                ? row.lastSeen.map { "last seen \($0)" + (row.lastSeenRoom.map { " in \($0)" } ?? "") } ?? "not seen yet"
                : "here now"
            let facts = [seen, status].compactMap { $0 }.joined(separator: " · ")
            let factsSize = fitted(facts, size * 0.8, right - whereX)
            let factsWidth = width(facts, factsSize)
            drawPerson(RoomInfo.Person(identity: row.identity, label: row.label, isAdmin: row.isAdmin, isContact: true), &g, base: base, x: left, y: detailsY, size: size,
                       sunk: sunk, now: now, theme: theme, fade: visible(detailsY), maxWidth: right - factsWidth - nameX - size,
                       bright: true, dark: row.whereNow.isEmpty)
            text(facts, right - factsWidth, detailsY, factsSize, theme.accent, 0.9)
            // Every room they're in, as far as we can see: shrinking to fit, and past that as
            // many as fit and how many more.
            let roomsSize = max(size * 0.62, fitted("in " + row.whereNow.joined(separator: " · "), size * 0.8, right - nameX))
            let roomsLine = row.whereNow.isEmpty ? "not in any room you can see"
                : roomList(row.whereNow, height: roomsSize, room: right - nameX)
            text(roomsLine, nameX, roomsY, roomsSize, theme.primary, row.whereNow.isEmpty ? 0.45 : 0.85)
            let small = size * 0.62
            text(row.identity, nameX, fingerprintY, small, theme.accent, 0.9)
            text("⌘C copies", right - width("⌘C copies", small), fingerprintY, small, theme.primary, 0.6)
        } else if rows.isEmpty {
            text("save someone from a room's people wall (⌘I, →, ↑↓, ⏎)", nameX, detailsY, size * 0.8, theme.primary, 0.5)
        } else {
            text("↑↓ pick someone to see their fingerprint", nameX, detailsY, size * 0.8, theme.primary, 0.45)
        }

        // Rows, scrolling only when the selection reaches an edge.
        let listTop = y - lineH * 1.5
        let firstRow = listTop - lineH * 1.05
        let listBottom = stripTop + lineH * 0.55
        let capacity = max(1, Int((firstRow - listBottom) / lineH) + 1)
        if let i = rows.firstIndex(where: { $0.identity == selected }) {
            if i < first { first = i }
            if i >= first + capacity { first = i - capacity + 1 }
        }
        first = max(0, min(first, rows.count - capacity))
        let shown = rows.dropFirst(first).prefix(capacity)

        text("NAME", nameX, listTop, headingH, theme.primary, 0.5)
        text("WHERE NOW", whereX, listTop, headingH, theme.primary, 0.5)
        text("LAST SEEN", seenX, listTop, headingH, theme.primary, 0.5)
        if first > 0 { text("↑ \(first) more", nameX + width("NAME", headingH) + size, listTop, headingH, theme.primary, 0.55) }
        if rows.isEmpty { text("nobody yet", nameX, firstRow, size * 0.9, theme.primary, 0.45) }

        y = firstRow
        for row in shown {
            let isSelected = row.identity == selected
            let away = row.whereNow.isEmpty
            if isSelected { text("▸", left - size * 0.9, y, size, theme.accent, 1.5) }
            drawPerson(RoomInfo.Person(identity: row.identity, label: row.label, isAdmin: row.isAdmin, isContact: true), &g, base: base, x: left, y: y, size: size,
                       sunk: sunk, now: now, theme: theme, fade: visible(y), maxWidth: whereX - nameX - size * 0.6,
                       bright: isSelected, dark: away)
            let detail = isSelected ? theme.accent : theme.primary
            // The first room, and how many more (all of them are in the strip when picked).
            let more = row.whereNow.count > 1 ? " +\(row.whereNow.count - 1)" : ""
            let rooms = away ? "—" : cut(row.whereNow[0], size * 0.85, seenX - whereX - size * 0.6 - width(more, size * 0.85)) + more
            text(rooms, whereX, y, size * 0.85, detail, away ? 0.5 : 0.9)
            text(row.lastSeen ?? "—", seenX, y, size * 0.85, detail, away ? 0.6 : 0.9)
            y -= lineH
        }
        let rest = rows.count - first - shown.count
        if rest > 0 { text("↓ \(rest) more", right - width("↓ \(rest) more", headingH), y + lineH * 0.2, headingH, theme.primary, 0.55) }
    }

    /// A contact's own wall: their name, petname, since when, status and fingerprint, then
    /// every room they're in that we can see, with ⏎ to go there.
    private func drawCard(into g: inout FrameGeometry, card: Card?, risen: Float, isPage: Bool, selectedPlace: String?,
                          first: inout Int, theme: Theme) {
        let base = Self.base(1)
        let w = HelpScene.wallWidth / 2, h = HelpScene.wallHeight
        let sunk = (1 - risen) * h
        let now = AppClock.now
        let pad: Float = 0.65, size: Float = 0.34, lineH = size * 1.5, headingH = size * 0.7
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
        let left = -w + pad, right = w - pad

        guard let card else {
            drawFrame(into: &g, base: base, risen: risen, label: "THEIR ROOMS", selected: isPage, theme: theme, hint: "← contacts  ·  esc")
            text("pick a contact (↑↓) to see them here", left, h / 2, size * 0.8, theme.primary, 0.45)
            return
        }
        let name = card.row.label
        drawFrame(into: &g, base: base, risen: risen, label: cut(name.uppercased(), 1.0, HelpScene.wallWidth + 2), selected: isPage,
                  theme: theme, hint: "↑↓ pick a room  ·  ⏎ go there  ·  ← contacts  ·  esc")

        // Who: their glyph and name, then the facts, then the whole fingerprint.
        var y = h - pad - size * 1.5
        let big = size * 1.5
        drawPerson(RoomInfo.Person(identity: card.row.identity, label: card.row.label, isAdmin: card.row.isAdmin, isContact: true), &g, base: base, x: left, y: y, size: big,
                   sunk: sunk, now: now, theme: theme, fade: visible(y), maxWidth: right - left - big * 1.3, bright: true,
                   dark: card.row.whereNow.isEmpty)
        y -= lineH * 1.05
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("d MMM yyyy")
        var facts = [card.row.petname.map { "you call them \($0)" }, "a contact since \(f.string(from: card.added))",
                     card.status.map { $0 == "retired" ? "retired identity" : "\($0) identity" }].compactMap { $0 }
        if card.places.isEmpty {
            facts.append(card.row.lastSeen.map { "last seen \($0)" + (card.row.lastSeenRoom.map { " in \($0)" } ?? "") } ?? "not seen yet")
        }
        let factsLine = facts.joined(separator: " · ")
        text(factsLine, left, y, fitted(factsLine, size * 0.75, right - left), theme.primary, 0.7)
        y -= lineH * 0.8
        let small = size * 0.62
        text(card.row.identity, left, y, small, theme.accent, 0.85)
        text("⌘C copies", right - width("⌘C copies", small), y, small, theme.primary, 0.55)
        y -= lineH * 0.75
        if visible(y) != nil {
            g.line(base + SIMD3(left, y - sunk, 0), base + SIMD3(right, y - sunk, 0), theme.primary, intensity: 0.35, width: 1)
        }

        // Their rooms, scrolling only when the selection reaches an edge.
        let placeX = left + size * 1.3, kindX = left + 4.6, peopleX = left + 6.7, spokeX = left + 7.9
        let listTop = y - lineH * 0.95
        text("ROOMS · \(card.places.count)", placeX, listTop, headingH, theme.primary, 0.6)
        if card.places.isEmpty {
            text("not in any room you can see", placeX, listTop - lineH * 1.05, size * 0.85, theme.primary, 0.45)
            return
        }
        text("PEOPLE", peopleX, listTop, headingH, theme.primary, 0.5)
        text("THEY SPOKE", spokeX, listTop, headingH, theme.primary, 0.5)
        let firstRow = listTop - lineH * 1.05
        let bottom = pad + size * 0.3
        let capacity = max(1, Int((firstRow - bottom) / lineH) + 1)
        if let i = card.places.firstIndex(where: { $0.id == selectedPlace }) {
            if i < first { first = i }
            if i >= first + capacity { first = i - capacity + 1 }
        }
        first = max(0, min(first, card.places.count - capacity))
        let shown = card.places.dropFirst(first).prefix(capacity)
        if first > 0 { text("↑ \(first) more", right - width("↑ \(first) more", headingH), listTop + lineH * 0.55, headingH, theme.primary, 0.55) }

        y = firstRow
        for place in shown {
            let isSelected = place.id == selectedPlace
            let color = isSelected ? theme.accent : theme.primary
            if isSelected { text("▸", left + size * 0.2, y, size, theme.accent, 1.5) }
            text(cut("#" + place.name, size, kindX - placeX - size * 0.5), placeX, y, size, color, isSelected ? 1.5 : place.yours ? 1.15 : 0.85)
            var kind = place.yours ? "your room" : "listed"
            if place.access == "key" { kind += " · key" } else if place.access == "invite" { kind += " · invite" }
            text(kind, kindX, y, size * 0.75, color, place.yours ? 0.75 : 0.55)
            text("\(place.people)", peopleX, y, size * 0.85, color, 0.8)
            text(place.lastSpoke ?? "—", spokeX, y, size * 0.85, color, place.lastSpoke == nil ? 0.45 : 0.8)
            y -= lineH
        }
        let rest = card.places.count - first - shown.count
        if rest > 0 { text("↓ \(rest) more", right - width("↓ \(rest) more", headingH), y + lineH * 0.25, headingH, theme.primary, 0.55) }
    }
}

// MARK: - identities

extension RoomInfoScene {
    /// The identities wall (⇧⌘I, /identity): yours, on this Mac. The one in use is marked;
    /// ↑↓ pick, ⏎ uses it, and the details strip shows its fingerprint and file. At launch
    /// (more than one, no default) it asks which to start with.
    func buildIdentities(into g: inout FrameGeometry, rows: [ChatController.IdentityRow], progress: Float, selected: String?,
                         atLaunch: Bool, pinned: Bool, first: inout Int, theme: Theme) {
        let risen = HelpScene.rise(0, progress: progress, focus: 0)
        guard risen > 0.001 else { return }
        let base = Self.base(0)
        drawFrame(into: &g, base: base, risen: risen, label: atLaunch ? "WHICH IDENTITY?" : "IDENTITIES", selected: true, theme: theme,
                  hint: atLaunch ? "↑↓ pick  ·  ⏎ start as it" : "↑↓ pick  ·  ⏎ use it  ·  /identity for more  ·  esc")

        let w = HelpScene.wallWidth / 2, h = HelpScene.wallHeight
        let sunk = (1 - risen) * h
        let now = AppClock.now
        let pad: Float = 0.65, size: Float = 0.34, lineH = size * 1.5, headingH = size * 0.7
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
        let left = -w + pad, right = w - pad
        let nameX = left + size * 1.3, notesX = left + 4.4, usedX = left + 8.25

        var y = h - pad - size * 1.5
        text(atLaunch ? "START AS" : "YOUR IDENTITIES", left, y, size * 1.5, theme.accent, 1.5)
        let note = pinned ? "pinned by PHOSPHOR_IDENTITY" : "on this Mac · each file IS that identity"
        text(note, right - width(note, size * 0.7), y, size * 0.7, theme.primary, 0.45)

        // The details strip: the picked identity's fingerprint and file, and what you can do.
        let stripTop = pad + lineH * 2.75
        g.line(base + SIMD3(left, stripTop - sunk, 0), base + SIMD3(right, stripTop - sunk, 0), theme.primary,
               intensity: visible(stripTop) == nil ? 0 : 0.35, width: 1)
        let detailsY = stripTop - lineH * 0.95, fileY = detailsY - lineH * 0.8, actionsY = fileY - lineH * 0.75
        let small = size * 0.62
        if let row = rows.first(where: { $0.path == selected }) {
            text(row.fingerprint, left, detailsY, small, theme.accent, 0.9)
            text("⌘C copies", right - width("⌘C copies", small), detailsY, small, theme.primary, 0.6)
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            let path = row.path.hasPrefix(home) ? "~" + row.path.dropFirst(home.count) : row.path
            text(cut(path, small, right - left), left, fileY, small, theme.primary, 0.55)
        }
        let actions = pinned ? "this Phosphor uses only this identity"
            : "/identity new · import · export · rename · remove · default"
        text(cut(actions, small, right - left), left, actionsY, small, theme.primary, 0.6)

        // Rows.
        let listTop = y - lineH * 1.5
        let firstRow = listTop - lineH * 1.05
        let listBottom = stripTop + lineH * 0.55
        let capacity = max(1, Int((firstRow - listBottom) / lineH) + 1)
        if let i = rows.firstIndex(where: { $0.path == selected }) {
            if i < first { first = i }
            if i >= first + capacity { first = i - capacity + 1 }
        }
        first = max(0, min(first, rows.count - capacity))
        text("NAME", nameX, listTop, headingH, theme.primary, 0.5)
        text("LAST USED", usedX, listTop, headingH, theme.primary, 0.5)
        if first > 0 { text("↑ \(first) more", nameX + width("NAME", headingH) + size, listTop, headingH, theme.primary, 0.55) }
        if rows.isEmpty { text("none yet: /identity new name", nameX, firstRow, size * 0.9, theme.primary, 0.45) }

        y = firstRow
        let shown = rows.dropFirst(first).prefix(capacity)
        for row in shown {
            let isSelected = row.path == selected
            if isSelected { text("▸", left - size * 0.9, y, size, theme.accent, 1.5) }
            drawPerson(RoomInfo.Person(identity: row.fingerprint, label: row.label), &g, base: base, x: left, y: y, size: size,
                       sunk: sunk, now: now, theme: theme, fade: visible(y), maxWidth: notesX - nameX - size * 0.6,
                       bright: isSelected || row.inUse, dark: false)
            let detail = isSelected ? theme.accent : theme.primary
            let notes = row.notes.joined(separator: " · ")
            text(cut(notes, size * 0.8, usedX - notesX - size * 0.6), notesX, y, size * 0.8, detail, row.inUse ? 1.1 : 0.7)
            text(row.lastUsed ?? "—", usedX, y, size * 0.85, detail, 0.7)
            y -= lineH
        }
        let rest = rows.count - first - shown.count
        if rest > 0 { text("↓ \(rest) more", right - width("↓ \(rest) more", headingH), y + lineH * 0.2, headingH, theme.primary, 0.55) }
    }
}
