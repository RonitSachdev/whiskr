import AppKit
@preconcurrency import Metal
import simd

// Pictures of things of the scenery, drawn by the scene itself in its clay (the editor's tray): one thing (or
// a little clump of several kinds, as the Brush's wildflowers) standing on a small round of grass, lit as on a
// clear day, seen from a little above and to one side, on a background the caller gives (the tile's colour in
// the theme), so the edges are smooth on it. Trees are the Default's own (the first of each kind), so the tray
// shows the meadow people know.

final class Portraits {
    private let gpu: GPU
    private let frame: MTLBuffer
    private let world: MTLBuffer
    private var targets: (pixels: Int, color: MTLTexture, depth: MTLTexture, resolve: MTLTexture)?
    /// Shapes made for pictures, kept: drawing one again makes nothing.
    private var meshes: [ShapeKey: Mesh] = [:]
    private var sods: [Int: Mesh] = [:]

    init(gpu: GPU) {
        self.gpu = gpu
        frame = gpu.device.makeBuffer(length: MemoryLayout<FrameUniforms>.stride, options: .storageModeShared)!
        world = gpu.device.makeBuffer(length: WorldUniforms.byteCount, options: .storageModeShared)!
        WorldUniforms().write(to: world.contents())
    }

    /// What a picture of `ids` shows: one of each as the Default grows it (a tree the Default's first of its
    /// kind, a plant its first shape), turned a little toward the light; several stand in a little clump.
    static func sitters(_ ids: [String]) -> [MeadowScenery.Thing] {
        ids.enumerated().map { k, id in
            let seed = MeadowScenery.standard.things.first { $0.id == id }?.seed ?? 1
            let angle = Float(k) * 2.4 + 0.5, out: Float = ids.count > 1 ? 0.62 + 0.18 * Float(k % 2) : 0
            return MeadowScenery.Thing(id: id, x: cos(angle) * out, z: sin(angle) * out, turn: 0.6 + Float(k) * 1.9, seed: seed, variant: k / 4 % 2)
        }
    }

    /// The picture of `ids`, `pixels` square, over `background` (sRGB); nil when the scene draws none of them.
    func image(of ids: [String], pixels: Int, background: MeadowColor) -> CGImage? {
        let things = Self.sitters(ids)
        let shapes = things.compactMap { thing -> (thing: MeadowScenery.Thing, mesh: Mesh, matrix: Mat4)? in
            guard let alone = Meadow.alone(thing) else { return nil }
            let mesh = meshes[alone.key] ?? gpu.mesh(alone.make(), label: "portrait")
            meshes[alone.key] = mesh
            return (thing, mesh, alone.matrix)
        }
        guard pixels > 0, !shapes.isEmpty else { return nil }

        // The round of grass: a little wider than the ground they stand on (and than a plant's leaves), its
        // top just under them.
        let foot = shapes.flatMap { SceneryRules.footprint(of: $0.thing) }
        let reach = foot.map { hypot($0.x, $0.z) + $0.r }.max() ?? 1
        let spread = shapes.map { max(abs($0.mesh.bounds.min.x), abs($0.mesh.bounds.max.x), abs($0.mesh.bounds.min.z), abs($0.mesh.bounds.max.z)) + hypot($0.thing.x, $0.thing.z) }.max() ?? 1
        let sodRadius = max(reach * 1.3, min(spread * 1.1, reach * 3), 0.6)
        let sodKey = Int((sodRadius * 20).rounded())
        let sod = sods[sodKey] ?? gpu.mesh(Self.sod(sodRadius), label: "portrait grass")
        sods[sodKey] = sod
        let ground = Float(Land.ground)
        let sodMatrix = Mat4.translation(Vec3(0, ground, 0))

        // Seen from 34° to the side and 22° above, square on to the picture (no perspective at this size), and
        // framed to fill it with a little room round.
        let bearing: Float = 34 * .pi / 180, pitch: Float = 22 * .pi / 180
        let toward = Vec3(sin(bearing) * cos(pitch), sin(pitch), cos(bearing) * cos(pitch))
        let look = Mat4.lookAt(eye: toward * 100, target: .zero)
        var low = Vec3(repeating: .infinity), high = Vec3(repeating: -.infinity)
        for (bounds, m) in shapes.map({ ($0.mesh.bounds, $0.matrix) }) + [(sod.bounds, sodMatrix)] {
            for corner in 0..<8 {
                let c = Vec3(corner & 1 == 0 ? bounds.min.x : bounds.max.x, corner & 2 == 0 ? bounds.min.y : bounds.max.y,
                             corner & 4 == 0 ? bounds.min.z : bounds.max.z)
                let p = look.point(m.point(c))
                low = simd_min(low, p)
                high = simd_max(high, p)
            }
        }
        let half = max(high.x - low.x, high.y - low.y) / 2 * 1.1
        let middle = (low + high) / 2
        // Orthographic, from view space: x and y onto the square round the middle, depth 0…1 over the box.
        let near = -high.z - 1, far = -low.z + 1
        let proj = Mat4(columns: (Vec4(1 / half, 0, 0, 0), Vec4(0, 1 / half, 0, 0), Vec4(0, 0, -1 / (far - near), 0),
                                  Vec4(-middle.x / half, -middle.y / half, -near / (far - near), 1)))
        let view = look
        let eye = toward * 100

        let light = Light()
        var F = FrameUniforms()
        F.viewProj = proj * view; F.view = view; F.proj = proj; F.invViewProj = (proj * view).inverse
        F.eye = Vec4(eye, 0)
        F.fog = Vec4(1e6, 2e6, 0, 0)
        F.hemiSky = Vec4(light.hemiSky, 0); F.hemiGround = Vec4(light.hemiGround, 0)
        F.keyColor = Vec4(light.keyColor, 0); F.keyDir = Vec4(light.keyDir, 0)
        F.rimColor = Vec4(light.rimColor, 0); F.rimDir = Vec4(light.rimDir, 0)
        F.turfLow = Vec4(light.turfLow, 0); F.turfHigh = Vec4(light.turfHigh, 0)
        F.horizon = Vec4(light.horizon, 0); F.skyTop = Vec4(light.skyTop, 0); F.skyMid = Vec4(light.skyMid, 0)
        F.viewport = Vec4(Float(pixels), Float(pixels), 2, 0)
        frame.contents().storeBytes(of: F, as: FrameUniforms.self)

        guard let targets = targets(pixels), let cb = gpu.queue.makeCommandBuffer() else { return nil }
        let pass = MTLRenderPassDescriptor()
        let clear = background.linearRGB
        pass.colorAttachments[0].texture = targets.color
        pass.colorAttachments[0].resolveTexture = targets.resolve
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: Double(clear.x), green: Double(clear.y), blue: Double(clear.z), alpha: 1)
        pass.colorAttachments[0].storeAction = .multisampleResolve
        pass.depthAttachment.texture = targets.depth
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.clearDepth = 1
        pass.depthAttachment.storeAction = .dontCare
        guard let enc = cb.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        enc.setRenderPipelineState(gpu.clay)
        enc.setDepthStencilState(gpu.depthWrite)
        enc.setFrontFacing(.counterClockwise)
        enc.setCullMode(.back)
        enc.setVertexBuffer(frame, offset: 0, index: 0)
        enc.setFragmentBuffer(frame, offset: 0, index: 0)
        enc.setVertexBuffer(world, offset: 0, index: 2)
        enc.setFragmentBuffer(world, offset: 0, index: 2)
        enc.setVertexBuffer(gpu.placeholder, offset: 0, index: 4)
        enc.setVertexTexture(gpu.blankGroundMap, index: 0)
        enc.setFragmentTexture(gpu.blankGroundMap, index: 0)
        for (shape, matrix) in [(sod, sodMatrix)] + shapes.map({ ($0.mesh, $0.matrix) }) {
            var instance = ClayInstance(matrix, lit: [])
            enc.setVertexBytes(&instance, length: MemoryLayout<ClayInstance>.stride, index: 3)
            enc.setVertexBuffer(shape.vertices, offset: 0, index: 1)
            enc.drawIndexedPrimitives(type: .triangle, indexCount: shape.indexCount, indexType: .uint32, indexBuffer: shape.indices, indexBufferOffset: 0)
        }
        enc.endEncoding()
        if let blit = cb.makeBlitCommandEncoder() { blit.synchronize(resource: targets.resolve); blit.endEncoding() }
        cb.commit()
        cb.waitUntilCompleted()

        var bytes = [UInt8](repeating: 0, count: pixels * pixels * 4)
        targets.resolve.getBytes(&bytes, bytesPerRow: pixels * 4, from: MTLRegionMake2D(0, 0, pixels, pixels), mipmapLevel: 0)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB), let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        return CGImage(width: pixels, height: pixels, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: pixels * 4, space: space, bitmapInfo: info,
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// The textures a picture `pixels` square is drawn into, made once for each size.
    private func targets(_ pixels: Int) -> (pixels: Int, color: MTLTexture, depth: MTLTexture, resolve: MTLTexture)? {
        if let targets, targets.pixels == pixels { return targets }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: gpu.colorFormat, width: pixels, height: pixels, mipmapped: false)
        d.textureType = .type2DMultisample
        d.sampleCount = gpu.sampleCount
        d.usage = .renderTarget
        d.storageMode = .private
        guard let color = gpu.device.makeTexture(descriptor: d) else { return nil }
        d.pixelFormat = .depth32Float
        guard let depth = gpu.device.makeTexture(descriptor: d) else { return nil }
        let r = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: gpu.colorFormat, width: pixels, height: pixels, mipmapped: false)
        r.usage = [.renderTarget, .shaderRead]
        r.storageMode = .managed
        guard let resolve = gpu.device.makeTexture(descriptor: r) else { return nil }
        targets = (pixels, color, depth, resolve)
        return targets
    }

    /// A round of meadow turf `radius` across, its top at y = 0: a low, softly lumped cake of clay in the
    /// grass's own greens, a shade darker round its side.
    static func sod(_ radius: Float) -> Geometry {
        var turf = Clay.blob(at: Vec3(0, -radius * 0.2, 0), size: Vec3(radius, radius * 0.2, radius), color: 0x5f8f34, top: 0x9cc952, lumpy: 0.04)
        // Flattened just under the top, so things stand on level ground.
        for i in turf.positions.indices where turf.positions[i].y > -radius * 0.02 { turf.positions[i].y = -radius * 0.02 + (turf.positions[i].y + radius * 0.02) * 0.15 }
        turf.computeNormals()
        return turf.roughened(1)
    }
}

extension MeadowView {
    /// A picture of a kind of thing (a catalog id the scene draws), or of a little clump of several, drawn by
    /// the scene in its clay on a small round of grass, by day, over `background` (sRGB): for the editor's tray.
    /// `pixels` square (the tile's points times the screen's scale, so it is crisp). Nil when the scene draws
    /// none of them.
    public func portrait(of ids: [String], pixels: Int, background: MeadowColor) -> CGImage? {
        guard let renderer else { return nil }
        if portraits == nil { portraits = Portraits(gpu: renderer.gpu) }
        return portraits?.image(of: ids, pixels: pixels, background: background)
    }
}
