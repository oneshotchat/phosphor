import MetalKit
import OSCCore
import QuartzCore
import simd

struct FrameUniforms {
    var viewProj: simd_float4x4
    var params: SIMD4<Float>   // viewport.xy, fadeNear, fadeFar
}

struct PostUniforms {
    var resX: Float, resY: Float, time: Float, curvature: Float
    var scanlines: Float, aberration: Float, bloom: Float, vignette: Float
    var grain: Float, exposure: Float, pad0: Float = 0, pad1: Float = 0
}

/// scene (HDR, additive) → phosphor persistence → bloom → CRT composite.
@MainActor
final class Renderer: NSObject, MTKViewDelegate {
    var camera = Camera()
    var crtEnabled = true
    var readingMode = false {
        didSet { readingToggledAt = AppClock.now }
    }
    private var readingToggledAt: Float = -100
    private var wasBrowsing = false
    /// The message the view is pinned to while scrolled up, and where it was last frame.
    private var anchor: (id: Int, y: Float)?

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let atlas: GlyphAtlas
    /// One scene per joined room; the active one is flat in front, the rest roll up into
    /// cylinders arranged by `layout`.
    private var scenes: [String: RoomScene] = [:]
    private var placements: [String: RoomScene.Placement] = [:]
    private var ripples: [FrameGeometry.Ripple] = []
    private var ringAngle: Float = 0
    private var layoutChangedAt: Float = -100
    private var roomsMovedAt: Float = -100
    /// The room that was active before the last switch.
    private var switchedFrom: String?
    /// How quickly rooms move in the row (exponential ease rate, per second).
    private let rowSpeed: Float = 5.5
    var layout: RoomLayout = RoomLayout(rawValue: UserDefaults.standard.string(forKey: "roomLayout") ?? "") ?? .ring {
        didSet {
            UserDefaults.standard.set(layout.rawValue, forKey: "roomLayout")
            layoutChangedAt = AppClock.now
            roomsMovedAt = AppClock.now
        }
    }
    private var activeScene: RoomScene? { controller.activeRoom.flatMap { scenes[$0] } }
    private let hud: HUD
    private let browserScene: BrowserScene
    /// Where each unjoined room stands in the overview this frame (as a room origin); a
    /// room joined from there starts from that spot.
    private var ghostOrigins: [String: SIMD3<Float>] = [:]
    /// The overview's row of unjoined rooms: how far it has slid sideways, and how visible
    /// it is (it fades in and out with the overview, keeping the last rooms while fading).
    private var ghostScroll: Float = 0
    private var ghostAlpha: Float = 0
    private var ghostRooms: [Room] = []
    /// The overview camera, kept so the row can be fitted to the eventual view, not the
    /// one still easing toward it.
    private static let overviewTarget = SIMD3<Float>(0, 3, 8)
    private static let overviewPitch: Float = 0.34
    private static let overviewDistance: Float = 60
    private static let ghostRowZ: Float = 18
    private let controller: ChatController
    private weak var phosphorView: PhosphorView?
    private var themeIndex = 0

    private let linePipeline: MTLRenderPipelineState
    private let glyphPipeline: MTLRenderPipelineState
    private let persistPipeline: MTLRenderPipelineState
    private let bloomDownPipeline: MTLRenderPipelineState
    private let bloomUpPipeline: MTLRenderPipelineState
    private let compositePipeline: MTLRenderPipelineState

    private static let hdrFormat = MTLPixelFormat.rgba16Float

    private var sceneTexture: MTLTexture?
    private var accum: [MTLTexture] = []
    private var accumIndex = 0
    private var bloomLevels: [MTLTexture] = []

    private var lastFrameTime = CACurrentMediaTime()
    private var frameTimes: [Float] = []
    private var lastCPU: Float = 0
    private static let logFPS = ProcessInfo.processInfo.environment["PHOSPHOR_FPS"] != nil
    private var effects: Float = 1          // eases between full CRT (1) and clean (0)
    private var eye = SIMD3<Float>(0, 0, 0)
    private var lookTarget = SIMD3<Float>(0, 0, 0)
    private var hasCamera = false
    private let snapshot = Snapshot.fromEnvironment()
    /// Applied once the starting room is up (switching rooms resets the scroll).
    private var pendingSnapshotLift: Float?

    private var theme: Theme { Theme.all[themeIndex] }

    init(view: PhosphorView, controller: ChatController) throws {
        guard let device = view.device, let queue = device.makeCommandQueue() else {
            throw RendererError.noDevice
        }
        self.device = device
        self.queue = queue
        atlas = GlyphAtlas(device: device)
        hud = HUD(atlas: atlas)
        browserScene = BrowserScene(atlas: atlas)
        self.controller = controller
        phosphorView = view

        view.colorPixelFormat = .bgra8Unorm_srgb
        view.clearColor = MTLClearColorMake(0, 0, 0, 1)
        view.preferredFramesPerSecond = 120
        view.framebufferOnly = true

        let library = try device.makeLibrary(source: shaderSource, options: nil)
        func pipeline(_ vertex: String, _ fragment: String, _ format: MTLPixelFormat,
                      additive: Bool = false) throws -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = library.makeFunction(name: vertex)
            d.fragmentFunction = library.makeFunction(name: fragment)
            d.colorAttachments[0].pixelFormat = format
            if additive {
                let c = d.colorAttachments[0]!
                c.isBlendingEnabled = true
                c.rgbBlendOperation = .add
                c.alphaBlendOperation = .add
                c.sourceRGBBlendFactor = .one
                c.destinationRGBBlendFactor = .one
                c.sourceAlphaBlendFactor = .one
                c.destinationAlphaBlendFactor = .one
            }
            return try device.makeRenderPipelineState(descriptor: d)
        }
        linePipeline = try pipeline("line_vertex", "line_fragment", Self.hdrFormat, additive: true)
        glyphPipeline = try pipeline("glyph_vertex", "glyph_fragment", Self.hdrFormat, additive: true)
        persistPipeline = try pipeline("fullscreen_vertex", "persist_fragment", Self.hdrFormat)
        bloomDownPipeline = try pipeline("fullscreen_vertex", "bloom_down_fragment", Self.hdrFormat)
        bloomUpPipeline = try pipeline("fullscreen_vertex", "bloom_up_fragment", Self.hdrFormat, additive: true)
        compositePipeline = try pipeline("fullscreen_vertex", "composite_fragment", view.colorPixelFormat)

        super.init()
        if let snapshot {
            readingMode = snapshot.readingMode
            themeIndex = snapshot.theme % Theme.all.count
            pendingSnapshotLift = snapshot.lift > 0 ? snapshot.lift : nil
            if let layout = snapshot.layout { self.layout = layout }
        }
    }

    func nextTheme() {
        themeIndex = (themeIndex + 1) % Theme.all.count
    }

    // MARK: targets

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        makeTargets(width: Int(size.width), height: Int(size.height))
    }

    private func makeTargets(width: Int, height: Int) {
        guard width > 0, height > 0 else { return }
        func target(_ w: Int, _ h: Int) -> MTLTexture {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: Self.hdrFormat, width: w, height: h, mipmapped: false)
            d.usage = [.renderTarget, .shaderRead]
            d.storageMode = .private
            return device.makeTexture(descriptor: d)!
        }
        sceneTexture = target(width, height)
        accum = [target(width, height), target(width, height)]
        bloomLevels = []
        var w = width / 2, h = height / 2
        while bloomLevels.count < 6, min(w, h) >= 8 {
            bloomLevels.append(target(w, h))
            w /= 2
            h /= 2
        }
        // Start the persistence buffers black.
        if let cb = queue.makeCommandBuffer() {
            for t in accum { pass(cb, t, clear: true)?.endEncoding() }
            cb.commit()
        }
    }

    // MARK: frame

    func draw(in view: MTKView) {
        let size = view.drawableSize
        if sceneTexture?.width != Int(size.width) || sceneTexture?.height != Int(size.height) {
            makeTargets(width: Int(size.width), height: Int(size.height))
        }
        guard let sceneTexture, !bloomLevels.isEmpty,
              let drawable = view.currentDrawable,
              let cb = queue.makeCommandBuffer()
        else { return }

        let now = CACurrentMediaTime()
        let dt = Float(min(now - lastFrameTime, 0.1))
        lastFrameTime = now
        frameTimes.append(Float(now))
        if let first = frameTimes.first, Float(now) - first > 2 {
            if Self.logFPS { fputs(String(format: "fps %.0f  cpu %.1f ms/frame\n", Float(frameTimes.count) / (Float(now) - first), lastCPU * 1000), stderr) }
            frameTimes.removeAll()
        }
        let cpuStart = CACurrentMediaTime()
        defer { lastCPU = Float(CACurrentMediaTime() - cpuStart) }
        let time = AppClock.now

        effects += ((crtEnabled && !readingMode ? 1 : 0) - effects) * min(1, dt * 6)

        // Camera: orbit, or face the selected (else newest) message head-on in reading mode.
        let aspect = Float(size.width / size.height)
        let fovy: Float = 0.9
        // Scrollback: lift eases at the same rate panels glide, so both move together.
        camera.liftTarget = simd_clamp(camera.liftTarget, 0, maxLift)
        camera.lift += (camera.liftTarget - camera.lift) * min(1, dt * 8)
        activeScene?.isLifted = camera.liftTarget > 1
        var desiredEye = camera.eye, desiredTarget = camera.center
        if controller.browser.isOpen {
            // Overview: pull up and back, with the rooms you could join in a row in front.
            desiredTarget = Self.overviewTarget
            desiredEye = desiredTarget + SIMD3(0, sin(Self.overviewPitch), cos(Self.overviewPitch)) * Self.overviewDistance
        } else if readingMode, let scene = activeScene, let id = controller.focus ?? scene.newestVisible, let panel = scene.panelFrames[id] {
            // Back off until the whole panel fits on screen, with a margin.
            let fitWidth = panel.width / 2 * 1.2 / (tan(fovy / 2) * aspect)
            let fitHeight = panel.height / 2 * 1.6 / tan(fovy / 2)
            desiredEye = panel.center + panel.normal * max(4, fitWidth, fitHeight)
            desiredTarget = panel.center
        }
        if !hasCamera { eye = desiredEye; lookTarget = desiredTarget; hasCamera = true }
        // Ease slowly in and out of reading mode and the browser; otherwise follow closely.
        if controller.browser.isOpen != wasBrowsing {
            wasBrowsing = controller.browser.isOpen
            readingToggledAt = time
        }
        let ease = SIMD3(repeating: min(1, dt * (readingMode || controller.browser.isOpen || time - readingToggledAt < 1.2 ? 3 : 14)))
        eye = simd_mix(eye, desiredEye, ease)
        lookTarget = simd_mix(lookTarget, desiredTarget, ease)

        let viewMatrix = simd_float4x4.lookAt(eye: eye, center: lookTarget, up: [0, 1, 0])
        let proj = simd_float4x4.perspective(fovyRadians: fovy, aspect: aspect, near: 0.1, far: 200)
        var uniforms = FrameUniforms(viewProj: proj * viewMatrix,
                                     params: SIMD4(Float(size.width), Float(size.height), 12, 55))
        let cameraRight = SIMD3(viewMatrix.columns.0.x, viewMatrix.columns.1.x, viewMatrix.columns.2.x)
        let cameraUp = SIMD3(viewMatrix.columns.0.y, viewMatrix.columns.1.y, viewMatrix.columns.2.y)

        let pixelScale = Float(view.window?.backingScaleFactor ?? 2)
        var geometry = FrameGeometry()
        geometry.pixelScale = pixelScale
        arrangeRooms(dt: dt, time: time)
        ripples.removeAll { time - $0.startedAt > FrameGeometry.Ripple.duration }
        geometry.floorGrid(theme: theme, ripples: ripples, time: time)
        if let lift = pendingSnapshotLift, time > 1.5 {
            camera.liftTarget = lift
            pendingSnapshotLift = nil
        }
        for (index, room) in controller.rooms.enumerated() {
            guard let scene = scenes[room] else { continue }
            let active = room == controller.activeRoom
            scene.build(into: &geometry, state: controller.state(room), theme: theme, me: controller.me, origin: controller.origin,
                        focus: active ? controller.focus : nil, eye: eye, cameraRight: cameraRight, cameraUp: cameraUp,
                        viewY: lookTarget.y, index: index,     // scrolling up lifts every room's sky
                        activity: controller.activity[room] ?? ChatController.Activity())
        }
        keepScrollbackSteady()
        buildGhosts(into: &geometry, dt: dt, aspect: aspect, fovy: fovy, cameraRight: cameraRight, cameraUp: cameraUp)

        // HUD in drawable pixels, origin bottom-left.
        var hudGeometry = FrameGeometry()
        hudGeometry.pixelScale = pixelScale
        let viewport = SIMD2(Float(size.width), Float(size.height))
        if let input = phosphorView?.input {
            let unseen = activeScene?.unseen ?? 0
            let hint: String? = activeScene?.isLifted != true ? nil
                : unseen > 0 ? "↓ \(unseen) new  ·  ⌘↓ latest" : "scrolled up  ·  ⌘↓ latest"
            hud.build(into: &hudGeometry, viewport: viewport, scale: pixelScale, controller: controller, input: input,
                      theme: theme, hint: hint)
            if controller.browser.isOpen {
                hud.buildBrowser(into: &hudGeometry, viewport: viewport, scale: pixelScale, browser: controller.browser, theme: theme)
            }
        }
        var hudUniforms = FrameUniforms(
            viewProj: simd_float4x4(columns: (SIMD4(2 / viewport.x, 0, 0, 0), SIMD4(0, 2 / viewport.y, 0, 0),
                                              SIMD4(0, 0, 0, 0), SIMD4(-1, -1, 0.5, 1))),
            params: SIMD4(viewport.x, viewport.y, 12, 55))

        // 1. Scene, then HUD: everything additive into HDR, so draw order doesn't matter.
        if let enc = pass(cb, sceneTexture, clear: true) {
            draw(geometry, uniforms: &uniforms, with: enc)
            draw(hudGeometry, uniforms: &hudUniforms, with: enc)
            enc.endEncoding()
        }

        // 2. Persistence: the phosphor keeps glowing as the beam moves on.
        let previous = accum[accumIndex]
        accumIndex ^= 1
        let current = accum[accumIndex]
        // Shorter persistence while rooms are rearranging: every line on screen moves at
        // once, and full trails turn the switch into a smear.
        let rearranging = 1 - smoothstep(0.6, 1.6, time - roomsMovedAt)
        var decay = powf(simd_mix(0.55, 0.8, effects) * (1 - 0.35 * rearranging), dt * 60)
        if let enc = pass(cb, current, clear: false) {
            enc.setRenderPipelineState(persistPipeline)
            enc.setFragmentTexture(sceneTexture, index: 0)
            enc.setFragmentTexture(previous, index: 1)
            enc.setFragmentBytes(&decay, length: MemoryLayout<Float>.size, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            enc.endEncoding()
        }

        // 3. Bloom: threshold + downsample chain, then additive upsample back to level 0.
        var source = current
        for (i, level) in bloomLevels.enumerated() {
            var params = SIMD4<Float>(1 / Float(source.width), 1 / Float(source.height), 0.55, i == 0 ? 1 : 0)
            if let enc = pass(cb, level, clear: false) {
                enc.setRenderPipelineState(bloomDownPipeline)
                enc.setFragmentTexture(source, index: 0)
                enc.setFragmentBytes(&params, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                enc.endEncoding()
            }
            source = level
        }
        for i in stride(from: bloomLevels.count - 1, to: 0, by: -1) {
            let src = bloomLevels[i]
            var params = SIMD4<Float>(1 / Float(src.width), 1 / Float(src.height), 0, 0)
            if let enc = pass(cb, bloomLevels[i - 1], clear: false, load: true) {
                enc.setRenderPipelineState(bloomUpPipeline)
                enc.setFragmentTexture(src, index: 0)
                enc.setFragmentBytes(&params, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                enc.endEncoding()
            }
        }

        // 4. CRT composite onto the drawable.
        var post = PostUniforms(
            resX: Float(size.width), resY: Float(size.height), time: time,
            curvature: 0.045 * effects,
            scanlines: 0.55 * effects,
            aberration: 2.5 * geometry.pixelScale * effects,
            bloom: simd_mix(0.35, 0.9, effects),
            vignette: simd_mix(0.3, 1, effects),
            grain: 0.035 * effects,
            exposure: 1.25
        )
        func composite(into target: MTLTexture) {
            guard let enc = pass(cb, target, clear: true) else { return }
            enc.setRenderPipelineState(compositePipeline)
            enc.setFragmentTexture(current, index: 0)
            enc.setFragmentTexture(bloomLevels[0], index: 1)
            enc.setFragmentBytes(&post, length: MemoryLayout<PostUniforms>.stride, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            enc.endEncoding()
        }
        composite(into: drawable.texture)
        if snapshot?.isDue(time: time) == true, let snapshot,
           let target = snapshot.makeTarget(device: device, size: size, format: view.colorPixelFormat) {
            composite(into: target)
            cb.addCompletedHandler { _ in snapshot.write(target) }
        }

        cb.present(drawable)
        cb.commit()
    }

    // MARK: rooms

    func handle(_ event: Event, in room: String) {
        guard let scene = scenes[room] else { return }
        scene.handle(event)
        // A mention sends one wave across the floor from the room's base, from where the
        // room stands now; it plays out even if you switch rooms meanwhile. Softer for the
        // room you're in, which shows the message itself.
        if case .messageCreated(let m) = event.payload, m.author.identity != controller.me,
           m.mentions?.contains(controller.me) == true {
            ripples.append(FrameGeometry.Ripple(center: scene.floorCenter, radius: scene.wallWidth / 2, startedAt: AppClock.now,
                                                strength: room == controller.activeRoom ? 0.5 : 1))
        }
    }
    func reload(_ room: String) { scenes[room]?.reset() }

    /// Switching rooms starts the new one at its latest messages.
    func activeChanged(from old: String?, to new: String?) {
        switchedFrom = old
        camera.liftTarget = 0
        anchor = nil
        readingMode = false
        roomsMovedAt = AppClock.now
        if let old { scenes[old]?.isLifted = false }
    }

    /// Creates scenes for new rooms, drops departed ones, and moves every room toward its
    /// spot in the ring or row: the active room flat at the front, the rest rolled up.
    private func arrangeRooms(dt: Float, time: Float) {
        let rooms = controller.rooms
        for id in scenes.keys where !rooms.contains(id) {
            scenes[id] = nil
            placements[id] = nil
        }
        let count = rooms.count
        guard count > 0 else { return }
        let activeIndex = controller.activeRoom.flatMap { rooms.firstIndex(of: $0) } ?? 0
        let step = 2 * Float.pi / Float(count)
        let radius = max(22, Float(count) * 24 / (2 * .pi))     // room for 16-wide cylinders
        var delta = -Float(activeIndex) * step - ringAngle
        delta = atan2(sin(delta), cos(delta))          // spin the short way round
        ringAngle += delta * min(1, dt * 3)

        // Ring targets move smoothly as the ring spins, so follow them closely; a layout
        // switch eases everything across.
        let follow = min(1, dt * (time - layoutChangedAt < 1.5 ? 3 : 10))
        let steppingBack = layout == .row && time - roomsMovedAt < rowSwitchDelay(rooms: rooms, activeIndex: activeIndex)
        let cameraFloor = SIMD3<Float>(0, 0, 19)
        for (i, id) in rooms.enumerated() {
            // The incoming room waits in its slot until the old one has stepped back.
            let active = i == activeIndex && !steppingBack
            let target: SIMD3<Float> = switch layout {
            case .ring:
                SIMD3(sin(Float(i) * step + ringAngle) * radius, 0, cos(Float(i) * step + ringAngle) * radius - radius)
            case .row:
                // A line in the distance. Slots follow join order, so a room always
                // returns to the same place.
                active ? .zero : rowSlot(i, of: count)
            }
            let joinedFromBrowser = placements[id] == nil ? ghostOrigins[id] : nil
            var p = placements[id] ?? RoomScene.Placement(origin: joinedFromBrowser ?? target)
            p.origin += (target - p.origin) * (layout == .row ? min(1, dt * rowSpeed) : follow)
            // Row walls face straight ahead, square with the grid; ring cylinders turn their
            // front toward the camera so their busiest side shows.
            let toCamera = cameraFloor - p.origin
            let facing = layout == .row || simd_length(toCamera) < 0.01
                ? SIMD3<Float>(0, 0, 1) : simd_normalize(SIMD3(toCamera.x, 0, toCamera.z))
            p.normal = simd_normalize(p.normal + (facing - p.normal) * follow)
            placements[id] = p

            // Background rooms roll into cylinders in the ring; in the row they stay flat.
            let scene = scenes[id] ?? RoomScene(atlas: atlas)
            scene.placement = p
            scene.targetCurl = active || layout == .row ? 0 : 1
            scene.targetBackground = active ? 0 : 1
            if scenes[id] == nil {
                scene.settle()
                if joinedFromBrowser != nil { scene.startAsGhost(rolledUp: layout == .ring) }
                scenes[id] = scene
            }
            scene.isActive = active
            scene.dim = active ? 1 : 0.5
        }
    }

    /// How long the incoming room waits in its slot so it can't clip the outgoing one.
    ///
    /// Both ease exponentially at `rowSpeed`: the old room from the front to its slot, the
    /// new one from its slot to the front, starting `d` later. Walls are parallel, so they
    /// can only touch when at the same depth; at that moment their sideways gap is
    /// (slot distance) × (1 − u), where u = 1 / (1 + e^(k·d)). Keeping that gap above a
    /// wall's width plus a margin gives the smallest safe `d`. Rooms whose slots are far
    /// enough apart never overlap and move together.
    private func rowSwitchDelay(rooms: [String], activeIndex: Int) -> Float {
        guard let old = switchedFrom, let oldIndex = rooms.firstIndex(of: old), oldIndex != activeIndex else { return 0 }
        let apart = abs(rowSlot(activeIndex, of: rooms.count).x - rowSlot(oldIndex, of: rooms.count).x)
        let needed = min(0.99, 17 / apart)          // fraction of the slot distance that must remain
        return needed <= 0.5 ? 0 : log(needed / (1 - needed)) / rowSpeed
    }

    /// Slot `i` of `count` in the row. Rooms keep their real size (a wall is 8 grid
    /// squares wide wherever it stands), two squares apart, with edges on grid lines; the
    /// row sits as far back as it needs to for all of them to fit across the view.
    private func rowSlot(_ i: Int, of count: Int) -> SIMD3<Float> {
        let pitch: Float = 20                                       // wall width + two squares
        let cameraZ: Float = 19
        let depth = max(48, (Float(count) * pitch / 2 + 1) / 0.77)  // half-width of view ≈ 0.77 × depth
        let x = (Float(i) - Float(count - 1) / 2) * pitch
        let z = ((cameraZ - depth) / 2).rounded(.down) * 2          // on a grid line
        return SIMD3(x, 0, z)
    }

    /// The overview's rooms you haven't joined: a row in front of the active room, in the
    /// current layout's form. If they don't all fit across the view, the row slides to keep
    /// the selected one on screen.
    private func buildGhosts(into g: inout FrameGeometry, dt: Float, aspect: Float, fovy: Float,
                             cameraRight: SIMD3<Float>, cameraUp: SIMD3<Float>) {
        let browser = controller.browser
        if browser.isOpen {
            ghostRooms = browser.entries.compactMap { if case .listed(let room) = $0 { room } else { nil } }
        }
        ghostAlpha += ((browser.isOpen ? 1 : 0) - ghostAlpha) * min(1, dt * 4)
        guard ghostAlpha > 0.01 else {
            ghostScroll = 0
            return
        }

        let pitch: Float = 20                                   // a room's width plus two squares
        let count = ghostRooms.count
        let selected = browser.selected?.id
        let selectedIndex = ghostRooms.firstIndex { $0.id == selected }
        // How much of the row the overview camera sees.
        let eyeZ = Self.overviewTarget.z + cos(Self.overviewPitch) * Self.overviewDistance
        let halfView = tan(fovy / 2) * aspect * (eyeZ - Self.ghostRowZ) * 0.92
        var target: Float = 0
        if Float(count) * pitch > halfView * 2, let i = selectedIndex {
            let x = (Float(i) - Float(count - 1) / 2) * pitch
            let limit = halfView - pitch * 0.55
            target = simd_clamp(ghostScroll, -limit - x, limit - x)
        }
        ghostScroll += (target - ghostScroll) * min(1, dt * 6)

        var placed: [BrowserScene.Placed] = []
        var origins: [String: SIMD3<Float>] = [:]
        for (i, room) in ghostRooms.enumerated() {
            let x = (Float(i) - Float(count - 1) / 2) * pitch + ghostScroll
            guard abs(x) < halfView + pitch * 1.5 else { continue }    // well off screen
            let origin = SIMD3<Float>(x, 0, Self.ghostRowZ + (layout == .ring ? BrowserScene.width / 2 : 0))
            origins[room.id] = origin
            placed.append(BrowserScene.Placed(room: room, origin: origin))
        }
        ghostOrigins = origins
        browserScene.build(into: &g, rooms: placed, selected: browser.isOpen ? selected : nil,
                           cylinders: layout == .ring, alpha: ghostAlpha, theme: theme,
                           cameraRight: cameraRight, cameraUp: cameraUp)
    }

    /// The highest the view may fly: the top of everything loaded.
    private var maxLift: Float { max(0, (activeScene?.stackTop ?? 0) - camera.target.y - 2) }

    /// While scrolled up, new messages push the stack up from below; lift the view by the
    /// same amount so the message being read stays put. Near the top, fetch older history.
    private func keepScrollbackSteady() {
        guard let scene = activeScene else { return }
        if scene.isLifted, let anchor, let now = scene.targetBottoms[anchor.id] {
            camera.liftTarget += now - anchor.y
        }
        anchor = scene.referenceMessage.flatMap { id in scene.targetBottoms[id].map { (id, $0) } }
        if camera.liftTarget > maxLift - 6 { controller.loadOlder() }
    }

    /// Back to the default framing: straight on, at the latest messages.
    func resetView() {
        let defaults = Camera()
        camera.yaw = defaults.yaw
        camera.pitch = defaults.pitch
        camera.distance = defaults.distance
        camera.liftTarget = 0
        readingMode = false
    }

    func jumpToLatest() {
        camera.liftTarget = 0
        readingMode = false
    }

    private func draw(_ geometry: FrameGeometry, uniforms: inout FrameUniforms, with enc: MTLRenderCommandEncoder) {
        enc.setVertexBytes(&uniforms, length: MemoryLayout<FrameUniforms>.stride, index: 1)
        if !geometry.lines.isEmpty, let buffer = makeBuffer(geometry.lines) {
            enc.setRenderPipelineState(linePipeline)
            enc.setVertexBuffer(buffer, offset: 0, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: geometry.lines.count)
        }
        if !geometry.glyphs.isEmpty, let buffer = makeBuffer(geometry.glyphs) {
            enc.setRenderPipelineState(glyphPipeline)
            enc.setVertexBuffer(buffer, offset: 0, index: 0)
            enc.setFragmentTexture(atlas.texture, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: geometry.glyphs.count)
        }
    }

    private func pass(_ cb: MTLCommandBuffer, _ target: MTLTexture, clear: Bool, load: Bool = false) -> MTLRenderCommandEncoder? {
        let d = MTLRenderPassDescriptor()
        d.colorAttachments[0].texture = target
        d.colorAttachments[0].loadAction = clear ? .clear : (load ? .load : .dontCare)
        d.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
        d.colorAttachments[0].storeAction = .store
        return cb.makeRenderCommandEncoder(descriptor: d)
    }

    // A fresh buffer per frame is fine at prototype scale; ring buffers later.
    private func makeBuffer<T>(_ items: [T]) -> MTLBuffer? {
        items.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) }
    }
}

enum RoomLayout: String {
    /// Rooms on a circle; switching spins it.
    case ring
    /// Rooms in a line behind; the active one comes forward.
    case row
}

enum RendererError: Error {
    case noDevice
}
