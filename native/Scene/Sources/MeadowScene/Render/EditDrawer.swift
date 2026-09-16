import Foundation
@preconcurrency import Metal
import simd

// Draws the editor's marks on the ground while the meadow is edited (`MeadowEditMarks`): a ring of the
// focus colour round each chosen thing's ground (and, for a tree, a second round where its crown shades the
// ground, so a chosen tree reads at a glance from any height), a dashed ring round one that may not stand
// where it is, a faint ring under the pointer, the keyboard's cursor, the ring under the thing about to be
// placed with a tick for which way it faces, the Brush's or the Eraser's circle, and the picnic ground's soft
// dashed outline. Each lies a little above the land, following it, drawn twice: where it is seen, whole,
// and where something stands in front of it (a crown, tall grass) faintly, so a mark is never lost behind
// what it marks.

final class EditDrawer {
    private let gpu: GPU

    init(gpu: GPU) { self.gpu = gpu }

    /// One outline to draw: a stadium (a circle when `half` is 0) round `center`, its long axis `along`.
    private struct Outline {
        var center: Vec2
        var along: Vec2
        var half: Float
        var r: Float
    }

    /// One batch of strips in one colour and strength.
    private struct Strip {
        var first: Int
        var count: Int
        var alpha: Float
    }

    func encode(_ stage: Stage, arena: Arena, enc: MTLRenderCommandEncoder) {
        guard stage.editing, let meadow = stage.meadow else { return }
        let marks = stage.editMarks
        let chrome = stage.settings.chrome
        let strong = marks.highContrast
        let things = meadow.scenery.things
        let clearings = stage.world.clearings, clearingCount = stage.clearingCount
        let eye = stage.camera.eye
        let tall = Swift.max(stage.camera.viewport.y, 1)
        /// World units per point of the view at a spot.
        func perPoint(_ x: Float, _ z: Float) -> Float { 2 * tan(MapCamera.fovY / 2) / tall * simd_distance(eye, Vec3(x, 0, z)) }

        // Vertices (position, normal, colour with roughness: the clay vertex) and indices, for everything.
        let capacity = 24_000
        let verts = arena.alloc(Float.self, capacity * 10)
        let index = arena.alloc(UInt32.self, capacity * 3)
        var vertexCount = 0, indexCount = 0
        var strips: [Strip] = []
        strips.reserveCapacity(8)

        func height(_ x: Float, _ z: Float, levelled: Float) -> Float {
            // The level middle needs no noise; past it, the land's own rise, brought down where a blanket levels it.
            let land = x * x + z * z <= Float(Land.level * Land.level) ? Float(Land.ground) : Land.height(x, z)
            return land + (Float(Land.ground) - land) * levelled
        }
        func vertex(_ p: Vec3, _ color: Vec3) {
            let b = vertexCount * 10
            verts.pointer[b] = p.x; verts.pointer[b + 1] = p.y; verts.pointer[b + 2] = p.z
            verts.pointer[b + 3] = 0; verts.pointer[b + 4] = 1; verts.pointer[b + 5] = 0
            verts.pointer[b + 6] = color.x; verts.pointer[b + 7] = color.y; verts.pointer[b + 8] = color.z; verts.pointer[b + 9] = 1
            vertexCount += 1
        }
        /// A closed path's points round an outline, `step` units apart at most.
        func path(_ o: Outline, _ out: Float, step: Float, _ each: (Vec2, Vec2) -> Void) {
            let r = o.r + out
            let arc = Swift.max(12, Int((Float.pi * r / step).rounded(.up)))
            let across = Vec2(-o.along.y, o.along.x)
            // One half round each end, joined by the straight sides.
            for end in 0..<2 {
                let sign: Float = end == 0 ? 1 : -1
                let middle = o.center + o.along * o.half * sign
                for k in 0...arc {
                    let a = -Float.pi / 2 + Float.pi * Float(k) / Float(arc)
                    let normal = (o.along * cos(a) + across * sin(a)) * sign
                    each(middle + normal * r, normal)
                }
            }
        }
        /// A band from `from` to `to` units outside an outline, lifted `lift` above the land, solid or dashed.
        func band(_ o: Outline, from: Float, to: Float, color: Vec3, dashed: Bool, lift: Float) {
            let levelled = Land.level(o.center.x, o.center.y, clearings, clearingCount)
            var points: [(Vec2, Vec2)] = []
            points.reserveCapacity(80)
            path(o, (from + to) / 2, step: Swift.max(0.25, o.r * 0.08)) { p, n in points.append((p, n)) }
            let n = points.count
            guard n > 2, vertexCount + n * 2 < capacity, indexCount + n * 6 < capacity * 3 else { return }
            let base = vertexCount
            let half = (to - from) / 2
            for (p, normal) in points {
                for w in [-half, half] {
                    let q = p + normal * w
                    vertex(Vec3(q.x, height(q.x, q.y, levelled: levelled) + lift, q.y), color)
                }
            }
            // Dashes: about two units on, one off, whole around the ring.
            var length: Float = 0
            for k in 0..<n {
                let a = points[k].0, b = points[(k + 1) % n].0
                let gapHere = simd_distance(a, b) < 1e-4
                defer { length += simd_distance(a, b) }
                if gapHere { continue }
                if dashed, length.truncatingRemainder(dividingBy: 1.8) > 1.15 { continue }
                let i0 = UInt32(base + k * 2), i1 = UInt32(base + ((k + 1) % n) * 2)
                for i in [i0, i1, i0 + 1, i0 + 1, i1, i1 + 1] { index.pointer[indexCount] = i; indexCount += 1 }
            }
        }
        func batch(alpha: Float, _ make: () -> Void) {
            let first = indexCount
            make()
            if indexCount > first { strips.append(Strip(first: first, count: indexCount - first, alpha: alpha)) }
        }
        func outline(of i: Int) -> Outline? {
            guard things.indices.contains(i), meadow.laid[i] != .none else { return nil }
            return outline(of: things[i])
        }
        func outline(of thing: MeadowScenery.Thing) -> Outline? {
            let circles = SceneryRules.footprint(of: thing)
            guard let first = circles.first, let last = circles.last else { return nil }
            // Never smaller on screen than a fingertip's ring (a small stone, a young tree's trunk), so it reads.
            if circles.count == 1 { return Outline(center: Vec2(first.x, first.z), along: Vec2(1, 0), half: 0, r: Swift.max(first.r, 8 * perPoint(first.x, first.z))) }
            let a = Vec2(first.x, first.z), b = Vec2(last.x, last.z)
            return Outline(center: (a + b) / 2, along: simd_normalize(b - a), half: simd_distance(a, b) / 2, r: first.r)
        }

        let focus = chrome.focus.linearRGB
        let ink = chrome.ink.linearRGB
        let white = Vec3(1, 1, 1)

        // The picnic ground: a soft dashed outline, kept for the workspaces.
        batch(alpha: strong ? 0.95 : 0.6) {
            let g = SceneryRules.picnicGround
            let corner: Float = 4
            // A rounded rectangle, walked as a closed path with the band's half width either side.
            let w = 2.2 * perPoint(0, (g.minZ + g.maxZ) / 2) * (strong ? 1.4 : 1)
            var points: [(Vec2, Vec2)] = []
            let corners = [(Vec2(g.maxX - corner, g.maxZ - corner), Float(0)), (Vec2(g.minX + corner, g.maxZ - corner), Float.pi / 2),
                           (Vec2(g.minX + corner, g.minZ + corner), Float.pi), (Vec2(g.maxX - corner, g.minZ + corner), 3 * Float.pi / 2)]
            for (c, start) in corners {
                for k in 0...8 {
                    let a = start + Float.pi / 2 * Float(k) / 8
                    let normal = Vec2(cos(a), sin(a))
                    points.append((c + normal * corner, normal))
                }
            }
            // Fill in the long sides so the land's rise is followed and the dashes are even.
            var dense: [(Vec2, Vec2)] = []
            for k in 0..<points.count {
                let (a, na) = points[k], (b, _) = points[(k + 1) % points.count]
                let steps = Swift.max(1, Int((simd_distance(a, b) / 0.6).rounded(.up)))
                for s in 0..<steps { dense.append((a + (b - a) * Float(s) / Float(steps), na)) }
            }
            let n = dense.count
            guard vertexCount + n * 4 < capacity else { return }
            for pass in 0..<(strong ? 2 : 1) {
                let base = vertexCount
                let color = pass == 0 ? white : ink
                let (inner, outer): (Float, Float) = pass == 0 ? (-w / 2, w / 2) : (w / 2, w * 1.3)
                for (p, normal) in dense {
                    for d in [inner, outer] {
                        let q = p + normal * d
                        vertex(Vec3(q.x, height(q.x, q.y, levelled: Land.level(q.x, q.y, clearings, clearingCount)) + 0.3, q.y), color)
                    }
                }
                var length: Float = 0
                for k in 0..<n {
                    let a = dense[k].0, b = dense[(k + 1) % n].0
                    defer { length += simd_distance(a, b) }
                    if length.truncatingRemainder(dividingBy: 3) > 1.8 { continue }
                    let i0 = UInt32(base + k * 2), i1 = UInt32(base + ((k + 1) % n) * 2)
                    for i in [i0, i1, i0 + 1, i0 + 1, i1, i1 + 1] { index.pointer[indexCount] = i; indexCount += 1 }
                }
            }
        }

        // Under the pointer: a faint ring.
        if let hovered = marks.hovered, !marks.selected.contains(hovered), let o = outline(of: hovered) {
            batch(alpha: strong ? 0.9 : 0.55) {
                let p = perPoint(o.center.x, o.center.y)
                band(o, from: 1.5 * p, to: 3.5 * p, color: white, dashed: false, lift: 0.3)
            }
        }
        // Chosen: the focus colour, with a thin white edge inside so it reads on any green; a tree also
        // ringed, more lightly, where its crown shades the ground.
        let refused = Set(marks.refused)
        batch(alpha: 0.95) {
            for i in marks.selected where !refused.contains(i) {
                guard let o = outline(of: i) else { continue }
                let p = perPoint(o.center.x, o.center.y)
                band(o, from: 0.5 * p, to: 1.7 * p, color: white, dashed: false, lift: 0.32)
                band(o, from: 1.7 * p, to: (strong ? 5 : 4) * p, color: focus, dashed: false, lift: 0.32)
            }
        }
        batch(alpha: strong ? 0.95 : 0.8) {
            for i in marks.selected where !refused.contains(i) {
                guard let crown = meadow.canopy(i) else { continue }
                let o = Outline(center: Vec2(crown.x, crown.z), along: Vec2(1, 0), half: 0, r: crown.r)
                let p = perPoint(o.center.x, o.center.y)
                band(o, from: -0.6 * p, to: 0.6 * p, color: white, dashed: false, lift: 0.3)
                band(o, from: 0.6 * p, to: (strong ? 3.4 : 2.6) * p, color: focus, dashed: false, lift: 0.3)
            }
        }
        // May not stand there: dashed, white within and the ink without, never by colour alone.
        batch(alpha: 0.95) {
            for i in marks.refused {
                guard let o = outline(of: i) else { continue }
                let p = perPoint(o.center.x, o.center.y)
                band(o, from: 0.5 * p, to: 2.3 * p, color: white, dashed: true, lift: 0.32)
                band(o, from: 2.3 * p, to: 4.3 * p, color: ink, dashed: true, lift: 0.32)
            }
        }
        // The thing about to be placed: its ground ringed as a chosen thing's (dashed, in the ink, where it
        // may not stand), with a tick on the ring for which way it faces.
        if let ghost = marks.ghost, let o = outline(of: ghost) {
            batch(alpha: 0.95) {
                let p = perPoint(o.center.x, o.center.y)
                let refused = marks.ghostRefused
                band(o, from: 0.5 * p, to: (refused ? 2.3 : 1.7) * p, color: white, dashed: refused, lift: 0.32)
                band(o, from: (refused ? 2.3 : 1.7) * p, to: (refused ? 4.3 : strong ? 5 : 4) * p, color: refused ? ink : focus, dashed: refused, lift: 0.32)
                // The tick: outward from the ring along the thing's own x axis, as it is turned.
                let facing = Vec2(cos(ghost.turn), -sin(ghost.turn))
                let r = o.r + o.half
                let tick = Outline(center: o.center + facing * (r + 5 * p), along: facing, half: 3.5 * p, r: 0)
                band(tick, from: 0, to: 1.6 * p, color: refused ? ink : focus, dashed: false, lift: 0.32)
            }
        }
        // The Brush's circle (the focus colour) or the Eraser's (dashed, in the ink).
        if let brush = marks.brush {
            batch(alpha: 0.9) {
                let o = Outline(center: Vec2(brush.center.x, brush.center.y), along: Vec2(1, 0), half: 0, r: brush.radius)
                let p = perPoint(o.center.x, o.center.y)
                band(o, from: -1.2 * p, to: 0.2 * p, color: white, dashed: brush.erasing, lift: 0.3)
                band(o, from: 0.2 * p, to: (strong ? 3 : 2.2) * p, color: brush.erasing ? ink : focus, dashed: brush.erasing, lift: 0.3)
            }
        }
        // The keyboard's cursor: a small ring of the focus colour with a dot in its middle.
        if let cursor = marks.cursor {
            batch(alpha: 0.95) {
                let p = perPoint(cursor.x, cursor.y)
                let o = Outline(center: Vec2(cursor.x, cursor.y), along: Vec2(1, 0), half: 0, r: 7 * p)
                band(o, from: 0, to: 1.5 * p, color: white, dashed: false, lift: 0.3)
                band(o, from: 1.5 * p, to: 3.5 * p, color: focus, dashed: false, lift: 0.3)
                band(Outline(center: o.center, along: o.along, half: 0, r: 0.6 * p), from: 0, to: 1.8 * p, color: focus, dashed: false, lift: 0.3)
            }
        }
        guard !strips.isEmpty else { return }

        enc.setRenderPipelineState(gpu.clayBlend)
        enc.setCullMode(.none)
        enc.setVertexBuffer(verts.buffer, offset: verts.offset, index: 1)
        // Seen, whole; then behind whatever stands in front of it, faintly.
        for (depth, strength) in [(gpu.depthRead, Float(1)), (gpu.depthNone, Float(0.32))] {
            enc.setDepthStencilState(depth)
            for strip in strips {
                let inst = arena.alloc(ClayInstance.self, 1)
                inst.pointer[0] = ClayInstance(.identity, tint: Vec4(1, 1, 1, strip.alpha * strength), lit: .unlit)
                enc.setVertexBuffer(inst.buffer, offset: inst.offset, index: 3)
                enc.drawIndexedPrimitives(type: .triangle, indexCount: strip.count, indexType: .uint32, indexBuffer: index.buffer,
                                          indexBufferOffset: index.offset + strip.first * 4)
            }
        }
        enc.setCullMode(.back)
        enc.setDepthStencilState(gpu.depthRead)
    }
}
