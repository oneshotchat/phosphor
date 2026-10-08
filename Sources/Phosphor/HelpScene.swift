import simd

/// Help in the world (⌘/ or /help): one wall per topic, standing on the floor in a row
/// between you and the room, like the overview's unjoined rooms. They rise out of the
/// floor as help opens (the one you asked for first) and sink back when it closes; the
/// camera flies to the wall you're on, and ←→ fly along the row.
@MainActor
struct HelpScene {
    let atlas: GlyphAtlas

    static let wallWidth: Float = 11
    static let wallHeight: Float = 7.6
    static let pitch: Float = 13
    static let rowZ: Float = 12

    /// Where wall `i` stands: the middle of its base.
    static func base(_ i: Int) -> SIMD3<Float> {
        SIMD3((Float(i) - Float(Help.Topic.allCases.count - 1) / 2) * pitch, 0, rowZ)
    }

    /// The camera for wall `i`: square on, a little above, far enough back for it all.
    static func view(_ i: Float) -> (eye: SIMD3<Float>, target: SIMD3<Float>) {
        let x = (i - Float(Help.Topic.allCases.count - 1) / 2) * pitch
        return (SIMD3(x, 5.4, rowZ + 14.5), SIMD3(x, 3.2, rowZ))
    }

    /// How far wall `i` has risen, 0…1, when help is `progress` open and `focus` is the
    /// wall being looked at: that one first, its neighbours a moment later.
    static func rise(_ i: Int, progress: Float, focus: Float) -> Float {
        smoothstep(0, 1, simd_clamp(progress * 1.4 - 0.13 * abs(Float(i) - focus), 0, 1))
    }

    func build(into g: inout FrameGeometry, progress: Float, focus: Float, selected: Int, isOperator: Bool, theme: Theme) {
        guard progress > 0.001 else { return }
        for (i, topic) in Help.Topic.allCases.enumerated() {
            let p = Self.rise(i, progress: progress, focus: focus)
            guard p > 0.001 else { continue }
            let near = max(0.35, 1 - abs(Float(i) - focus) * 0.65)
            drawWall(topic, into: &g, base: Self.base(i), risen: p, alpha: near,
                     isSelected: i == selected, isOperator: isOperator, theme: theme)
        }
    }

    private func drawWall(_ topic: Help.Topic, into g: inout FrameGeometry, base: SIMD3<Float>, risen: Float, alpha: Float,
                          isSelected: Bool, isOperator: Bool, theme: Theme) {
        let w = Self.wallWidth / 2, h = Self.wallHeight
        // The wall rises out of the floor: everything is drawn `sunk` lower, and nothing
        // below the floor is drawn.
        let sunk = (1 - risen) * h
        func at(_ x: Float, _ y: Float) -> SIMD3<Float> { base + SIMD3(x, y - sunk, 0) }
        let color = isSelected ? theme.accent : theme.primary

        // The slot in the floor glows from the start; the frame shows only above it.
        g.line(base - SIMD3(w, 0, 0), base + SIMD3(w, 0, 0), color, intensity: (isSelected ? 1.8 : 1.1) * alpha, width: 2)
        let top = h - sunk
        if top > 0.02 {
            for x in [-w, w] { g.line(base + SIMD3(x, 0, 0), base + SIMD3(x, top, 0), theme.primary, intensity: 0.7 * alpha, width: 1.3) }
            g.line(base + SIMD3(-w, top, 0), base + SIMD3(w, top, 0), theme.primary, intensity: 0.7 * alpha, width: 1.3)
        }

        // The topic's name on the floor in front, as the unjoined rooms have theirs.
        let labelSize: Float = isSelected ? 1.15 : 0.95
        let labelWidth = FrameGeometry.textWidth(topic.title, atlas: atlas, height: labelSize)
        g.text(topic.title, atlas: atlas, origin: base + SIMD3(-labelWidth / 2, 0.03, 1.1 + labelSize), right: [1, 0, 0],
               up: [0, 0, -1], height: labelSize, color: color, intensity: (isSelected ? 1.6 : 0.8) * alpha * max(0.3, risen))
        if isSelected {
            let hint = "←→ more help  ·  esc closes"
            let hintSize: Float = 0.5
            let hw = FrameGeometry.textWidth(hint, atlas: atlas, height: hintSize)
            g.text(hint, atlas: atlas, origin: base + SIMD3(-hw / 2, 0.03, 2.1 + labelSize + hintSize), right: [1, 0, 0],
                   up: [0, 0, -1], height: hintSize, color: theme.primary, intensity: 0.7 * risen)
        }

        let rows: [(String, String)] = topic == .keys ? Help.keys.map { ($0.keys, $0.action) }
            : Help.commands.filter { $0.topic == topic }.map { ($0.usage, $0.summary) }

        // Size the text to fit the wall: by line count, then by the widest row.
        let pad: Float = 0.65
        let lines = Float(rows.count) + 2.2
        var size = min(0.42, (h - pad * 2) / lines / 1.45)
        func width(_ s: String, _ height: Float) -> Float { FrameGeometry.textWidth(s, atlas: atlas, height: height) }
        func columns(_ size: Float) -> (Float, Float) {
            ((rows.map { width($0.0, size) }.max() ?? 0) + 1.2 * size,
             rows.map { width($0.1, size * 0.9) }.max() ?? 0)
        }
        var (keyWidth, summaryWidth) = columns(size)
        if keyWidth + summaryWidth > Self.wallWidth - pad * 2 {
            size *= (Self.wallWidth - pad * 2) / (keyWidth + summaryWidth)
            (keyWidth, summaryWidth) = columns(size)
        }
        let lineH = size * 1.45

        // Text fades in as it clears the floor.
        func text(_ s: String, _ x: Float, _ y: Float, _ height: Float, _ c: SIMD3<Float>, _ intensity: Float) {
            let above = y - sunk
            guard above > 0.05 else { return }
            g.text(s, atlas: atlas, origin: at(x, y), right: [1, 0, 0], up: [0, 1, 0], height: height, color: c,
                   intensity: intensity * alpha * min(1, above / 0.8))
        }
        var y = h - pad - size * 1.3
        text(topic.title, -w + pad, y, size * 1.3, theme.accent, 1.4)
        if topic == .mod && !isOperator {
            text("  (you're not an operator here)", -w + pad + width(topic.title, size * 1.3), y, size * 0.85, theme.accent, 0.9)
        }
        y -= lineH * 1.8
        for (left, right) in rows {
            text(left, -w + pad, y, size, theme.primary, 1.2)
            text(right, -w + pad + keyWidth, y, size * 0.9, theme.primary, 0.65)
            y -= lineH
        }
    }
}
