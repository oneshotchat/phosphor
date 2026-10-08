import Foundation
import simd

/// Small line-drawn icons for room settings, drawn like everything else: glowing
/// vectors on a plane. Shapes are in a unit box (-1…1), scaled to `size` (half-width).
enum Icon {
    case eye, eyeHidden              // listed, unlisted
    case padlockOpen, key, envelope  // anyone can join, needs a key, invite only
    case bubble, bubbleVoiced        // anyone can speak, moderated (+ is IRC's voice)
    case hourglass, infinity         // kept for a while, kept forever
    case person, crown               // people here, operators
    case pen, penCrossed             // signing, not signing

    func draw(into g: inout FrameGeometry, at center: SIMD3<Float>, size: Float, right: SIMD3<Float>, up: SIMD3<Float>,
              color: SIMD3<Float>, intensity: Float) {
        func p(_ x: Float, _ y: Float) -> SIMD3<Float> { center + right * (x * size) + up * (y * size) }
        func path(_ points: [(Float, Float)], closed: Bool = false) {
            var pts = points.map { p($0.0, $0.1) }
            if closed, let first = pts.first { pts.append(first) }
            g.polyline(pts, color, intensity: intensity, width: 1.4)
        }
        func arc(_ cx: Float, _ cy: Float, _ rx: Float, _ ry: Float, from a0: Float, to a1: Float, steps: Int = 14) -> [(Float, Float)] {
            (0...steps).map { i in
                let a = a0 + (a1 - a0) * Float(i) / Float(steps)
                return (cx + rx * cos(a), cy + ry * sin(a))
            }
        }
        func slash() { path([(-0.85, -0.85), (0.85, 0.85)]) }

        switch self {
        case .eye, .eyeHidden:
            path(arc(0, -0.75, 1.1, 1.25, from: 0.5, to: .pi - 0.5) + arc(0, 0.75, 1.1, 1.25, from: .pi + 0.5, to: 2 * .pi - 0.5))
            path(arc(0, 0, 0.3, 0.3, from: 0, to: 2 * .pi, steps: 12))
            if self == .eyeHidden { slash() }
        case .padlockOpen:
            path([(-0.7, -0.9), (0.7, -0.9), (0.7, 0.1), (-0.7, 0.1)], closed: true)
            path(arc(-0.1, 0.45, 0.42, 0.45, from: 0, to: .pi) + [(-0.52, 0.3)])     // shackle, lifted open
            path([(0, -0.3), (0, -0.55)])
        case .key:
            path(arc(-0.5, 0, 0.42, 0.42, from: 0, to: 2 * .pi, steps: 14))
            path([(-0.08, 0), (0.95, 0)])
            path([(0.55, 0), (0.55, -0.3)])
            path([(0.85, 0), (0.85, -0.35)])
        case .envelope:
            path([(-0.95, -0.65), (0.95, -0.65), (0.95, 0.65), (-0.95, 0.65)], closed: true)
            path([(-0.95, 0.65), (0, -0.1), (0.95, 0.65)])
        case .bubble, .bubbleVoiced:
            path([(-0.95, -0.35), (-0.95, 0.75), (0.95, 0.75), (0.95, -0.35), (-0.2, -0.35), (-0.6, -0.85), (-0.55, -0.35)],
                 closed: true)
            if self == .bubble {
                for x: Float in [-0.45, 0, 0.45] { path([(x - 0.06, 0.2), (x + 0.06, 0.2)]) }
            } else {
                path([(-0.35, 0.2), (0.35, 0.2)])
                path([(0, -0.12), (0, 0.52)])
            }
        case .hourglass:
            path([(-0.65, 0.9), (0.65, 0.9), (-0.65, -0.9), (0.65, -0.9)], closed: true)
            path([(-0.3, -0.75), (0.3, -0.75)])                                     // sand settling
        case .infinity:
            path((0...28).map { i in
                let t = Float(i) / 28 * 2 * .pi
                let d = 1 + sin(t) * sin(t)
                return (1.05 * cos(t) / d, 1.1 * sin(t) * cos(t) / d)
            })
        case .person:
            path(arc(0, 0.45, 0.38, 0.38, from: 0, to: 2 * .pi, steps: 12))
            path(arc(0, -0.95, 0.8, 0.85, from: 0.15, to: .pi - 0.15))
        case .crown:
            path([(-0.9, -0.6), (0.9, -0.6), (0.95, 0.55), (0.45, 0.0), (0, 0.75), (-0.45, 0.0), (-0.95, 0.55)], closed: true)
        case .pen, .penCrossed:
            path([(-0.75, -0.75), (-0.55, -0.15), (0.55, 0.95), (0.95, 0.55), (-0.15, -0.55)], closed: true)
            path([(-0.75, -0.75), (-0.35, -0.35)])
            if self == .penCrossed { slash() }
        }
    }
}
