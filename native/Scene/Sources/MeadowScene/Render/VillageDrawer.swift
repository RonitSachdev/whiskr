import AppKit
import CoreText
@preconcurrency import Metal
import simd

// Draws the village: gingham blankets, the picnic spread, lanterns, ladybirds, the rings round what is
// chosen, the name flags (Core Text, redrawn only when a name, colour or fit changes), the hamper's glow
// after dark, and the lanterns' halos.

final class VillageDrawer {
    private let gpu: GPU
    private let cloths: [Mesh]
    private let outlines: [[Vec2]]
    private let treats: [Mesh]
    private let lanternFrame: Mesh
    private let lanternGlobe: Mesh
    private let ladybird: Mesh
    private let catRing: Mesh
    private let stone: Mesh
    private let note: MTLTexture
    private var flags: [String: (version: Int, texture: MTLTexture)] = [:]
    /// The colours the cached flags were painted in; a change repaints them all.
    private var flagChrome = MeadowChrome.standard

    init(gpu: GPU) {
        self.gpu = gpu
        cloths = Picnic.clothSeeds.map { gpu.mesh(Picnic.cloth($0), label: "cloth") }
        outlines = Picnic.outlines
        treats = Picnic.treats.map { gpu.mesh($0.shape, label: "picnic") }
        lanternFrame = gpu.mesh(Picnic.lanternFrame(), label: "lantern")
        lanternGlobe = gpu.mesh(Picnic.lanternGlobe(), label: "lantern globe")
        ladybird = gpu.mesh(Picnic.ladybird, label: "ladybird")
        catRing = gpu.mesh(Picnic.catRing, label: "ring")
        stone = gpu.mesh(Picnic.steppingStone, label: "stepping stone")
        note = Paint.note(gpu.device, queue: gpu.queue)
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

    /// The ring's rows, in units beyond the cloth's edge: a white band, then a charcoal one.
    static let ringRows: [Float] = [0.04, 0.2, 0.2, 0.34]
    static let globeLit = linear(0xffd66b)
    static let globeDark = linear(0xd9d9d4)
    static let globeRed = linear(0xef6a5f)

    func encodeOpaque(_ stage: Stage, arena: Arena, enc: MTLRenderCommandEncoder) {
        guard let village = stage.village else { return }
        enc.setRenderPipelineState(gpu.clay)
        enc.setDepthStencilState(gpu.depthWrite)
        enc.setCullMode(.back)
        let t = stage.time
        for plot in village.plots {
            // The blanket: turned its own way, scaled to fit its cats; watched-only ones are faded.
            var cloth = ClayInstance(.translation(plot.group + Vec3(plot.blanketAt.x, 0, plot.blanketAt.z)) * .rotationY(plot.turn) * .scale(Vec3(plot.blanketSize, 1, plot.blanketSize)),
                                     tint: Vec4(plot.view.color.red, plot.view.color.green, plot.view.color.blue, 1), roughness: 1, lit: [.gingham, .shaded, .glow])
            cloth.extra.z = plot.blanketSize * Picnic.checksPerUnit
            cloth.extra.w = plot.view.state == .watchOnly ? 0.45 : 0
            one(arena, cloth, enc)
            draw(cloths[plot.cloth], 1, enc)

            for treat in plot.treats where treat.shown.x > 0.01 {
                one(arena, ClayInstance(.translation(plot.group + treat.at) * .rotationY(treat.turn) * .scale(max(treat.shown.x, 0.001) * TREAT_SIZE), lit: [.shaded, .glow]), enc)
                draw(treats[treat.kind], 1, enc)
            }
            // Lanterns only after dark: they grow in with the dusk and shrink away at dawn.
            for (i, lantern) in plot.lanterns.enumerated() where village.shown(lantern) > 0.01 {
                let model = Mat4.translation(plot.group + lantern.at) * .rotationY(lantern.phase) * .scale(max(village.shown(lantern), 0.001) * LANTERN_SIZE)
                one(arena, ClayInstance(model, lit: [.shaded, .glow]), enc)
                draw(lanternFrame, 1, enc)
                // The globe: warm and glowing while running, pale glass when finished, red on failure.
                let flicker = 1 + 0.08 * sin(t * 7.1 + lantern.phase + Float(i)) * sin(t * 3.3 + lantern.phase * 2)
                let lit = lantern.lit
                let color = mix(mix(Self.globeDark, Self.globeLit, t: lit), Self.globeRed, t: lantern.red)
                let emissive = mix(Self.globeLit, Self.globeRed, t: lantern.red) * lit * 0.9 * flicker
                one(arena, ClayInstance(model, tint: Vec4(color, 1), emissive: emissive, lit: []), enc)
                draw(lanternGlobe, 1, enc)
            }
            if plot.view.state != .ended {
                one(arena, ClayInstance(.translation(plot.group + plot.ladybird) * .rotationY(plot.ladybirdTurn) * .scale(0.13), lit: []), enc)
                draw(ladybird, 1, enc)
            }
        }
        // The stepping stones from worktrees to their repositories, warmed by the picnic's light at night.
        let stones = village.stoneCount
        if stones > 0 {
            let inst = arena.alloc(ClayInstance.self, stones)
            for i in 0..<stones {
                let s = village.stones[i]
                inst.pointer[i] = ClayInstance(.translation(Vec3(s.x, -0.012, s.y)) * .rotationY(s.w) * .scale(s.z), lit: [.shaded, .glow])
            }
            enc.setVertexBuffer(inst.buffer, offset: inst.offset, index: 3)
            draw(stone, stones, enc)
        }
    }

    /// Notes floating from one cat to another, over everything else.
    func encodeNotes(_ stage: Stage, arena: Arena, enc: MTLRenderCommandEncoder) {
        guard let village = stage.village else { return }
        var n = 0
        for note in village.notes where note.drawn.w > 0.001 { _ = note; n += 1 }
        if n == 0 { return }
        let inst = arena.alloc(SpriteInstance.self, n)
        var k = 0
        for note in village.notes where note.drawn.w > 0.001 {
            let b = note.drawn
            inst.pointer[k] = SpriteInstance(at: Vec4(b.x, b.y, b.z, 1), size: Vec4(b.w, b.w, 0.5, 0.5), tint: Vec4(1, 1, 1, 1), uv: Vec4(0, 0, 1, 1))
            k += 1
        }
        enc.setRenderPipelineState(gpu.sprite)
        enc.setVertexBuffer(inst.buffer, offset: inst.offset, index: 1)
        enc.setFragmentTexture(note, index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: n)
    }

    /// The chosen cat's pool of light: a warm cream by day, the fireflies' gold by night.
    private static let haloDay = linear(0xfffaf0), haloNight = linear(0xffd27a)

    /// A circle one unit across from the middle, for rings round cats and lanterns.
    private static let circle: [Vec2] = (0..<48).map { i in let a = Float(i) / 48 * 2 * .pi; return Vec2(cos(a), sin(a)) }

    /// The rings lying on the ground: round what is chosen, a white and charcoal band round the blanket
    /// (the design's ring) and the pale ring under a chosen cat; and round what has the keyboard's
    /// attention, a thin band in the focus colour a little outside everything else.
    func encodeGround(_ stage: Stage, arena: Arena, enc: MTLRenderCommandEncoder) {
        guard let village = stage.village else { return }
        let chosen = village.chosen.flatMap { item in village.plot(item.blanketID).map { (item, $0) } }
        let focused = stage.keyboardFocus.flatMap { item in village.plot(item.blanketID).map { (item, $0) } }
        if chosen == nil && focused == nil { return }
        enc.setRenderPipelineState(gpu.clayBlend)
        enc.setDepthStencilState(gpu.depthRead)
        enc.setCullMode(.none)
        let night = stage.light.night
        let chrome = stage.settings.chrome
        if let (item, plot) = chosen {
            // The app's surface inside, its ink outside by day; by night a dark inner band and a warm cream edge.
            let inner = mix(chrome.surface.linearRGB, linear(0x3a3a32), t: night), outer = mix(chrome.ink.linearRGB, linear(0xf3d9a6), t: night)
            band(outlines[plot.cloth], size: plot.blanketSize, (Self.ringRows[0], Self.ringRows[1], inner), (Self.ringRows[2], Self.ringRows[3], outer),
                 model: blanketModel(plot), arena: arena, enc: enc)
            // The chosen cat: a soft pool of light on the cloth under it (warm cream by day, the fireflies' gold
            // by night), and its pale ring round it, breathing a little.
            if case .cat(_, let a) = item, let actor = plot.actors[a], !actor.leaving {
                let p = actor.cat.position
                let pool = (mix(Self.haloDay, Self.haloNight, t: night), 0.85 - 0.15 * night)
                let halo = arena.alloc(ShadowInstance.self, 1)
                halo.pointer[0] = ShadowInstance(model: .translation(Vec3(p.x, 0.03, p.z)) * .scale(Vec3(1, 1, 1) * actor.shownSize * 5),
                                                 extra: Vec4(pool.1, pool.0.x, pool.0.y, pool.0.z))
                enc.setRenderPipelineState(gpu.halo)
                enc.setVertexBuffer(halo.buffer, offset: halo.offset, index: 3)
                enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
                enc.setRenderPipelineState(gpu.clayBlend)
                one(arena, ClayInstance(.translation(Vec3(p.x, 0.02, p.z)) * .scale(actor.shownSize * (1.3 + sin(stage.time * 3) * 0.04)), tint: Vec4(1, 1, 1, 0.9), lit: .unlit), enc)
                draw(catRing, 1, enc)
            }
        }
        if let (item, plot) = focused {
            // Two points wide on screen (a touch more, as the ground is seen at a slant), two points clear.
            let perPoint = 2 * tan(MapCamera.fovY / 2) / max(stage.camera.viewport.y, 1) * simd_distance(stage.camera.eye, plot.middle)
            let width = 2.4 * perPoint, gap = 2.5 * perPoint
            let color = chrome.focus.linearRGB
            switch item {
            case .blanket:
                let from = (chosen?.1 === plot ? Self.ringRows[3] : 0.04) + gap
                band(outlines[plot.cloth], size: plot.blanketSize, (from, from + width, color), model: blanketModel(plot), arena: arena, enc: enc)
            case .cat(_, let a):
                guard let actor = plot.actors[a], !actor.leaving else { break }
                let p = actor.cat.position
                band(Self.circle, size: actor.shownSize * 1.36, (gap, gap + width, color), model: .translation(Vec3(p.x, 0, p.z)), arena: arena, enc: enc)
            case .lantern(_, let id):
                guard let lantern = plot.lanterns.first(where: { $0.view.id == id }), village.shown(lantern) > 0.01 else { break }
                band(Self.circle, size: 0.55 * LANTERN_SIZE * village.shown(lantern), (gap, gap + width, color),
                     model: .translation(plot.group + Vec3(lantern.at.x, 0, lantern.at.z)), arena: arena, enc: enc)
            }
        }
        enc.setCullMode(.back)
    }

    private func blanketModel(_ plot: Plot) -> Mat4 { .translation(plot.group + Vec3(plot.blanketAt.x, 0, plot.blanketAt.z)) * .rotationY(plot.turn) }

    /// Flat strips lying just above the ground along a closed outline (a unit shape scaled by `size`), each
    /// from `from` to `to` world units beyond it in its own colour, crisp where one meets the next.
    private func band(_ outline: [Vec2], size: Float, _ strips: (from: Float, to: Float, color: Vec3)..., model: Mat4, arena: Arena, enc: MTLRenderCommandEncoder) {
        let n = outline.count
        let rows = strips.count * 2
        let verts = arena.alloc(Float.self, n * rows * 10)
        let index = arena.alloc(UInt32.self, n * strips.count * 6)
        let turnsOut: Float = Extrude.signedArea(outline) > 0 ? 1 : -1
        for i in 0..<n {
            let p = outline[i]
            let tangent = simd_normalize(outline[(i + 1) % n] - outline[(i + n - 1) % n])
            let out = Vec2(tangent.y, -tangent.x) * turnsOut
            for (k, strip) in strips.enumerated() {
                for (r, w) in [strip.from, strip.to].enumerated() {
                    // Shape coordinates (x, y) lie as (x, −y) on the ground, as the cloth does.
                    let q = p * size + out * w
                    let base = (i * rows + k * 2 + r) * 10
                    verts.pointer[base] = q.x; verts.pointer[base + 1] = 0.012; verts.pointer[base + 2] = -q.y
                    verts.pointer[base + 3] = 0; verts.pointer[base + 4] = 1; verts.pointer[base + 5] = 0
                    verts.pointer[base + 6] = strip.color.x; verts.pointer[base + 7] = strip.color.y; verts.pointer[base + 8] = strip.color.z; verts.pointer[base + 9] = 1
                }
            }
        }
        // Each strip its own pair of rows, so the colour changes crisply between them.
        var k = 0
        for i in 0..<n {
            let a = UInt32(i * rows), b = UInt32(((i + 1) % n) * rows)
            for strip in 0..<strips.count {
                let r = UInt32(strip * 2)
                index.pointer[k] = a + r; index.pointer[k + 1] = b + r; index.pointer[k + 2] = a + r + 1
                index.pointer[k + 3] = a + r + 1; index.pointer[k + 4] = b + r; index.pointer[k + 5] = b + r + 1
                k += 6
            }
        }
        one(arena, ClayInstance(model, tint: Vec4(1, 1, 1, 0.95), lit: .unlit), enc)
        enc.setVertexBuffer(verts.buffer, offset: verts.offset, index: 1)
        enc.drawIndexedPrimitives(type: .triangle, indexCount: k, indexType: .uint32, indexBuffer: index.buffer, indexBufferOffset: index.offset)
    }

    /// Flags, then the glows: the hamper's lantern after dark and the halos of lit lanterns.
    func encodeTransparent(_ stage: Stage, arena: Arena, enc: MTLRenderCommandEncoder) {
        guard let village = stage.village else { return }
        enc.setDepthStencilState(gpu.depthRead)
        enc.setCullMode(.none)
        enc.setRenderPipelineState(gpu.sprite)
        if stage.settings.chrome != flagChrome {
            flagChrome = stage.settings.chrome
            flags.removeAll()
        }
        for plot in village.plots {
            let texture = flag(for: plot)
            let label = plot.label
            let whole = plot.flagHeight / FlagLabel.fill
            let wide = whole * Float(label.canvas.width) / Float(label.canvas.height)
            let s = arena.alloc(SpriteInstance.self, 1)
            s.pointer[0] = SpriteInstance(at: Vec4(plot.flagAt, plot.clear * (plot.view.state == .ended ? 0.6 : 1)),
                                          size: Vec4(wide, whole, 0.5, (1 - FlagLabel.fill) / 2), tint: Vec4(1, 1, 1, 1), uv: Vec4(0, 0, 1, 1))
            enc.setVertexBuffer(s.buffer, offset: s.offset, index: 1)
            enc.setFragmentTexture(texture, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }

        // Forget the flags of blankets that have gone.
        if flags.count > village.count { flags = flags.filter { village.plot($0.key) != nil } }

        // Glows, added onto whatever is behind them.
        let night = stage.light.night
        var count = 0
        for plot in village.plots { count += plot.lanterns.count + 1 }
        let glows = arena.alloc(SpriteInstance.self, max(count, 1))
        var n = 0
        let t = stage.time
        for (place, plot) in village.plots.enumerated() {
            // After dark a lantern glows at each hamper: the warm light the picnic sits in seems to come from it.
            if night > 0.02, let hamper = plot.treats.first, hamper.kind == 0, hamper.shown.x > 0.01 {
                let flicker = 1 + 0.06 * sin(t * 5.3 + Float(place) * 1.7) * sin(t * 2.1 + Float(place) * 3.1)
                let size = LAMP_SIZE * max(hamper.shown.x, 0.001) * flicker
                glows.pointer[n] = SpriteInstance(at: Vec4(plot.group + hamper.at + Vec3(0, LAMP_HEIGHT * hamper.shown.x, 0), night),
                                                  size: Vec4(size, size, 0.5, 0.5), tint: Vec4(1, 1, 1, 0), uv: Vec4(0, 0, 0, 0))
                n += 1
            }
            for lantern in plot.lanterns where village.shown(lantern) > 0.01 && lantern.lit > 0.02 {
                let color = mix(linear(0xffd66b), linear(0xef6a5f), t: lantern.red)
                let size = (1.5 + night * 1.2) * village.shown(lantern) * LANTERN_SIZE
                glows.pointer[n] = SpriteInstance(at: Vec4(plot.group + lantern.at + Vec3(0, 0.45 * LANTERN_SIZE, 0), lantern.lit * (0.45 + 0.55 * night)),
                                                  size: Vec4(size, size, 0.5, 0.5), tint: Vec4(color, 0), uv: Vec4(1, 0, 0, 0))
                n += 1
            }
        }
        if n > 0 {
            enc.setRenderPipelineState(gpu.glow)
            enc.setVertexBuffer(glows.buffer, offset: glows.offset, index: 1)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: n)
        }
        enc.setCullMode(.back)
    }

    // MARK: flag textures

    private func flag(for plot: Plot) -> MTLTexture {
        let id = plot.view.id
        if let have = flags[id], have.version == plot.label.version { return have.texture }
        let texture = Self.paintFlag(plot.label, chrome: flagChrome, gpu: gpu)
        flags[id] = (plot.label.version, texture)
        return texture
    }

    /// Flag.ts `write`: the pill with a soft shadow, a pin when pinned, the colour dot (hollow when watched
    /// from outside, a small server glyph for another machine), the name, and the branch after a small
    /// branch glyph in a quieter ink; inverted when chosen. In the app's colours.
    static func paintFlag(_ label: FlagLabel, chrome: MeadowChrome = .standard, gpu: GPU) -> MTLTexture {
        let S = FlagLabel.scale, tall = FlagLabel.tall, shadow = FlagLabel.shadow
        let w = label.canvas.width, h = label.canvas.height
        let wide = CGFloat(w) - shadow * 2
        return Paint.texture(gpu.device, queue: gpu.queue, width: w, height: h, label: "flag") { c in
            let surface = Paint.color(chrome.surface), ink = Paint.color(chrome.ink)
            let pill = CGPath(roundedRect: CGRect(x: shadow, y: shadow, width: wide, height: tall), cornerWidth: tall / 2, cornerHeight: tall / 2, transform: nil)
            c.saveGState()
            c.setShadow(offset: CGSize(width: 0, height: -1.5 * S), blur: 5 * S, color: CGColor(gray: 0, alpha: 0.16))
            c.addPath(pill)
            c.setFillColor(label.chosen ? ink : surface)
            c.fillPath()
            c.restoreGState()
            if !label.chosen {
                c.addPath(pill)
                c.setLineWidth(S)
                c.setStrokeColor(CGColor(gray: 0, alpha: 0.1))
                c.strokePath()
            }
            let middle = shadow + tall / 2
            // Text and marks on the pill, and the quieter ink of the pin and the branch.
            let text = label.chosen ? surface : ink
            let quiet = text.copy(alpha: label.chosen ? 0.72 : 0.6) ?? text
            if label.pinned { pin(in: c, left: shadow + FlagLabel.lead * S, middle: middle, color: quiet) }
            let dot = CGRect(x: shadow + label.dotX, y: middle - 5 * S, width: 10 * S, height: 10 * S)
            let color = CGColor(srgbRed: CGFloat(label.color.red), green: CGFloat(label.color.green), blue: CGFloat(label.color.blue), alpha: 1)
            if label.remote {
                // A small server: two stacked rounded boxes with a light each.
                c.setStrokeColor(label.chosen ? surface : ink.copy(alpha: 0.65) ?? ink)
                c.setLineWidth(1.4 * S)
                for k in 0..<2 {
                    let r = CGRect(x: dot.minX - S, y: dot.minY + CGFloat(k) * 5.5 * S - 0.5 * S, width: 12 * S, height: 4.5 * S)
                    c.addPath(CGPath(roundedRect: r, cornerWidth: 1.2 * S, cornerHeight: 1.2 * S, transform: nil))
                    c.strokePath()
                    c.setFillColor(color)
                    c.fillEllipse(in: CGRect(x: r.maxX - 3.4 * S, y: r.midY - 0.9 * S, width: 1.8 * S, height: 1.8 * S))
                }
            } else if label.hollow {
                c.setStrokeColor(color)
                c.setLineWidth(2 * S)
                c.strokeEllipse(in: dot.insetBy(dx: S, dy: S))
            } else {
                c.setFillColor(color)
                c.fillEllipse(in: dot)
                if label.chosen {
                    c.setLineWidth(1.5 * S)
                    c.setStrokeColor(surface)
                    c.strokeEllipse(in: dot)
                }
            }
            Paint.draw(Paint.line(label.shown, font: FlagLabel.font, color: text), in: c, left: shadow + label.titleX, middleY: middle + S * 0.5)
            if let detail = label.shownDetail {
                branch(in: c, left: shadow + label.glyphX, middle: middle, color: quiet)
                Paint.draw(Paint.line(detail, font: FlagLabel.detailFont, color: quiet), in: c, left: shadow + label.detailX, middleY: middle + S * 0.5)
            }
            if let more = label.shownMore {
                // Red when one of those it counts has failed, as that lantern would be.
                let mark = label.moreFailed ? Paint.color(chrome.alert) : quiet
                lantern(in: c, left: shadow + label.lanternX, middle: middle, color: mark)
                Paint.draw(Paint.line(more, font: FlagLabel.detailFont, color: mark), in: c, left: shadow + label.moreX, middleY: middle + S * 0.5)
            }
        }
    }

    /// A small hurricane lantern drawn in line, as the branch is: a handle, a cap, the globe with its flame
    /// and a base; `FlagLabel.lanternWide` across.
    private static func lantern(in c: CGContext, left: CGFloat, middle: CGFloat, color: CGColor) {
        let S = FlagLabel.scale, wide = FlagLabel.lanternWide * S, x = left + wide / 2
        c.saveGState()
        c.setStrokeColor(color)
        c.setFillColor(color)
        c.setLineWidth(1.1 * S)
        c.setLineCap(.round)
        c.addArc(center: CGPoint(x: x, y: middle - 3.6 * S), radius: 1.6 * S, startAngle: .pi, endAngle: 0, clockwise: false)
        c.strokePath()
        c.move(to: CGPoint(x: x - 2.2 * S, y: middle - 3.4 * S)); c.addLine(to: CGPoint(x: x + 2.2 * S, y: middle - 3.4 * S))
        c.move(to: CGPoint(x: left + 0.2 * S, y: middle + 4.3 * S)); c.addLine(to: CGPoint(x: left + wide - 0.2 * S, y: middle + 4.3 * S))
        c.strokePath()
        c.addPath(CGPath(roundedRect: CGRect(x: left + 0.9 * S, y: middle - 2 * S, width: wide - 1.8 * S, height: 5.4 * S),
                         cornerWidth: 2 * S, cornerHeight: 2 * S, transform: nil))
        c.strokePath()
        c.fillEllipse(in: CGRect(x: x - 0.9 * S, y: middle - 0.1 * S, width: 1.8 * S, height: 2.4 * S))
        c.restoreGState()
    }

    /// A push pin leaning right, head up, its point toward the bottom left: `FlagLabel.pinWide` across.
    private static func pin(in c: CGContext, left: CGFloat, middle: CGFloat, color: CGColor) {
        let S = FlagLabel.scale
        c.saveGState()
        c.translateBy(x: left + FlagLabel.pinWide * S / 2, y: middle)
        c.rotate(by: .pi / 5)
        c.setFillColor(color)
        c.setStrokeColor(color)
        // Head, collar, then the needle.
        c.addPath(CGPath(roundedRect: CGRect(x: -2.2 * S, y: -5.6 * S, width: 4.4 * S, height: 4.2 * S), cornerWidth: 1.2 * S, cornerHeight: 1.2 * S, transform: nil))
        c.fillPath()
        c.addPath(CGPath(roundedRect: CGRect(x: -3.8 * S, y: -1.9 * S, width: 7.6 * S, height: 1.9 * S), cornerWidth: 0.9 * S, cornerHeight: 0.9 * S, transform: nil))
        c.fillPath()
        c.setLineWidth(1.3 * S)
        c.setLineCap(.round)
        c.move(to: CGPoint(x: 0, y: 0))
        c.addLine(to: CGPoint(x: 0, y: 5.2 * S))
        c.strokePath()
        c.restoreGState()
    }

    /// A git branch: a trunk with a ring at each end, and a branch curving off it to a ring on the right;
    /// `FlagLabel.glyphWide` across.
    private static func branch(in c: CGContext, left: CGFloat, middle: CGFloat, color: CGColor) {
        let S = FlagLabel.scale
        let trunk = left + 1.4 * S, twig = left + FlagLabel.glyphWide * S - 1.4 * S
        let top = middle - 4.3 * S, low = middle + 4.3 * S, r = 1.25 * S
        c.saveGState()
        c.setStrokeColor(color)
        c.setLineWidth(1.1 * S)
        c.setLineCap(.round)
        c.move(to: CGPoint(x: trunk, y: top + r)); c.addLine(to: CGPoint(x: trunk, y: low - r))
        c.move(to: CGPoint(x: twig, y: top + 1.3 * S + r))
        c.addCurve(to: CGPoint(x: trunk, y: middle + 2.2 * S), control1: CGPoint(x: twig, y: middle + 0.6 * S), control2: CGPoint(x: trunk, y: middle))
        c.strokePath()
        for (x, y) in [(trunk, top), (trunk, low), (twig, top + 1.3 * S)] {
            c.strokeEllipse(in: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r))
        }
        c.restoreGState()
    }
}
