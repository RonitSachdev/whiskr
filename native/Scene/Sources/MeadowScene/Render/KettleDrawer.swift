@preconcurrency import Metal
import simd

// Draws each blanket's camp kettle (`Kettle.swift`): the stove and kettle, the lid (which rattles), the ring of
// flames, the little red flag of a failure, and, see-through, the steam, a snuffed flame's dark puff and the
// flame's glow after dark.

final class KettleDrawer {
    private let gpu: GPU
    private let body: Mesh
    private let lid: Mesh
    private let flame: Mesh
    private let flag: Mesh
    private let puff: Mesh

    init(gpu: GPU) {
        self.gpu = gpu
        body = gpu.mesh(Kettle.body(), label: "kettle")
        lid = gpu.mesh(Kettle.lid(), label: "kettle lid")
        flame = gpu.mesh(Kettle.flame(), label: "kettle flame")
        flag = gpu.mesh(Kettle.flag(), label: "kettle flag")
        puff = gpu.mesh(Shapes.sphere(1, 16, 10), label: "kettle steam")
    }

    private func draw(_ mesh: Mesh, _ instances: Int, _ enc: MTLRenderCommandEncoder) {
        enc.setVertexBuffer(mesh.vertices, offset: 0, index: 1)
        enc.drawIndexedPrimitives(type: .triangle, indexCount: mesh.indexCount, indexType: .uint32, indexBuffer: mesh.indices, indexBufferOffset: 0, instanceCount: instances)
    }
    private func one(_ arena: Arena, _ inst: ClayInstance, _ enc: MTLRenderCommandEncoder) {
        let a = arena.alloc(ClayInstance.self, 1)
        a.pointer[0] = inst
        enc.setVertexBuffer(a.buffer, offset: a.offset, index: 3)
    }

    /// The kettle's place in the world: on its blanket, turned its own way, at the size it is shown.
    static func model(_ plot: Plot) -> Mat4 {
        .translation(plot.group + plot.kettle.at) * .rotationY(plot.kettle.turn) * .scale(max(plot.kettle.shown.x, 0.001) * KETTLE_SIZE)
    }

    /// The flame's colour as it glows: a hot blue going warm at the tips, brighter at night.
    static let flameGlow = linear(0xffc766)

    func encodeOpaque(_ stage: Stage, arena: Arena, enc: MTLRenderCommandEncoder) {
        guard let village = stage.village else { return }
        enc.setRenderPipelineState(gpu.clay)
        enc.setDepthStencilState(gpu.depthWrite)
        enc.setCullMode(.back)
        let t = stage.time
        for plot in village.plots where plot.kettle.shown.x > 0.01 {
            let k = plot.kettle
            let model = Self.model(plot)
            one(arena, ClayInstance(model, lit: [.shaded, .glow]), enc)
            draw(body, 1, enc)
            // The lid, lifted off its seat and tipped about the spout's line while it rattles.
            let seat = Kettle.lidSeat
            let lidModel = model * .translation(seat + Vec3(0, k.lidLift, 0)) * .rotationZ(k.lidTip) * .translation(-seat)
            one(arena, ClayInstance(lidModel, lit: [.shaded, .glow]), enc)
            draw(lid, 1, enc)
            if k.flame > 0.01 {
                // A low ring of flames, licking up a little and never quite still (held still with the meadow).
                let lick = 1 + 0.12 * sin(t * 17) * sin(t * 6.3)
                let flameModel = model * .translation(Kettle.burner) * .scale(Vec3(0.75 + 0.25 * k.flame, k.flame * lick, 0.75 + 0.25 * k.flame))
                one(arena, ClayInstance(flameModel, emissive: Self.flameGlow * 0.25 * k.flame, lit: .unlit), enc)
                draw(flame, 1, enc)
            }
            if k.flag.x > 0.01 {
                one(arena, ClayInstance(model * .translation(Kettle.flagFoot) * .scale(Vec3(1, max(k.flag.x, 0.001), 1)), lit: [.shaded, .glow]), enc)
                draw(flag, 1, enc)
            }
        }
    }

    /// The stove's warm light spilling onto the blanket round the kettle while it burns: what says "on" from
    /// any height, by day and more so at night.
    func encodeGround(_ stage: Stage, arena: Arena, enc: MTLRenderCommandEncoder) {
        guard let village = stage.village else { return }
        var n = 0
        for plot in village.plots where plot.kettle.shown.x > 0.01 && plot.kettle.flame > 0.02 { _ = plot; n += 1 }
        guard n > 0 else { return }
        let night = stage.light.night
        let inst = arena.alloc(ShadowInstance.self, n)
        var k = 0
        let warm = linear(0xffa646)
        for plot in village.plots where plot.kettle.shown.x > 0.01 && plot.kettle.flame > 0.02 {
            let at = plot.group + plot.kettle.at
            let size = KETTLE_SIZE * 2.1 * plot.kettle.shown.x
            inst.pointer[k] = ShadowInstance(model: .translation(Vec3(at.x, 0.035, at.z)) * .scale(Vec3(1, 1, 1) * size),
                                             extra: Vec4(min(1, plot.kettle.flame * (0.95 + 0.3 * night)), warm.x, warm.y, warm.z))
            k += 1
        }
        enc.setRenderPipelineState(gpu.halo)
        enc.setDepthStencilState(gpu.depthRead)
        enc.setCullMode(.none)
        enc.setVertexBuffer(inst.buffer, offset: inst.offset, index: 3)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: n)
        enc.setCullMode(.back)
    }

    /// Steam and a snuffed flame's puff, see-through and unlit; then the flame's glow, added onto what is behind it.
    func encodeTransparent(_ stage: Stage, arena: Arena, enc: MTLRenderCommandEncoder) {
        guard let village = stage.village else { return }
        var n = 0, glows = 0
        for plot in village.plots where plot.kettle.shown.x > 0.01 {
            for a in plot.kettle.puffAlpha where a > 0.005 { _ = a; n += 1 }
            if plot.kettle.smokeAlpha > 0.005 { n += 1 }
            if plot.kettle.flame > 0.02 { glows += 1 }
        }
        let night = stage.light.night
        if n > 0 {
            let inst = arena.alloc(ClayInstance.self, n)
            var k = 0
            let steam = linear(0xfbfaf6), smoke = linear(0x4a4642)
            for plot in village.plots where plot.kettle.shown.x > 0.01 {
                let kettle = plot.kettle, model = Self.model(plot)
                for i in 0..<KETTLE_PUFFS where kettle.puffAlpha[i] > 0.005 {
                    let p = kettle.puffs[i]
                    // Lit as clay is, so a puff keeps a soft grey underside and reads on pale cloth as on grass.
                    inst.pointer[k] = ClayInstance(model * .translation(Vec3(p.x, p.y, p.z)) * .scale(p.w), tint: Vec4(steam, kettle.puffAlpha[i]), lit: .lambert)
                    k += 1
                }
                if kettle.smokeAlpha > 0.005 {
                    let s = kettle.smoke
                    inst.pointer[k] = ClayInstance(model * .translation(Vec3(s.x, s.y, s.z)) * .scale(s.w), tint: Vec4(smoke, kettle.smokeAlpha), lit: .unlit)
                    k += 1
                }
            }
            enc.setRenderPipelineState(gpu.clayBlend)
            enc.setDepthStencilState(gpu.depthRead)
            enc.setCullMode(.back)
            enc.setVertexBuffer(inst.buffer, offset: inst.offset, index: 3)
            draw(puff, k, enc)
        }
        if glows > 0 {
            let inst = arena.alloc(SpriteInstance.self, glows)
            var g = 0
            for plot in village.plots where plot.kettle.shown.x > 0.01 && plot.kettle.flame > 0.02 {
                let at = Self.model(plot).point(Kettle.burner + Vec3(0, 0.04, 0))
                let size = (0.7 + night * 0.9) * KETTLE_SIZE * plot.kettle.shown.x
                inst.pointer[g] = SpriteInstance(at: Vec4(at, plot.kettle.flame * (0.25 + 0.75 * night)), size: Vec4(size, size, 0.5, 0.5),
                                                 tint: Vec4(Self.flameGlow, 0), uv: Vec4(1, 0, 0, 0))
                g += 1
            }
            enc.setRenderPipelineState(gpu.glow)
            enc.setDepthStencilState(gpu.depthRead)
            enc.setCullMode(.none)
            enc.setVertexBuffer(inst.buffer, offset: inst.offset, index: 1)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: g)
            enc.setCullMode(.back)
        }
    }
}
