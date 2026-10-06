import Foundation
import simd

/// `--tour`: plays the demo's running order by itself, for recording a video. It drives
/// the app the way a person would (typing, switching rooms, moving the camera, browsing,
/// leaving), and cues the beats that are random in the demo (a reaction to your message,
/// a mention from a background room) so they land on time. About 2½ minutes, or about 40
/// seconds with `--tour-fast`.
@MainActor
final class DemoTour {
    private let controller: ChatController
    private let renderer: Renderer
    private let view: PhosphorView
    /// `--tour-fast`: the same beats cut like an ad, about 40 seconds.
    private let fast: Bool
    private var task: Task<Void, Never>?

    init(controller: ChatController, renderer: Renderer, view: PhosphorView, fast: Bool = false) {
        self.controller = controller
        self.renderer = renderer
        self.view = view
        self.fast = fast
    }

    /// Your CRT and layout settings, put back on quit: the tour changes them, and they're
    /// remembered between launches.
    private var savedCRT = false
    private var savedLayout = RoomLayout.ring

    func restoreSettings() {
        renderer.crtEnabled = savedCRT
        renderer.layout = savedLayout
    }

    func start(after lead: Double = 6) {
        savedCRT = renderer.crtEnabled
        savedLayout = renderer.layout
        task = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(lead))     // let the rooms fill up
                try await self?.run()
            } catch {}
        }
    }

    func stop() { task?.cancel() }

    private func run() async throws {
        renderer.layout = .ring
        controller.activate(index: 0)

        // 1. #lobby: let messages beam up and write themselves out.
        try await wait(9, 3)

        // 2. Say something; someone reacts. Then mention someone via autocomplete.
        try await type(fast ? "why is my chat client glowing ✦" : "just installed phosphor. why is my chat client glowing")
        view.devPressReturn()
        try await wait(2.5, 1.2)
        controller.demoReactToMine("🔥")
        try await wait(4, 1.2)
        try await type("@sa")
        try await wait(1.2, 0.6)                             // autocomplete shows
        view.devPressTab()
        try await type(fast ? "seen the vaporise effect?" : "have you seen the vaporise effect yet?")
        view.devPressReturn()
        try await wait(5, 1.6)

        // 3. A mention from a background room ripples the floor.
        controller.demoMention(roomIndex: 1)
        try await wait(6, 2.6)

        // 4. Switch rooms: #dev (where the ping came from), #clients, back to #lobby.
        controller.cycle(1)
        try await wait(6, 2.2)
        controller.cycle(1)
        try await wait(7, 2.2)
        controller.activate(index: 0)
        try await wait(5, 2)

        // 5. Fly up through history, then back down.
        try await animate(3.5, 1.6) { t in self.renderer.camera.liftTarget = 9 * t }
        try await wait(3, 0.8)
        renderer.jumpToLatest()
        try await wait(3, 1.2)

        // 6. Move the camera: orbit round, zoom in, a reading-mode close-up, reset.
        let yaw = renderer.camera.yaw
        try await animate(6, 2.2) { t in self.renderer.camera.yaw = yaw + 1.1 * Self.ease(t) }
        try await wait(1, 0.2)
        try await animate(4, 1.8) { t in self.renderer.camera.yaw = yaw + 1.1 - 2.0 * Self.ease(t) }
        let distance = renderer.camera.distance
        try await animate(3, 1.2) { t in self.renderer.camera.distance = distance * (1 - 0.35 * Self.ease(t)) }
        try await wait(1.5, 0.4)
        renderer.resetView()
        try await wait(3, 1.4)
        renderer.readingMode = true
        try await wait(4, 2)
        renderer.readingMode = false
        try await wait(3, 1.4)

        // 7. The row layout, and a switch between neighbours there.
        renderer.layout = .row
        try await wait(5, 2.4)
        controller.cycle(1)
        try await wait(5, 2.2)
        controller.cycle(-1)
        try await wait(4, 2)
        renderer.layout = .ring
        try await wait(5, 2.2)

        // 8. The room browser: look around, then join #showcase.
        view.toggleBrowser()
        try await wait(3, 1.4)
        for _ in 0..<3 {
            controller.browser.move(1)
            try await wait(1.2, 0.35)
        }
        controller.browser.move(-1)                           // #showcase
        try await wait(1.5, 0.6)
        view.devPressReturn()
        try await wait(6, 3)

        // 9. Leave it: vaporise.
        controller.leaveActive()
        try await wait(7, 3)

        // 10. Finale: the CRT look, then a phosphor theme.
        renderer.crtEnabled = true
        try await wait(5, 1.6)
        renderer.nextTheme()
        try await wait(5, 1.2)
        renderer.nextTheme()
        try await wait(5, 1.6)
        // Back to the signature colours, keeping the CRT look on for the ending.
        while renderer.themeName != "vector" { renderer.nextTheme() }

        // 11. Ending: over to #dev and up through its history, slow at first, faster and
        //     faster, on past the oldest message into the sky. Fade out here.
        controller.activate(index: 1)
        try await wait(5, 3)
        renderer.liftPastTop = true
        let climb: Double = fast ? 7 : 9
        try await animate(climb, climb) { t in self.renderer.camera.liftTarget = 280 * t * t * t }
        // …and keep going, at the speed it reached, until the video fades.
        let speed: Float = 3 * 280 / Float(climb)
        while true {
            renderer.camera.liftTarget += speed / 60
            try await Task.sleep(for: .milliseconds(16))
        }
    }

    // MARK: helpers

    /// Waits `slow` seconds, or `quick` in the fast cut.
    private func wait(_ slow: Double, _ quick: Double) async throws {
        try await Task.sleep(for: .seconds(fast ? quick : slow))
    }

    /// Types like a person: a character at a time, a little uneven.
    private func type(_ text: String) async throws {
        for ch in text {
            view.devType(String(ch))
            try await Task.sleep(for: .milliseconds(fast ? Int.random(in: 14...28) : Int.random(in: 35...85)))
        }
    }

    /// Calls `step` with t from 0 to 1 over `seconds`, once a frame.
    private func animate(_ slow: Double, _ quick: Double, _ step: (Float) -> Void) async throws {
        let frames = max(1, Int((fast ? quick : slow) * 60))
        for i in 1...frames {
            step(Float(i) / Float(frames))
            try await Task.sleep(for: .milliseconds(16))
        }
    }

    private static func ease(_ t: Float) -> Float { t * t * (3 - 2 * t) }
}
