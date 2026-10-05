import MetalKit
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
final class Renderer: NSObject, MTKViewDelegate {
    var camera = Camera()
    var crtEnabled = true
    var readingMode = false

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let atlas: GlyphAtlas
    private let scene = DemoScene()
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

    private let startTime = CACurrentMediaTime()
    private var lastFrameTime = CACurrentMediaTime()
    private var effects: Float = 1          // eases between full CRT (1) and clean (0)
    private var eye = SIMD3<Float>(0, 0, 0)
    private var lookTarget = SIMD3<Float>(0, 0, 0)
    private var hasCamera = false
    private let snapshot = Snapshot.fromEnvironment()

    private var theme: Theme { Theme.all[themeIndex] }

    init(view: MTKView) throws {
        guard let device = view.device, let queue = device.makeCommandQueue() else {
            throw RendererError.noDevice
        }
        self.device = device
        self.queue = queue
        atlas = GlyphAtlas(device: device)

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
        }
        print("Phosphor: drag to orbit, scroll to zoom, R reading mode, T theme, space CRT on/off")
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
        let time = Float(now - startTime)

        effects += ((crtEnabled && !readingMode ? 1 : 0) - effects) * min(1, dt * 6)

        // Camera: orbit, or snap face-on to the newest message in reading mode.
        if !readingMode { camera.yaw += dt * 0.04 }
        let aspect = Float(size.width / size.height)
        let fovy: Float = 0.9
        var desiredEye = camera.eye, desiredTarget = camera.target
        if readingMode {
            let newest = scene.newestVisibleMessage(time: time)
            let panel = scene.panelFrame(newest)
            // Back off until the whole panel fits across the screen, with a margin.
            let halfWidth = scene.panelWidth(newest, atlas: atlas) / 2 * 1.15
            let distance = max(4, halfWidth / (tan(fovy / 2) * aspect))
            desiredEye = panel.center + panel.normal * distance
            desiredTarget = panel.center
        }
        if !hasCamera { eye = desiredEye; lookTarget = desiredTarget; hasCamera = true }
        let ease = SIMD3(repeating: min(1, dt * 4))
        eye = simd_mix(eye, desiredEye, ease)
        lookTarget = simd_mix(lookTarget, desiredTarget, ease)

        let viewMatrix = simd_float4x4.lookAt(eye: eye, center: lookTarget, up: [0, 1, 0])
        let proj = simd_float4x4.perspective(fovyRadians: fovy, aspect: aspect, near: 0.1, far: 200)
        var uniforms = FrameUniforms(viewProj: proj * viewMatrix,
                                     params: SIMD4(Float(size.width), Float(size.height), 12, 55))
        let cameraRight = SIMD3(viewMatrix.columns.0.x, viewMatrix.columns.1.x, viewMatrix.columns.2.x)
        let cameraUp = SIMD3(viewMatrix.columns.0.y, viewMatrix.columns.1.y, viewMatrix.columns.2.y)

        var geometry = FrameGeometry()
        geometry.pixelScale = Float(view.window?.backingScaleFactor ?? 2)
        scene.build(into: &geometry, atlas: atlas, time: time, theme: theme,
                    eye: eye, cameraRight: cameraRight, cameraUp: cameraUp)

        // 1. Scene: everything additive into HDR; draw order doesn't matter.
        if let enc = pass(cb, sceneTexture, clear: true) {
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
            enc.endEncoding()
        }

        // 2. Persistence: the phosphor keeps glowing as the beam moves on.
        let previous = accum[accumIndex]
        accumIndex ^= 1
        let current = accum[accumIndex]
        var decay = powf(simd_mix(0.55, 0.86, effects), dt * 60)
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

enum RendererError: Error {
    case noDevice
}
