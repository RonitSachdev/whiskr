import Foundation
@preconcurrency import Metal
import simd

// Draws the meadow: ground, grass, flowers, mushrooms, stones, saplings, trees, the log, hills, clouds,
// the sky's moon and stars, streams, butterflies and bees, seeds, rain and snow, fireflies, and whatever
// stands in the way faded to see-through (screens.ts: depth first, then colour on its nearest surface).

final class MeadowDrawer {
    private let gpu: GPU
    private var built = false
    private var groundVerts: MTLBuffer!, groundIndex: MTLBuffer!, groundIndexCount = 0
    private var bladeVerts: [MTLBuffer] = [], bladeIndex: [MTLBuffer] = [], bladeIndexCount: [Int] = []
    private var tufts: MTLBuffer!
    private var chunks: [GrassField.Chunk] = []
    private var plantMeshes: [Mesh] = []
    /// This frame's rooted plants: every instance in one block of the arena, with what each knows about
    /// where it stands beside it (`rootKernel`), and the draws over them.
    private struct RootedDraw { var mesh: Int; var first: Int; var count: Int; var faded: Bool }
    private var rootedDraws: [RootedDraw] = []
    private var rooted: (buffer: MTLBuffer, offset: Int)?
    private var roots: (buffer: MTLBuffer, offset: Int)?
    private var trees: [Mesh] = []
    private var log: Mesh!
    private var sphere: Mesh!, cloudBall: Mesh!, moon: Mesh!, drop: Mesh!, seed: Mesh!
    private var butterflyBody: Mesh!, butterflyWing: Mesh!, beeBody: Mesh!, beeWing: Mesh!
    private var stars: MTLBuffer!
    private var water: MTLBuffer?
    private var waterIndex: MTLBuffer?
    private var waterIndexCount = 0
    private var waterVersion = -1
    private var planes = [Vec4](repeating: .zero, count: 6)

    init(gpu: GPU) { self.gpu = gpu }

    private func build(_ m: Meadow) {
        built = true
        // Ground: Meadow.ts buildGround, 800 × 800 in 160 segments, with the level middle and rolling edge.
        var gv: [Float] = [], gi: [UInt32] = []
        let segs = 160, size: Double = 800
        let step = size / Double(segs)
        var h = [[Double]](repeating: [Double](repeating: 0, count: segs + 1), count: segs + 1)
        for j in 0...segs { for i in 0...segs { h[j][i] = Land.height(-size / 2 + step * Double(i), -size / 2 + step * Double(j)) } }
        for j in 0...segs {
            for i in 0...segs {
                let x = -size / 2 + step * Double(i), z = -size / 2 + step * Double(j)
                let hl = h[j][max(i - 1, 0)], hr = h[j][min(i + 1, segs)], hd = h[max(j - 1, 0)][i], hu = h[min(j + 1, segs)][i]
                let n = simd_normalize(SIMD3<Double>(hl - hr, 2 * step, hd - hu))
                gv += [Float(x), Float(h[j][i]), Float(z), Float(n.x), Float(n.y), Float(n.z)]
            }
        }
        for j in 0..<segs {
            for i in 0..<segs {
                let a = UInt32(j * (segs + 1) + i), b = a + 1, c = a + UInt32(segs + 1), d = c + 1
                gi += [a, c, b, b, c, d]
            }
        }
        groundVerts = gpu.buffer(gv, label: "ground"); groundIndex = gpu.buffer(gi, label: "ground index"); groundIndexCount = gi.count

        for band in GrassField.bands {
            let shape = GrassField.tuft(band.levels)
            bladeVerts.append(gpu.buffer(shape.vertices, label: "blades"))
            bladeIndex.append(gpu.buffer(shape.indices, label: "blade index"))
            bladeIndexCount.append(shape.indices.count)
        }
        tufts = gpu.buffer(m.grass.tufts, label: "tufts")
        chunks = m.grass.chunks

        plantMeshes = m.plants.map { gpu.mesh($0.shape.roughness.isEmpty ? $0.shape.roughened(0.8) : $0.shape, label: "plant") }
        rootedDraws.reserveCapacity(m.beds.count * 2)
        trees = m.treeShapes.map { gpu.mesh($0.shape, label: "tree") }
        log = gpu.mesh(m.logShape, label: "log")
        sphere = gpu.mesh(Shapes.sphere(1, 32, 16).colored(0xffffff, roughness: 1), label: "hill")
        cloudBall = gpu.mesh(Shapes.sphere(1, 20, 14).colored(0xffffff, roughness: 1), label: "cloud")
        moon = gpu.mesh(Shapes.sphere(16, 24, 16).colored(0xfff6d8, roughness: 1), label: "moon")
        drop = gpu.mesh(Shapes.sphere(1, 6, 4).colored(0xffffff, roughness: 1), label: "drop")
        seed = gpu.mesh(Critters.seed.colored(0xffffff, roughness: 1), label: "seed")
        butterflyBody = gpu.mesh(Critters.butterflyBody, label: "butterfly")
        butterflyWing = gpu.mesh(Critters.butterflyWing.colored(0xffffff, roughness: 0.8), label: "wing")
        beeBody = gpu.mesh(Critters.beeBody, label: "bee")
        beeWing = gpu.mesh(Critters.beeWing.colored(0xffffff, roughness: 1), label: "bee wing")
        stars = gpu.buffer(m.stars.flatMap { [$0.x, $0.y, $0.z] }, label: "stars")
    }

    private func draw(_ mesh: Mesh, _ instances: Int, _ enc: MTLRenderCommandEncoder) {
        enc.setVertexBuffer(mesh.vertices, offset: 0, index: 1)
        enc.drawIndexedPrimitives(type: .triangle, indexCount: mesh.indexCount, indexType: .uint32, indexBuffer: mesh.indices, indexBufferOffset: 0, instanceCount: instances)
    }
    private func instances(_ arena: Arena, _ list: UnsafeBufferPointer<ClayInstance>, _ enc: MTLRenderCommandEncoder) {
        let a = arena.alloc(ClayInstance.self, list.count)
        a.pointer.update(from: list.baseAddress!, count: list.count)
        enc.setVertexBuffer(a.buffer, offset: a.offset, index: 3)
    }
    private func one(_ arena: Arena, _ inst: ClayInstance, _ enc: MTLRenderCommandEncoder) {
        let a = arena.alloc(ClayInstance.self, 1)
        a.pointer[0] = inst
        enc.setVertexBuffer(a.buffer, offset: a.offset, index: 3)
    }

    /// Frustum planes from viewProj (Metal clip space, z 0…1).
    private func frustum(_ m: Mat4) {
        let r0 = Vec4(m.columns.0.x, m.columns.1.x, m.columns.2.x, m.columns.3.x)
        let r1 = Vec4(m.columns.0.y, m.columns.1.y, m.columns.2.y, m.columns.3.y)
        let r2 = Vec4(m.columns.0.z, m.columns.1.z, m.columns.2.z, m.columns.3.z)
        let r3 = Vec4(m.columns.0.w, m.columns.1.w, m.columns.2.w, m.columns.3.w)
        planes[0] = r3 + r0; planes[1] = r3 - r0; planes[2] = r3 + r1; planes[3] = r3 - r1; planes[4] = r2; planes[5] = r3 - r2
    }
    /// Whether a square of the column's strip of grass is within the levelled ground round a blanket.
    private func nearBlankets(_ c: GrassField.Chunk, _ stage: Stage) -> Bool {
        let half = Float(GrassField.chunk / 2)
        for i in 0..<stage.clearingCount {
            let k = stage.world.clearings[i]
            let dx = max(abs(k.x - c.center.x) - half, 0), dz = max(abs(k.y - c.center.y) - half, 0)
            if hypot(dx, dz) < max(k.z, 0) + Land.flat + Land.blend { return true }
        }
        return false
    }

    private func visible(_ lo: Vec3, _ hi: Vec3) -> Bool {
        for p in planes {
            let v = Vec3(p.x >= 0 ? hi.x : lo.x, p.y >= 0 ? hi.y : lo.y, p.z >= 0 ? hi.z : lo.z)
            if simd_dot(Vec3(p.x, p.y, p.z), v) + p.w < 0 { return false }
        }
        return true
    }

    // MARK: opaque

    func encodeOpaque(_ stage: Stage, frame F: FrameUniforms, arena: Arena, enc: MTLRenderCommandEncoder) {
        guard let m = stage.meadow else { return }
        if !built { build(m) }
        frustum(F.viewProj)
        let eye = stage.camera.eye

        // Plants: flowers, mushrooms, stones, and the saplings that are not faded.
        enc.setRenderPipelineState(gpu.clay)
        enc.setCullMode(.back)
        enc.setDepthStencilState(gpu.depthWrite)
        if !debugSkip.contains("plants") { drawRooted(faded: false, enc) }
        // Trees and the log, unless faded.
        for (i, tree) in m.treeShapes.enumerated() where m.screens[tree.screen].fade >= 0.999 {
            one(arena, ClayInstance(.translation(m.treeAt(i, stage.world.clearings, stage.clearingCount)), lit: []), enc)
            draw(trees[i], 1, enc)
        }
        if m.screens[m.logScreen].fade >= 0.999 {
            one(arena, ClayInstance(m.logMatrix, lit: .shaded), enc)
            draw(log, 1, enc)
        }
        // Hills, far off.
        let hills = arena.alloc(ClayInstance.self, m.hills.count)
        for (i, h) in m.hills.enumerated() {
            hills.pointer[i] = ClayInstance(m.hill(i, stage.world.clearings, stage.clearingCount), tint: Vec4(h.1, 1), roughness: 1, lit: [])
        }
        enc.setVertexBuffer(hills.buffer, offset: hills.offset, index: 3)
        draw(sphere, m.hills.count, enc)

        // Butterflies and bees.
        encodeCritters(m, arena: arena, enc: enc)

        // Streams between machines.
        encodeWater(stage, enc: enc)

        // Grass, then the ground it grows from, so the ground's costly pixels hidden by blades are never
        // shaded. One instanced draw per visible square, thinned by distance (grass.ts).
        enc.setCullMode(.none)
        if !debugSkip.contains("grass") {
            enc.setRenderPipelineState(gpu.grass)
            enc.setVertexBuffer(tufts, offset: 0, index: 3)
            var bound = -1
            for c in chunks where (!c.column || nearBlankets(c, stage)) && visible(c.bounds.min, c.bounds.max + Vec3(2, 0, 2)) {
                if bound != c.band { enc.setVertexBuffer(bladeVerts[c.band], offset: 0, index: 1); bound = c.band }
                enc.drawIndexedPrimitives(type: .triangle, indexCount: bladeIndexCount[c.band], indexType: .uint16, indexBuffer: bladeIndex[c.band],
                                          indexBufferOffset: 0, instanceCount: c.kept(eye: eye), baseVertex: 0, baseInstance: c.first)
            }
        }
        if !debugSkip.contains("ground") {
            enc.setRenderPipelineState(gpu.ground)
            enc.setVertexBuffer(groundVerts, offset: 0, index: 1)
            enc.drawIndexedPrimitives(type: .triangle, indexCount: groundIndexCount, indexType: .uint32, indexBuffer: groundIndex, indexBufferOffset: 0)
        }
        enc.setCullMode(.back)
    }

    /// Gathers this frame's rooted plants and works out, once per plant, what its vertices share.
    /// Encoded before the render pass.
    func prepare(_ stage: Stage, arena: Arena, commandBuffer: MTLCommandBuffer, frame: MTLBuffer, world: MTLBuffer) {
        guard let m = stage.meadow else { return }
        if !built { build(m) }
        rootedDraws.removeAll(keepingCapacity: true)
        var total = 0
        for bed in m.beds { total += bed.matrices.count }
        let inst = arena.alloc(ClayInstance.self, total)
        let info = arena.alloc(Vec4.self, total * 2)
        var n = 0
        for bed in m.beds {
            if let screens = bed.screens {
                // Saplings: the solid ones, then those faded because they stand in the way.
                for faded in [false, true] {
                    let first = n
                    for (i, matrix) in bed.matrices.enumerated() where (m.screens[screens[i]].fade < 0.999) == faded {
                        inst.pointer[n] = ClayInstance(matrix, tint: Vec4(1, 1, 1, m.screens[screens[i]].fade), sway: bed.sway, lit: .rooted)
                        n += 1
                    }
                    if n > first { rootedDraws.append(RootedDraw(mesh: bed.plant, first: first, count: n - first, faded: faded)) }
                }
            } else {
                let first = n
                for matrix in bed.matrices { inst.pointer[n] = ClayInstance(matrix, sway: bed.sway, lit: .rooted); n += 1 }
                rootedDraws.append(RootedDraw(mesh: bed.plant, first: first, count: n - first, faded: false))
            }
        }
        rooted = (inst.buffer, inst.offset)
        roots = (info.buffer, info.offset)
        guard n > 0, let compute = commandBuffer.makeComputeCommandEncoder() else { return }
        compute.setComputePipelineState(gpu.rootKernel)
        compute.setBuffer(frame, offset: 0, index: 0)
        compute.setBuffer(world, offset: 0, index: 2)
        compute.setBuffer(inst.buffer, offset: inst.offset, index: 3)
        compute.setBuffer(info.buffer, offset: info.offset, index: 4)
        var count = UInt32(n)
        compute.setBytes(&count, length: 4, index: 5)
        compute.dispatchThreads(MTLSize(width: n, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 64, height: 1, depth: 1))
        compute.endEncoding()
    }

    private func drawRooted(faded: Bool, _ enc: MTLRenderCommandEncoder) {
        guard let rooted, let roots else { return }
        for d in rootedDraws where d.faded == faded {
            enc.setVertexBuffer(rooted.buffer, offset: rooted.offset + d.first * MemoryLayout<ClayInstance>.stride, index: 3)
            enc.setVertexBuffer(roots.buffer, offset: roots.offset + d.first * 32, index: 4)
            draw(plantMeshes[d.mesh], d.count, enc)
        }
        enc.setVertexBuffer(gpu.placeholder, offset: 0, index: 4)
    }

    private func encodeCritters(_ m: Meadow, arena: Arena, enc: MTLRenderCommandEncoder) {
        let flyers = m.critters.flyers
        let bodies = arena.alloc(ClayInstance.self, flyers.count)
        let wings = arena.alloc(ClayInstance.self, flyers.count * 2)
        var nb = 0, nw = 0
        // Butterflies: body, then two wings hinged at it, flapping about the body's long axis.
        for f in flyers where !f.bee {
            let base = Mat4.translation(f.body) * .rotationY(f.heading)
            bodies.pointer[nb] = ClayInstance(base, lit: []); nb += 1
            for side: Float in [1, -1] {
                wings.pointer[nw] = ClayInstance(base * .rotationZ(side * f.wing) * .scale(Vec3(side, 1, 1)), tint: Vec4(linear(f.color), 1), roughness: 0.8, lit: .twoSided)
                nw += 1
            }
        }
        if nb > 0 {
            enc.setVertexBuffer(bodies.buffer, offset: bodies.offset, index: 3)
            draw(butterflyBody, nb, enc)
            enc.setCullMode(.none)
            enc.setVertexBuffer(wings.buffer, offset: wings.offset, index: 3)
            draw(butterflyWing, nw, enc)
            enc.setCullMode(.back)
        }
        let bees = arena.alloc(ClayInstance.self, flyers.count)
        var n = 0
        for f in flyers where f.bee {
            bees.pointer[n] = ClayInstance(.translation(f.body) * .rotationY(f.heading), lit: []); n += 1
        }
        if n > 0 {
            enc.setVertexBuffer(bees.buffer, offset: bees.offset, index: 3)
            draw(beeBody, n, enc)
        }
    }

    /// Seeds riding the breeze: unlit white by day, fading to the moonlight at night. Drawn after everything
    /// solid and before the flags and bubbles, without marking depth, so they drift behind a name or a
    /// bubble whichever side of it they are, and still behind cats, plants and ground.
    func encodeSeeds(_ stage: Stage, arena: Arena, enc: MTLRenderCommandEncoder) {
        guard let m = stage.meadow, built else { return }
        let seeds = arena.alloc(ClayInstance.self, m.critters.seeds.count)
        let dim = 1 - 0.9 * stage.light.night
        for (i, s) in m.critters.seeds.enumerated() { seeds.pointer[i] = ClayInstance(.translation(s), tint: Vec4(dim, dim, dim, 1), lit: .unlit) }
        enc.setDepthStencilState(gpu.depthRead)
        enc.setCullMode(.back)
        enc.setRenderPipelineState(gpu.clayBlend)
        enc.setVertexBuffer(seeds.buffer, offset: seeds.offset, index: 3)
        draw(seed, m.critters.seeds.count, enc)
    }

    private func encodeWater(_ stage: Stage, enc: MTLRenderCommandEncoder) {
        guard let village = stage.village else { return }
        if waterVersion != village.layoutVersion {
            waterVersion = village.layoutVersion
            // A ribbon along each stream, a little above the ground so the banks frame it.
            var v: [Float] = [], idx: [UInt32] = []
            for s in village.streams {
                var z: Float = -170
                let base = UInt32(v.count / 5)
                var rows: UInt32 = 0
                while z <= 170 {
                    let x = s.x + s.y * sin(z * 0.045 + s.z) + s.y * 0.4 * sin(z * 0.11 + s.z * 1.7)
                    for side: Float in [-1, 1] {
                        let px = x + side * (s.w + 0.25)
                        v += [px, Land.height(px, z) + 0.02, z, side, z]
                    }
                    rows += 1
                    z += 1
                }
                for r in 0..<(rows - 1) {
                    let a = base + r * 2
                    idx += [a, a + 2, a + 1, a + 1, a + 2, a + 3]
                }
            }
            water = v.isEmpty ? nil : gpu.buffer(v, label: "water")
            waterIndex = idx.isEmpty ? nil : gpu.buffer(idx, label: "water index")
            waterIndexCount = idx.count
        }
        guard let water, let waterIndex else { return }
        enc.setCullMode(.none)
        enc.setRenderPipelineState(gpu.water)
        enc.setVertexBuffer(water, offset: 0, index: 1)
        enc.drawIndexedPrimitives(type: .triangle, indexCount: waterIndexCount, indexType: .uint32, indexBuffer: waterIndex, indexBufferOffset: 0)
        enc.setCullMode(.back)
    }

    // MARK: sky

    /// Clouds (they never fog), the moon and the stars, after the sky.
    func encodeSky(_ stage: Stage, arena: Arena, enc: MTLRenderCommandEncoder) {
        guard let m = stage.meadow else { return }
        let l = stage.light
        enc.setDepthStencilState(gpu.depthWrite)
        enc.setRenderPipelineState(gpu.clay)
        enc.setCullMode(.back)
        let clouds = arena.alloc(ClayInstance.self, m.clouds.count)
        let turn = Mat4.rotationY(m.cloudTurn)
        let glow = linear(0xfff4e6) * l.cloudGlow
        for (i, c) in m.clouds.enumerated() { clouds.pointer[i] = ClayInstance(turn * c, emissive: glow, roughness: 1, lit: .noFog) }
        enc.setVertexBuffer(clouds.buffer, offset: clouds.offset, index: 3)
        draw(cloudBall, m.clouds.count, enc)
        // Stars and the moon fade in with the dark, unless cloud is hiding them.
        if l.stars > 0.02 {
            enc.setDepthStencilState(gpu.depthRead)
            enc.setRenderPipelineState(gpu.stars)
            enc.setVertexBuffer(stars, offset: 0, index: 1)
            enc.drawPrimitives(type: .point, vertexStart: 0, vertexCount: m.stars.count)
            enc.setRenderPipelineState(gpu.clayBlend)
            one(arena, ClayInstance(.translation(stage.camera.eye + Vec3(-150, 190, -320)), tint: Vec4(1, 1, 1, l.stars), lit: [.unlit, .noFog]), enc)
            draw(moon, 1, enc)
        }
    }

    // MARK: see-through

    /// Whatever stands in the way, faded: first its depth alone, then its colour blended on its nearest
    /// surface, so a crown of overlapping clumps fades as one soft shape.
    func encodeFaded(_ stage: Stage, arena: Arena, enc: MTLRenderCommandEncoder) {
        guard let m = stage.meadow, built else { return }
        enc.setCullMode(.back)
        for pass in 0..<2 {
            enc.setRenderPipelineState(pass == 0 ? gpu.clayDepth : gpu.clayFade)
            enc.setDepthStencilState(pass == 0 ? gpu.depthWrite : gpu.depthEqual)
            for (i, tree) in m.treeShapes.enumerated() where m.screens[tree.screen].fade < 0.999 {
                one(arena, ClayInstance(.translation(m.treeAt(i, stage.world.clearings, stage.clearingCount)), tint: Vec4(1, 1, 1, m.screens[tree.screen].fade), lit: []), enc)
                draw(trees[i], 1, enc)
            }
            if m.screens[m.logScreen].fade < 0.999 {
                one(arena, ClayInstance(m.logMatrix, tint: Vec4(1, 1, 1, m.screens[m.logScreen].fade), lit: .shaded), enc)
                draw(log, 1, enc)
            }
            drawRooted(faded: true, enc)
        }
        enc.setDepthStencilState(gpu.depthRead)
    }

    /// Bee wings, rain or snow, and the fireflies round the picnics.
    func encodeParticles(_ stage: Stage, frame F: FrameUniforms, arena: Arena, enc: MTLRenderCommandEncoder) {
        guard let m = stage.meadow, built else { return }
        enc.setDepthStencilState(gpu.depthRead)
        // Bee wings: glassy, a blur of motion.
        let flyers = m.critters.flyers
        let wings = arena.alloc(ClayInstance.self, flyers.count * 2)
        var n = 0
        for f in flyers where f.bee {
            let base = Mat4.translation(f.body) * .rotationY(f.heading)
            for side: Float in [1, -1] {
                wings.pointer[n] = ClayInstance(base * .scale(Vec3(side, 1, f.wing)), tint: Vec4(1, 1, 1, 0.6), lit: [.unlit, .twoSided]); n += 1
            }
        }
        enc.setCullMode(.none)
        enc.setRenderPipelineState(gpu.clayBlend)
        if n > 0 { enc.setVertexBuffer(wings.buffer, offset: wings.offset, index: 3); draw(beeWing, n, enc) }

        if m.falling {
            let l = stage.light
            let drops = arena.alloc(ClayInstance.self, m.drops.count)
            let tilt = Mat4.rotationZ(-0.13 * l.wind)
            let alpha: Float = m.snowing ? 0.95 : 0.55
            for (i, d) in m.drops.enumerated() {
                let model: Mat4 = m.snowing ? .translation(d) * .scale(0.07) : .translation(d) * tilt * .scale(Vec3(0.018, 0.42, 0.018))
                drops.pointer[i] = ClayInstance(model, tint: Vec4(l.dropColor, alpha), lit: [.unlit, .noFog])
            }
            enc.setVertexBuffer(drops.buffer, offset: drops.offset, index: 3)
            draw(drop, m.drops.count, enc)
        }
        enc.setCullMode(.back)

        if stage.light.night > 0.01 {
            let flies = arena.alloc(Vec4.self, m.fireflies.count)
            var k = 0
            for f in m.fireflies where f.w > 0 { flies.pointer[k] = f; k += 1 }
            if k > 0 {
                enc.setRenderPipelineState(gpu.firefly)
                enc.setVertexBuffer(flies.buffer, offset: flies.offset, index: 1)
                enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: k)
            }
        }
    }
}
