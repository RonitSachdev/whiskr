import Foundation
@preconcurrency import Metal
import QuartzCore
import simd

// One render pass per frame: 4× MSAA colour and depth in tile memory (memoryless), resolved into the
// target. Opaque things first (cats, picnic, plants, ground, grass), the sky only where nothing was
// drawn, then everything see-through. Three frames in flight, each with its own scratch arena.

/// Diagnostics only: `MEADOW_SKIP=grass,ground,…` leaves those passes out, to find what costs.
let debugSkip = Set((ProcessInfo.processInfo.environment["MEADOW_SKIP"] ?? "").split(separator: ",").map(String.init))

final class Renderer {
    static let inFlight = 3
    let gpu: GPU
    let cats: CatDrawer
    let meadow: MeadowDrawer
    let village: VillageDrawer
    private let arenas: [Arena]
    private let frameBuffers: [MTLBuffer]
    private let worldBuffers: [MTLBuffer]
    let semaphore = DispatchSemaphore(value: Renderer.inFlight)
    private(set) var slot = 0
    private var msaaColor: MTLTexture?
    private var msaaDepth: MTLTexture?
    private var targetSize = (0, 0)

    init(device: MTLDevice) throws {
        gpu = try GPU(device: device)
        cats = CatDrawer(gpu: gpu)
        meadow = MeadowDrawer(gpu: gpu)
        village = VillageDrawer(gpu: gpu)
        arenas = (0..<Self.inFlight).map { _ in Arena(device: device, size: 4 << 20) }
        frameBuffers = (0..<Self.inFlight).map { _ in device.makeBuffer(length: MemoryLayout<FrameUniforms>.stride, options: .storageModeShared)! }
        worldBuffers = (0..<Self.inFlight).map { _ in device.makeBuffer(length: WorldUniforms.byteCount, options: .storageModeShared)! }
    }

    private func attachments(width: Int, height: Int, memoryless: Bool) {
        if targetSize == (width, height), msaaColor != nil { return }
        targetSize = (width, height)
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: gpu.colorFormat, width: width, height: height, mipmapped: false)
        d.textureType = .type2DMultisample
        d.sampleCount = gpu.sampleCount
        d.usage = .renderTarget
        d.storageMode = memoryless ? .memoryless : .private
        msaaColor = gpu.device.makeTexture(descriptor: d)
        msaaColor?.label = "msaa colour"
        d.pixelFormat = .depth32Float
        msaaDepth = gpu.device.makeTexture(descriptor: d)
        msaaDepth?.label = "msaa depth"
    }

    /// Encodes one frame of `stage` into `commandBuffer`, resolving into `target`. The caller has waited
    /// on `semaphore` and signals it when the command buffer completes. `pointScale` is target pixels per
    /// point, for things measured in screen pixels.
    func encode(_ stage: Stage, into commandBuffer: MTLCommandBuffer, target: MTLTexture, pointScale: Float) {
        prepare(stage, into: commandBuffer, width: target.width, height: target.height, pointScale: pointScale)
        encodePass(stage, into: commandBuffer, target: target)
    }

    private var F = FrameUniforms()
    /// Kept and refilled each frame rather than made anew.
    private let pass = MTLRenderPassDescriptor()
    /// Milliseconds the last `prepare` spent posing cats.
    var poseMilliseconds: Double { cats.poseMilliseconds }

    /// Everything that does not need the drawable: uniforms, cat skins, the plants' compute pass. Done
    /// first, so the drawable is asked for only when the pass is about to be encoded and waiting for one
    /// never holds up the main thread longer than it must.
    func prepare(_ stage: Stage, into commandBuffer: MTLCommandBuffer, width: Int, height: Int, pointScale: Float) {
        slot = (slot + 1) % Self.inFlight
        let arena = arenas[slot]
        arena.reset()
        arena.releaseRetired()
        attachments(width: width, height: height, memoryless: true)

        // Uniforms.
        let aspect = Float(width) / Float(max(height, 1))
        let camera = stage.camera
        let proj = camera.projection(aspect: aspect), view = camera.viewMatrix, vp = proj * view
        let l = stage.light
        F = FrameUniforms()
        F.viewProj = vp; F.view = view; F.proj = proj; F.invViewProj = vp.inverse
        F.eye = Vec4(camera.eye, stage.meadowTime)
        let misty = stage.settings.weather?.sky == .fog
        // Fog starts beyond whatever you are looking at, so zooming out never washes the cats out.
        let fogOn = stage.mode == .meadow
        F.fog = Vec4(fogOn ? camera.view.distance + (misty ? 5 : 30) : 1e6, fogOn ? camera.view.distance + (misty ? 85 : 210) : 2e6, l.wind, l.night)
        F.hemiSky = Vec4(l.hemiSky, 0); F.hemiGround = Vec4(l.hemiGround, 0)
        F.keyColor = Vec4(l.keyColor, 0); F.keyDir = Vec4(l.keyDir, 0)
        F.rimColor = Vec4(l.rimColor, 0); F.rimDir = Vec4(l.rimDir, 0)
        F.turfLow = Vec4(l.turfLow, 0); F.turfHigh = Vec4(l.turfHigh, 0)
        F.horizon = Vec4(l.horizon, 0); F.skyTop = Vec4(l.skyTop, 0); F.skyMid = Vec4(l.skyMid, 0)
        F.viewport = Vec4(Float(width), Float(height), pointScale, 0)
        F.sky2 = Vec4(l.stars, 0, l.cloudGlow, l.night)
        let inv = view.inverse
        F.camRight = Vec4(simd_normalize(inv.direction(Vec3(1, 0, 0))), 0)
        F.camUp = Vec4(simd_normalize(inv.direction(Vec3(0, 1, 0))), 0)
        F.counts = Vec4(Float(stage.clearingCount), Float(stage.treeCount), Float(stage.streamCount), Float(stage.pathCount))
        frameBuffers[slot].contents().storeBytes(of: F, as: FrameUniforms.self)
        stage.world.write(to: worldBuffers[slot].contents())

        cats.pose(stage.cats, slot: slot, inFlight: Self.inFlight)
        if stage.mode == .meadow {
            meadow.prepare(stage, arena: arena, commandBuffer: commandBuffer, frame: frameBuffers[slot], world: worldBuffers[slot])
        }
    }

    /// The render pass itself, resolving into `target`.
    func encodePass(_ stage: Stage, into commandBuffer: MTLCommandBuffer, target: MTLTexture) {
        let arena = arenas[slot]
        let pass = self.pass
        pass.colorAttachments[0].texture = msaaColor
        pass.colorAttachments[0].resolveTexture = target
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .multisampleResolve
        pass.depthAttachment.texture = msaaDepth
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.clearDepth = 1
        pass.depthAttachment.storeAction = .dontCare
        guard let enc = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        enc.setVertexBuffer(frameBuffers[slot], offset: 0, index: 0)
        enc.setFragmentBuffer(frameBuffers[slot], offset: 0, index: 0)
        enc.setVertexBuffer(worldBuffers[slot], offset: 0, index: 2)
        enc.setVertexBuffer(gpu.placeholder, offset: 0, index: 4)
        enc.setFragmentBuffer(worldBuffers[slot], offset: 0, index: 2)
        enc.setFrontFacing(.counterClockwise)
        enc.setDepthStencilState(gpu.depthWrite)

        // Opaque, nearest things first so the rest is rejected early.
        cats.encodeOpaque(stage.cats, slot: slot, arena: arena, enc: enc)
        if stage.mode == .meadow {
            village.encodeOpaque(stage, arena: arena, enc: enc)
            meadow.encodeOpaque(stage, frame: F, arena: arena, enc: enc)
        }
        // The sky, only where nothing was drawn.
        enc.setCullMode(.none)
        enc.setDepthStencilState(gpu.depthRead)
        enc.setRenderPipelineState(gpu.sky)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        if stage.mode == .meadow { meadow.encodeSky(stage, arena: arena, enc: enc) }

        // See-through things.
        enc.setDepthStencilState(gpu.depthRead)
        if stage.mode == .meadow { village.encodeGround(stage, arena: arena, enc: enc) }
        cats.encodeShadows(stage.cats, arena: arena, enc: enc)
        enc.setDepthStencilState(gpu.depthRead)
        cats.encodeSteam(stage.cats, arena: arena, enc: enc)
        if stage.mode == .meadow {
            meadow.encodeSeeds(stage, arena: arena, enc: enc)
            village.encodeTransparent(stage, arena: arena, enc: enc)
        }
        enc.setDepthStencilState(gpu.depthRead)
        cats.encodeBubbles(stage.cats, alert: stage.settings.chrome.alert, arena: arena, enc: enc)
        if stage.mode == .meadow { village.encodeNotes(stage, arena: arena, enc: enc) }
        if stage.mode == .meadow {
            meadow.encodeParticles(stage, frame: F, arena: arena, enc: enc)
            // Whatever stands in the way, last of all (screens.ts FADED_ORDER).
            meadow.encodeFaded(stage, arena: arena, enc: enc)
        }
        enc.endEncoding()
    }

    /// Draws one frame into a new image, for tests and comparisons.
    func image(_ stage: Stage, width: Int, height: Int, pointScale: Float = 2) -> CGImage? {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: gpu.colorFormat, width: width, height: height, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .managed
        guard let target = gpu.device.makeTexture(descriptor: d), let cb = gpu.queue.makeCommandBuffer() else { return nil }
        semaphore.wait()
        encode(stage, into: cb, target: target, pointScale: pointScale)
        if let blit = cb.makeBlitCommandEncoder() { blit.synchronize(resource: target); blit.endEncoding() }
        cb.commit()
        cb.waitUntilCompleted()
        semaphore.signal()
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        target.getBytes(&bytes, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: cs, bitmapInfo: info,
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}
