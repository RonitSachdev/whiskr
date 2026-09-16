import AppKit
@preconcurrency import Metal
import simd

// Pictures of things of the scenery, drawn by the scene itself in its clay (the editor's tray): one thing (or
// a little clump of several kinds, as the Brush's wildflowers) standing on a small round of grass, lit as on a
// clear day, seen from a little above and to one side, on a background the caller gives (the tile's colour in
// the theme), so the edges are smooth on it. Trees are the Default's own (the first of each kind), so the tray
// shows the meadow people know. A ground paint is pictured as a round of the meadow's own turf, its ground and
// grass drawn by the meadow's shaders from a little ground map of its own: a path worn across it, a lawn mown
// within a rim of long grass, a bed of soil in it, or the long grass alone.

final class Portraits {
    private let gpu: GPU
    private let frame: MTLBuffer
    private let world: MTLBuffer
    private var targets: (pixels: Int, color: MTLTexture, depth: MTLTexture, resolve: MTLTexture)?
    /// Shapes made for pictures, kept: drawing one again makes nothing.
    private var meshes: [ShapeKey: Mesh] = [:]
    private var sods: [Int: Mesh] = [:]
    /// A painted turf's pieces, made when first pictured: its ground map (one texture, painted again for each
    /// paint: pictures are drawn one at a time), its ground's disc, and its grass.
    private var turf: (map: MTLTexture, ground: MTLBuffer, groundIndex: MTLBuffer, groundCount: Int, blades: MTLBuffer, bladeIndex: MTLBuffer,
                       bladeCount: Int, tufts: MTLBuffer, tuftCount: Int)?

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
    /// One ground paint's id pictures that paint on a round of turf.
    func image(of ids: [String], pixels: Int, background: MeadowColor) -> CGImage? {
        if ids.count == 1, let paint = MeadowScenery.Ground.Paint(id: ids[0]) { return image(of: paint, pixels: pixels, background: background) }
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

        return draw(pixels: pixels, background: background, pitch: 22, boxes: shapes.map { ($0.mesh.bounds, $0.matrix) } + [(sod.bounds, sodMatrix)]) { enc in
            enc.setRenderPipelineState(self.gpu.clay)
            enc.setCullMode(.back)
            for (shape, matrix) in [(sod, sodMatrix)] + shapes.map({ ($0.mesh, $0.matrix) }) {
                var instance = ClayInstance(matrix, lit: [])
                enc.setVertexBytes(&instance, length: MemoryLayout<ClayInstance>.stride, index: 3)
                enc.setVertexBuffer(shape.vertices, offset: 0, index: 1)
                enc.drawIndexedPrimitives(type: .triangle, indexCount: shape.indexCount, indexType: .uint32, indexBuffer: shape.indices, indexBufferOffset: 0)
            }
        }
    }

    /// A picture `pixels` square over `background`, seen from 34° to the side and `pitch` degrees above, square
    /// on to the picture (no perspective at this size), framed to fill it with a little room round what `boxes`
    /// hold (bounds, as placed); `encode` draws into it, the frame and an empty world bound, and `map` as the
    /// ground's map.
    private func draw(pixels: Int, background: MeadowColor, pitch degrees: Float, boxes: [((min: Vec3, max: Vec3), Mat4)], map: MTLTexture? = nil,
                      _ encode: (MTLRenderCommandEncoder) -> Void) -> CGImage? {
        let bearing: Float = 34 * .pi / 180, pitch: Float = degrees * .pi / 180
        let toward = Vec3(sin(bearing) * cos(pitch), sin(pitch), cos(bearing) * cos(pitch))
        let look = Mat4.lookAt(eye: toward * 100, target: .zero)
        var low = Vec3(repeating: .infinity), high = Vec3(repeating: -.infinity)
        for (bounds, m) in boxes {
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
        enc.setDepthStencilState(gpu.depthWrite)
        enc.setFrontFacing(.counterClockwise)
        enc.setVertexBuffer(frame, offset: 0, index: 0)
        enc.setFragmentBuffer(frame, offset: 0, index: 0)
        enc.setVertexBuffer(world, offset: 0, index: 2)
        enc.setFragmentBuffer(world, offset: 0, index: 2)
        enc.setVertexBuffer(gpu.placeholder, offset: 0, index: 4)
        enc.setVertexTexture(map ?? gpu.blankGroundMap, index: 0)
        enc.setFragmentTexture(map ?? gpu.blankGroundMap, index: 0)
        // Pictured by day: no lamplight.
        enc.setVertexTexture(gpu.blankGroundMap, index: 1)
        enc.setFragmentTexture(gpu.blankGroundMap, index: 1)
        encode(enc)
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

    // MARK: painted turf

    /// How wide a painted turf's round is, in units: a path across it two strides wide, a lawn's stripe, a bed.
    static let turfRadius: Float = 3.2

    /// A paint (or the wild grass) on a round of the meadow's turf, seen from a little higher than a thing so
    /// the ground shows between the blades.
    private func image(of paint: MeadowScenery.Ground.Paint, pixels: Int, background: MeadowColor) -> CGImage? {
        guard pixels > 0, let turf = turf ?? makeTurf() else { return nil }
        self.turf = turf
        // The paint, in the map's cells round the middle (the map's own texels: the paint grid's cells and its margin).
        let r = Self.turfRadius
        let cells = Int((r / GroundMap.cell).rounded(.up)) + 2
        let middle = GroundMap.side / 2, width = 2 * cells
        var bytes = [UInt8](repeating: 0, count: width * width * 4)
        for row in 0..<width {
            for column in 0..<width {
                let p = GroundMap.middle(middle - cells + column, middle - cells + row)
                let channel: Int?
                switch paint {
                case .path: channel = abs(p.y - 0.35 * sin(p.x * 0.8)) < 0.95 ? 0 : nil
                case .lawn: channel = simd_length(p) < r * 0.92 ? 1 : nil
                case .soil: channel = simd_length(p * Vec2(0.8, 1.1)) < r * 0.64 ? 2 : nil
                case .wild: channel = nil
                }
                if let channel { bytes[(row * width + column) * 4 + channel] = 255 }
            }
        }
        turf.map.replace(region: MTLRegionMake2D(middle - cells, middle - cells, width, width), mipmapLevel: 0, withBytes: bytes, bytesPerRow: width * 4)

        let sodKey = Int((r * 20).rounded())
        let sod = sods[sodKey] ?? gpu.mesh(Self.sod(r), label: "portrait grass")
        sods[sodKey] = sod
        let ground = Float(Land.ground)
        let sodMatrix = Mat4.translation(Vec3(0, ground, 0))
        let blades = (min: Vec3(-r, ground, -r), max: Vec3(r, ground + 1.6, r))
        return draw(pixels: pixels, background: background, pitch: 38, boxes: [(sod.bounds, sodMatrix), (blades, .identity)], map: turf.map) { enc in
            enc.setRenderPipelineState(self.gpu.clay)
            enc.setCullMode(.back)
            var instance = ClayInstance(sodMatrix, lit: [])
            enc.setVertexBytes(&instance, length: MemoryLayout<ClayInstance>.stride, index: 3)
            enc.setVertexBuffer(sod.vertices, offset: 0, index: 1)
            enc.drawIndexedPrimitives(type: .triangle, indexCount: sod.indexCount, indexType: .uint32, indexBuffer: sod.indices, indexBufferOffset: 0)
            enc.setCullMode(.none)
            enc.setRenderPipelineState(self.gpu.grass)
            enc.setVertexBuffer(turf.blades, offset: 0, index: 1)
            enc.setVertexBuffer(turf.tufts, offset: 0, index: 3)
            enc.drawIndexedPrimitives(type: .triangle, indexCount: turf.bladeCount, indexType: .uint16, indexBuffer: turf.bladeIndex, indexBufferOffset: 0,
                                      instanceCount: turf.tuftCount)
            enc.setRenderPipelineState(self.gpu.ground)
            enc.setVertexBuffer(turf.ground, offset: 0, index: 1)
            enc.drawIndexedPrimitives(type: .triangle, indexCount: turf.groundCount, indexType: .uint32, indexBuffer: turf.groundIndex, indexBufferOffset: 0)
            enc.setCullMode(.back)
        }
    }

    /// A turf's pieces: a ground map with nothing on it, a disc of ground just over the sod's top, and tufts of
    /// the meadow's grass over it as thick as round the picnic ground, from a stream of their own.
    private func makeTurf() -> (map: MTLTexture, ground: MTLBuffer, groundIndex: MTLBuffer, groundCount: Int, blades: MTLBuffer, bladeIndex: MTLBuffer,
                                bladeCount: Int, tufts: MTLBuffer, tuftCount: Int)? {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: GroundMap.side, height: GroundMap.side, mipmapped: false)
        d.usage = .shaderRead
        d.storageMode = .shared
        guard let map = gpu.device.makeTexture(descriptor: d) else { return nil }
        map.replace(region: MTLRegionMake2D(0, 0, GroundMap.side, GroundMap.side), mipmapLevel: 0, withBytes: GroundMap().surface, bytesPerRow: GroundMap.side * 4)
        map.label = "portrait ground map"
        let r = Self.turfRadius * 0.97, y = Float(Land.ground) + 0.01, rings = 12, around = 48
        var vertices: [Float] = [0, y, 0, 0, 1, 0], indices: [UInt32] = []
        for ring in 1...rings {
            for k in 0..<around {
                let a = Float(k) / Float(around) * 2 * .pi, out = r * Float(ring) / Float(rings)
                vertices += [cos(a) * out, y, sin(a) * out, 0, 1, 0]
            }
        }
        for k in 0..<around {
            let next = (k + 1) % around
            indices += [0, UInt32(1 + next), UInt32(1 + k)]
            for ring in 1..<rings {
                let a = UInt32(1 + (ring - 1) * around + k), b = UInt32(1 + (ring - 1) * around + next)
                let c = a + UInt32(around), e = b + UInt32(around)
                indices += [a, b, c, b, e, c]
            }
        }
        var random = Seeded(0x7af)
        var tufts: [GrassField.Tuft] = []
        let count = Int((Float.pi * r * r * 5).rounded())
        while tufts.count < count {
            let x = (random.float() * 2 - 1) * r, z = (random.float() * 2 - 1) * r
            guard x * x + z * z < r * r * 0.96 else { continue }
            let tall = 0.95 + random.float() * 0.45, wide = 0.95 + random.float() * 0.5
            tufts.append(GrassField.Tuft(rootYaw: Vec4(x, y, z, random.float() * 2 * .pi), scale: Vec4(wide, tall, 0, 0)))
        }
        let blade = GrassField.tuft(GrassField.bands[0].levels)
        return (map, gpu.buffer(vertices, label: "portrait ground"), gpu.buffer(indices, label: "portrait ground index"), indices.count,
                gpu.buffer(blade.vertices, label: "portrait blades"), gpu.buffer(blade.indices, label: "portrait blade index"), blade.indices.count,
                gpu.buffer(tufts, label: "portrait tufts"), tufts.count)
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
