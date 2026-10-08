import simd

/// Help in the world (⌘/ or /help): one wall per topic in a row, like the overview's
/// unjoined rooms. The row is placed in the view as it was when help opened, square to
/// the camera so the text reads as flat as the HUD. Walls rise from below and come in
/// as it opens, the one you're on first; ←→ slide along the row.
@MainActor
struct HelpScene {
    let atlas: GlyphAtlas

    /// The view when help opened: the walls stand `distance` along `forward` from `eye`.
    struct Frame {
        var eye, forward, right, up: SIMD3<Float>
        static let distance: Float = 10
        /// How far the camera backs off while help is open, so the row fits with room around it.
        static let pullBack: Float = 2.5
    }

    static let wallWidth: Float = 11
    static let wallHeight: Float = 7.8
    static let pitch = wallWidth + 1.6

    /// `progress` 0…1 is how far open; `scroll` is the wall index centred (fractional
    /// while sliding); `selected` is the wall being slid to.
    func build(into g: inout FrameGeometry, frame: Frame, progress: Float, scroll: Float, selected: Int,
               isOperator: Bool, theme: Theme) {
        guard progress > 0.001 else { return }
        for (i, topic) in Help.Topic.allCases.enumerated() {
            let away = abs(Float(i) - scroll)
            // The centred wall arrives first; its neighbours follow a moment later.
            let p = smoothstep(0, 1, simd_clamp(progress * 1.35 - 0.12 * away, 0, 1))
            guard p > 0.001 else { continue }
            let center = frame.eye + frame.forward * (Frame.distance + (1 - p) * 6)
                + frame.right * ((Float(i) - scroll) * Self.pitch)
                + frame.up * (-0.2 - (1 - p) * Self.wallHeight * 1.1)
            let focus = max(0.28, 1 - away * 0.75)
            drawWall(topic, into: &g, center: center, frame: frame, alpha: p * focus,
                     isSelected: i == selected, isOperator: isOperator, theme: theme)
        }
    }

    private func drawWall(_ topic: Help.Topic, into g: inout FrameGeometry, center: SIMD3<Float>, frame: Frame,
                          alpha: Float, isSelected: Bool, isOperator: Bool, theme: Theme) {
        let r = frame.right, u = frame.up
        let w = Self.wallWidth / 2, h = Self.wallHeight / 2
        func at(_ x: Float, _ y: Float) -> SIMD3<Float> { center + r * x + u * y }
        let color = isSelected ? theme.accent : theme.primary

        // Outline, with a brighter base line like a room's.
        g.polyline([at(-w, -h), at(w, -h), at(w, h), at(-w, h), at(-w, -h)], theme.primary, intensity: 0.7 * alpha, width: 1.3)
        g.line(at(-w, -h), at(w, -h), color, intensity: 1.6 * alpha, width: 2)

        let rows: [(String, String)] = topic == .keys ? Help.keys.map { ($0.keys, $0.action) }
            : Help.commands.filter { $0.topic == topic }.map { ($0.usage, $0.summary) }

        // Size the text to fit the wall: by line count, then by the widest row.
        let pad: Float = 0.7
        let lines = Float(rows.count) + 3.2            // title, a gap, the rows, the footer
        var size = min(0.42, (Self.wallHeight - pad * 2) / lines / 1.45)
        func width(_ s: String, _ h: Float) -> Float { FrameGeometry.textWidth(s, atlas: atlas, height: h) }
        let gap: Float = 0.5
        func columns(_ size: Float) -> (Float, Float) {
            ((rows.map { width($0.0, size) }.max() ?? 0) + gap * size / 0.42,
             rows.map { width($0.1, size * 0.9) }.max() ?? 0)
        }
        var (keyWidth, summaryWidth) = columns(size)
        if keyWidth + summaryWidth > Self.wallWidth - pad * 2 {
            size *= (Self.wallWidth - pad * 2) / (keyWidth + summaryWidth)
            (keyWidth, summaryWidth) = columns(size)
        }
        let lineH = size * 1.45

        func text(_ s: String, _ x: Float, _ y: Float, _ height: Float, _ c: SIMD3<Float>, _ intensity: Float) {
            g.text(s, atlas: atlas, origin: at(x, y), right: r, up: u, height: height, color: c, intensity: intensity * alpha)
        }
        var y = h - pad - size * 1.3
        let note = topic == .mod && !isOperator ? "  (you're not an operator here)" : ""
        text(topic.title, -w + pad, y, size * 1.3, theme.accent, 1.4)
        if !note.isEmpty { text(note, -w + pad + width(topic.title, size * 1.3), y, size * 0.85, theme.accent, 0.9) }
        y -= lineH * 1.8
        for (left, right) in rows {
            text(left, -w + pad, y, size, theme.primary, 1.2)
            text(right, -w + pad + keyWidth, y, size * 0.9, theme.primary, 0.65)
            y -= lineH
        }
        if isSelected {
            text("←→ more help  ·  type / for suggestions  ·  esc closes", -w + pad, -h + pad * 0.6, size * 0.8, theme.primary, 0.55)
        }
    }
}
