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
        text("\(room)  ·  \(here)  ·  \(link)", mx, y, 15, theme.primary, 1.1)
        y -= 20 * scale
        let myLabel = state?.labels[controller.me] ?? controller.displayName
        if let topic = state?.room.topic, !topic.isEmpty {
            text(SafeText.clean(topic).replacingOccurrences(of: "\n", with: " "), mx, y, 12, theme.primary, 0.75)
            y -= 16 * scale
        }
        text("you: \(SafeText.clean(myLabel))   /help for commands", mx, y, 12, theme.primary, 0.6)

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

        // Input box, bottom.
        let boxH: Float = 34 * scale
        let x0 = mx, x1 = viewport.x - mx, y0 = my, y1 = my + boxH
        g.polyline([SIMD3(x0, y0, 0), SIMD3(x1, y0, 0), SIMD3(x1, y1, 0), SIMD3(x0, y1, 0), SIMD3(x0, y0, 0)],
                   theme.primary, intensity: 0.9, width: 1.4)
        let prompt = "\(room) › "
        let textX = x0 + 12 * scale
        let baseline = y0 + 11 * scale
        text(prompt, textX, baseline, 16, theme.primary, 0.7)

        // Committed text with the IME composition spliced in at the caret, scrolled to keep
        // the caret visible.
        let before = input.textBeforeCaret, after = input.textAfterCaret
        let available = x1 - 12 * scale - (textX + width(prompt, 16))
        var shownBefore = before
        while width(shownBefore + input.marked, 16) > available * 0.9, !shownBefore.isEmpty { shownBefore.removeFirst() }
        let startX = textX + width(prompt, 16)
        text(shownBefore, startX, baseline, 16, theme.primary, 1.2)
        let markedX = startX + width(shownBefore, 16)
        if !input.marked.isEmpty {
            text(input.marked, markedX, baseline, 16, theme.accent, 1.2)
            g.line(SIMD3(markedX, baseline - 3 * scale, 0), SIMD3(markedX + width(input.marked, 16), baseline - 3 * scale, 0),
                   theme.accent, intensity: 1.2, width: 1.2)
        }
        let caretX = markedX + width(input.marked, 16)
        text(after, caretX, baseline, 16, theme.primary, 1.2)
        if Int(now * 2) % 2 == 0 {
            g.line(SIMD3(caretX + 1 * scale, baseline - 3 * scale, 0), SIMD3(caretX + 1 * scale, baseline + 15 * scale, 0),
                   theme.accent, intensity: 1.8, width: 2)
        }

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
}
