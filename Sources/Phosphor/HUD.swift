import OSCCore
import simd

/// The input line and status, drawn in screen pixels but through the same glow and CRT
/// passes as the world so it reads as part of the same tube.
@MainActor
struct HUD {
    let atlas: GlyphAtlas

    func build(into g: inout FrameGeometry, viewport: SIMD2<Float>, scale: Float, controller: ChatController,
               input: InputLine, theme: Theme, hint: String?) {
        let now = AppClock.now
        let right = SIMD3<Float>(1, 0, 0), up = SIMD3<Float>(0, 1, 0)
        // Stay clear of the tube's curved edges.
        let mx = viewport.x * 0.06, my = viewport.y * 0.07
        func text(_ s: String, _ x: Float, _ y: Float, _ size: Float, _ color: SIMD3<Float>, _ intensity: Float = 1) {
            g.text(s, atlas: atlas, origin: SIMD3(x, y, 0), right: right, up: up, height: size * scale,
                   color: color, intensity: intensity)
        }
        func width(_ s: String, _ size: Float) -> Float { FrameGeometry.textWidth(s, atlas: atlas, height: size * scale) }

        // Status, top left.
        var y = viewport.y - my - 16 * scale
        let state = controller.state
        let room = state.map { "#" + SafeText.clean($0.room.name) } ?? "no room"
        let here = state.map { "\($0.occupants.count) here" } ?? ""
        let link = switch controller.connection {
        case .connected: "live"
        case .connecting: "connecting…"
        case .disconnected: "reconnecting…"
        case .unavailable: "polling"
        }
        text([room, here, link].filter { !$0.isEmpty }.joined(separator: "  ·  "), mx, y, 15, theme.primary, 1.1)
        y -= 20 * scale
        let myLabel = state?.labels[controller.me] ?? controller.displayName
        if let topic = state?.room.topic, !topic.isEmpty {
            text(SafeText.clean(topic).replacingOccurrences(of: "\n", with: " "), mx, y, 12, theme.primary, 0.75)
            y -= 16 * scale
        }
        text("you: \(SafeText.clean(myLabel)) · \(controller.signByDefault ? "signing" : "unsigned")   /help for commands",
             mx, y, 12, theme.primary, 0.6)

        // Joined rooms, top right: ⌘ number, name, unread count, and @ if you were mentioned.
        var items: [(String, SIMD3<Float>, Float)] = []
        for (i, room) in controller.rooms.enumerated() {
            let name = controller.state(room).map { "#" + SafeText.clean($0.room.name) } ?? "…"
            let activity = controller.activity[room] ?? ChatController.Activity()
            let active = room == controller.activeRoom
            var item = "\(i + 1) \(name)"
            if activity.unread > 0 { item += " •\(activity.unread)" }
            if activity.mentioned { item += " @" }
            items.append((active ? "[\(item)]" : item, active || activity.mentioned ? theme.accent : theme.primary,
                          active ? 1.3 : activity.unread > 0 ? 1 : 0.55))
        }
        let spacing = 16 * scale
        var rx = viewport.x - mx - items.reduce(0) { $0 + width($1.0, 13) + spacing } + spacing
        for (item, color, intensity) in items {
            text(item, rx, viewport.y - my - 16 * scale, 13, color, intensity)
            rx += width(item, 13) + spacing
        }

        // Notices fade after a while. Server notices get their own color: only they come from the server.
        for notice in controller.notices.reversed() {
            let age = now - notice.at
            guard age < 12 else { continue }
            y -= 18 * scale
            let color: SIMD3<Float> = switch notice.kind {
            case .error, .mention: theme.accent
            case .server: SIMD3(1, 1, 1)
            case .info: theme.primary
            }
            text(notice.text, mx, y, 12, color, (notice.kind == .info ? 0.7 : 1.1) * (1 - smoothstep(9, 12, age)))
        }

        // Input box, bottom; it grows upward for multi-line messages (⇧⏎).
        let prompt = controller.browser.isOpen ? controller.browser.inputPrompt : "\(room) › "
        let textX = mx + 12 * scale
        let startX = textX + width(prompt, 16)
        let available = viewport.x - mx - 12 * scale - startX

        // The line with the caret holds the IME composition; the others are plain.
        var above = input.textBeforeCaret.components(separatedBy: "\n")
        var below = input.textAfterCaret.components(separatedBy: "\n")
        let caretBefore = above.removeLast(), caretAfter = below.removeFirst()
        let maxLines = 8
        let shownAbove = Array(above.suffix(max(0, maxLines - 1 - min(below.count, 2))))
        let shownBelow = Array(below.prefix(maxLines - 1 - shownAbove.count))
        let lineCount = shownAbove.count + 1 + shownBelow.count
        let lineH: Float = 22 * scale
        let boxH: Float = 34 * scale + Float(lineCount - 1) * lineH
        let x0 = mx, x1 = viewport.x - mx, y0 = my, y1 = my + boxH
        g.polyline([SIMD3(x0, y0, 0), SIMD3(x1, y0, 0), SIMD3(x1, y1, 0), SIMD3(x0, y1, 0), SIMD3(x0, y0, 0)],
                   theme.primary, intensity: 0.9, width: 1.4)
        var baseline = y0 + 11 * scale + Float(lineCount - 1) * lineH
        text(prompt, textX, baseline, 16, theme.primary, 0.7)
        if above.count > shownAbove.count { text("…", textX, baseline, 16, theme.primary, 0.6) }

        func plainLine(_ line: String) {
            var shown = line
            if width(shown, 16) > available {
                while width(shown + "…", 16) > available, !shown.isEmpty { shown.removeLast() }
                shown += "…"
            }
            text(shown, startX, baseline, 16, theme.primary, 1.2)
            baseline -= lineH
        }
        for line in shownAbove { plainLine(line) }

        // Caret line: scrolled so the caret stays visible.
        var shownBefore = caretBefore
        while width(shownBefore + input.marked, 16) > available * 0.9, !shownBefore.isEmpty { shownBefore.removeFirst() }
        text(shownBefore, startX, baseline, 16, theme.primary, 1.2)
        let markedX = startX + width(shownBefore, 16)
        if !input.marked.isEmpty {
            text(input.marked, markedX, baseline, 16, theme.accent, 1.2)
            g.line(SIMD3(markedX, baseline - 3 * scale, 0), SIMD3(markedX + width(input.marked, 16), baseline - 3 * scale, 0),
                   theme.accent, intensity: 1.2, width: 1.2)
        }
        let caretX = markedX + width(input.marked, 16)
        text(caretAfter, caretX, baseline, 16, theme.primary, 1.2)
        if Int(now * 2) % 2 == 0 {
            g.line(SIMD3(caretX + 1 * scale, baseline - 3 * scale, 0), SIMD3(caretX + 1 * scale, baseline + 15 * scale, 0),
                   theme.accent, intensity: 1.8, width: 2)
        }
        baseline -= lineH
        for line in shownBelow { plainLine(line) }

        // Mention autocomplete, stacked above the box.
        var cy = y1 + 10 * scale
        for (i, label) in input.completions.enumerated() {
            let selected = i == input.completionIndex
            text((selected ? "▸ @" : "  @") + SafeText.clean(label), x0 + 12 * scale, cy, 14,
                 selected ? theme.accent : theme.primary, selected ? 1.3 : 0.7)
            cy += 18 * scale
        }
        if let hint {
            let w = width(hint, 13)
            text(hint, x1 - 12 * scale - w, y1 + 10 * scale, 13, theme.accent, 1.2)
        }
        if input.completions.isEmpty, let focus = controller.focus {
            text("selected [\(focus)]  ·  /react 👍  ·  /edit text  ·  ↑↓ move  ·  esc clear", x0 + 12 * scale, cy, 12, theme.accent, 0.9)
        }
    }

    /// The browser's list, on the right: filtered rooms with who's there, recent activity
    /// and access, the selection highlighted.
    func buildBrowser(into g: inout FrameGeometry, viewport: SIMD2<Float>, scale: Float, browser: RoomBrowser, theme: Theme) {
        let right = SIMD3<Float>(1, 0, 0), up = SIMD3<Float>(0, 1, 0)
        let x = viewport.x * 0.56
        var y = viewport.y * 0.82
        func text(_ s: String, _ size: Float, _ color: SIMD3<Float>, _ intensity: Float) {
            g.text(s, atlas: atlas, origin: SIMD3(x, y, 0), right: right, up: up, height: size * scale, color: color, intensity: intensity)
        }
        text("ROOMS", 15, theme.accent, 1.3)
        y -= 18 * scale
        if case .name = browser.prompt {
            text("pick a name first, then a room", 12, theme.primary, 0.6)
        } else {
            text("type to filter · ↑↓ pick · ⏎ join · esc close", 12, theme.primary, 0.6)
        }
        y -= 26 * scale

        let entries = browser.entries
        if entries.isEmpty { text("no rooms match", 13, theme.primary, 0.6) }
        let window = 14
        let first = max(0, min(browser.selection - window / 2, entries.count - window))
        for (i, entry) in entries.enumerated().dropFirst(first).prefix(window) {
            let selected = i == browser.selection
            var line = selected ? "▸ " : "  "
            switch entry {
            case .listed(let room):
                line += "#" + SafeText.clean(room.name)
                line += "  \(room.occupantCount ?? 0) here"
                if let recent = room.activity?.messagesLast10m, recent > 0 { line += " · \(recent)/10m" }
                if room.access == "key" { line += "  [key]" }
                if room.access == "invite" { line += "  [invite]" }
                let topic = SafeText.clean(room.topic ?? "").replacingOccurrences(of: "\n", with: " ")
                if !topic.isEmpty { line += "  " + (topic.count > 30 ? topic.prefix(29) + "…" : topic) }
            case .byName(let name):
                line += "join #\(name) by name (unlisted, or new)"
            }
            text(line, 13, selected ? theme.accent : theme.primary, selected ? 1.4 : 0.8)
            y -= 19 * scale
        }
        if entries.count > window { text("  … \(entries.count) rooms", 12, theme.primary, 0.5) }
    }
}
