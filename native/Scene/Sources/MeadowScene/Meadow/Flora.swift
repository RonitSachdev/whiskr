import Foundation
import simd

// Port of src/meadow/flora.ts: meadow plants modelled on how the real ones grow, then simplified into
// clay. One unit is about 13 cm at cat scale (the cat is 2.3 tall), so flowers stand at its head height;
// blooms are about 2.5× life size so they read from above.

struct Plant {
    var shape: Geometry
    var top: Vec3   // where a butterfly would settle
}

enum Flora {
    static let green: (UInt32, UInt32) = (0x5a9a42, 0x86bd5a)

    private static func v(_ x: Float, _ y: Float, _ z: Float) -> Vec3 { Vec3(x, y, z) }
    private static func ring(_ count: Int, _ each: (Float, Int) -> Geometry) -> [Geometry] {
        (0..<count).map { each(Float($0) / Float(count) * 2 * .pi, $0) }
    }
    /// A stem that bows as it rises instead of standing like a pin.
    private static func stem(_ end: Vec3, _ bend: Vec3, _ thick: Float = 0.045) -> Clay.Limb {
        Clay.limb(Clay.bow(end, bend), thick, thick * 0.6, green.0, green.1, sides: 6, rings: 9)
    }
    /// A blade-shaped leaf growing out from a point on a stem, angled upward.
    private static func leaf(_ from: Vec3, _ length: Float, _ yaw: Float, _ rise: Float = 0.5, _ width: Float = 0.32) -> Geometry {
        let reach = length * 0.9
        return Clay.blob(at: Vec3(from.x + cos(rise) * cos(yaw) * reach, from.y + sin(rise) * reach, from.z - cos(rise) * sin(yaw) * reach),
                         size: Vec3(length, 0.02, length * width), color: green.0, top: green.1, turn: Vec3(0, yaw, rise))
    }
    /// Tilt that leans a bloom's face toward a compass direction, the way flowers turn to the light.
    private static func facing(_ direction: Float, _ by: Float) -> Vec3 { Vec3(sin(direction) * by, 0, -cos(direction) * by) }

    /// Oxeye daisy: many thin white rays round a domed golden disc, on a slender leaning stem.
    static func daisy(_ k: Float) -> Plant {
        let way = k * 4.1 + 0.6, height = 1.8 - k * 0.35
        let end = v(cos(way) * 0.32, height, sin(way) * 0.32)
        let stalk = stem(end, v(-cos(way) * 0.16, 0, -sin(way) * 0.16))
        let bloom = ring(13) { a, _ in Clay.blob(at: v(cos(a) * 0.2, -0.012, sin(a) * 0.2), size: Vec3(0.165, 0.024, 0.058), color: 0xfffdf5, turn: v(0, -a, -0.12)) }
            + [Clay.blob(at: v(0, 0.035, 0), size: Vec3(0.115, 0.07, 0.115), color: 0xeeb11a, top: 0xffd94a)]
        let parts = [stalk.shape, leaf(stalk.curve.pointAt(0.22), 0.3, way + 1.2), leaf(stalk.curve.pointAt(0.42), 0.24, way - 1.9, 0.6)]
            + Clay.seat(bloom, end, facing(way, 0.4))
        return Plant(shape: Geometry.join(parts), top: Vec3(end.x, height + 0.1, end.z))
    }

    /// Meadow buttercup: thin branching stems, each ending in a glossy five-petalled cup.
    static func buttercup(_ k: Float) -> Plant {
        let way = k * 3.3 + 2
        func cup(_ at: Vec3, _ lean: Float) -> [Geometry] {
            Clay.seat(ring(5) { a, _ in Clay.blob(at: v(cos(a) * 0.105, 0.03, sin(a) * 0.105), size: Vec3(0.115, 0.03, 0.1), color: 0xffcf14, top: 0xffe95a, turn: v(0, -a, 0.55)) }
                      + [Clay.blob(at: v(0, 0.03, 0), size: 0.046, color: 0xc9bd2e)], at, facing(lean, 0.3))
        }
        let end = v(cos(way) * 0.25, 2.0 - k * 0.3, sin(way) * 0.25)
        let main = stem(end, v(cos(way) * 0.1, 0, sin(way) * 0.1), 0.036)
        var parts = [main.shape] + cup(end, way)
        for (along, out, length) in [(Float(0.5), way + 2.2, Float(0.55)), (0.66, way - 2.0, 0.4)] {
            let from = main.curve.pointAt(along)
            let to = v(from.x + cos(out) * length, from.y + length * 1.1, from.z + sin(out) * length)
            let elbow = v(from.x + cos(out) * length * 0.75, from.y + length * 0.35, from.z + sin(out) * length * 0.75)
            parts.append(Clay.limb(QuadraticBezier(from, elbow, to), 0.028, 0.02, green.0, green.1, sides: 5, rings: 6).shape)
            parts += cup(to, out)
        }
        parts += [leaf(v(0, 0.08, 0), 0.34, way + 0.6, 0.35, 0.5), leaf(v(0, 0.08, 0), 0.3, way + 3.4, 0.4, 0.5), leaf(v(0, 0.08, 0), 0.26, way - 1.6, 0.3, 0.5)]
        return Plant(shape: Geometry.join(parts), top: Vec3(end.x, end.y + 0.1, end.z))
    }

    /// Field poppy: four broad papery petals forming a bowl round a dark-ringed seed pod, with a nodding bud.
    static func poppy(_ k: Float) -> Plant {
        let way = k * 2.7 + 4
        let end = v(cos(way) * 0.4, 2.2 - k * 0.3, sin(way) * 0.4)
        let stalk = stem(end, v(-cos(way) * 0.25, 0, -sin(way) * 0.25), 0.04)
        let bloom = ring(4) { a, _ in Clay.blob(at: v(cos(a) * 0.17, 0.05, sin(a) * 0.17), size: Vec3(0.27, 0.035, 0.24), color: 0xe8452a, top: 0xff7a4c, turn: v(0, -a, 0.6)) }
            + [Clay.blob(at: v(0, 0.03, 0), size: Vec3(0.11, 0.022, 0.11), color: 0x4a3340),
               Clay.blob(at: v(0, 0.075, 0), size: Vec3(0.062, 0.058, 0.062), color: 0x9fb36a)]
        // The bud's stem rises, arches over and hangs its head.
        let away = way + 2.6
        func out(_ reach: Float, _ y: Float) -> Vec3 { v(cos(away) * reach, y, sin(away) * reach) }
        let arch = CatmullRom([v(0, 0, 0), out(0.2, 0.8), out(0.44, 1.32), out(0.58, 1.18)])
        let bud = Clay.limb(arch, 0.032, 0.022, green.0, green.1, sides: 5, rings: 9)
        let parts = [stalk.shape, bud.shape] + Clay.seat(bloom, end, facing(way, 0.35)) + [
            Clay.blob(at: v(bud.end.x, bud.end.y - 0.1, bud.end.z), size: Vec3(0.085, 0.14, 0.085), color: 0x7fa052, top: 0xa7c070),
            leaf(stalk.curve.pointAt(0.18), 0.4, way + 1.5, 0.45, 0.26), leaf(stalk.curve.pointAt(0.3), 0.34, way - 1.3, 0.55, 0.26),
        ]
        return Plant(shape: Geometry.join(parts), top: Vec3(end.x, end.y + 0.12, end.z))
    }

    /// Lupin: a tapering spire of small pea-flowers packed in whorls, above fans of finger-like leaflets.
    static func lupin(_ k: Float) -> Plant {
        let way = k * 5 + 1, height = 2.55 - k * 0.3
        let end = v(cos(way) * 0.12, height, sin(way) * 0.12)
        let stalk = stem(end, v(0, 0, 0), 0.05)
        var parts = [stalk.shape]
        let deep = linear(0x6a4fd0), pale = linear(0xb7a4f6)
        let whorls = 12
        for i in 0..<whorls {
            let t = Float(i) / Float(whorls - 1)
            let center = stalk.curve.pointAt(0.42 + t * 0.58)
            let florets = 6 - Int(floor(t * 2.5)), out = 0.15 * (1 - 0.62 * t), size = 0.085 * (1 - 0.5 * t)
            // The lowest flowers open first; the tip is still green bud.
            let open = mix(deep, pale, t: t)
            for g in ring(florets, { a, _ in
                let around = a + Float(i) * 0.55
                return Clay.blob(at: v(center.x + cos(around) * out, center.y, center.z + sin(around) * out),
                                 size: Vec3(size * 1.25, size * 0.8, size * 0.85), color: 0, turn: v(0, -around, 0.5))
            }) {
                var g = g
                g.colors = [Vec3](repeating: t > 0.86 ? linear(0xb9c79a) : open, count: g.count)
                parts.append(g)
            }
        }
        // Palmate leaves: leaflets radiating from the end of a short stalk.
        for (along, out) in [(Float(0.14), way + 0.9), (0.24, way - 2.2)] {
            let from = stalk.curve.pointAt(along)
            let hub = v(from.x + cos(out) * 0.42, from.y + 0.32, from.z + sin(out) * 0.42)
            parts.append(Clay.limb(QuadraticBezier(from, v((from.x + hub.x) / 2, from.y + 0.05, (from.z + hub.z) / 2), hub), 0.022, 0.016, green.0, green.1, sides: 5, rings: 5).shape)
            parts += ring(7) { a, _ in leaf(hub, 0.2, a, 0.22, 0.26) }
        }
        return Plant(shape: Geometry.join(parts), top: Vec3(end.x, height + 0.05, end.z))
    }

    /// Fly agaric: a domed red cap flecked with white, flat pale gills beneath, a skirt on the stem.
    static func mushroom(_ k: Float) -> Plant {
        let lean = k * 0.5 - 0.1
        var cap = Clay.blob(at: v(lean * 0.35, 0.86, 0), size: Vec3(0.58, 0.34, 0.58), color: 0xc93527, top: 0xee5a48, lumpy: 0.05)
        // Flatten the underside and turn it to gill colour, so the cap is a dome, not a ball.
        let gills = linear(0xf2e6cf)
        for i in cap.positions.indices where cap.positions[i].y < 0.86 {
            cap.positions[i].y = 0.86 - (0.86 - cap.positions[i].y) * 0.2
            cap.colors[i] = gills
        }
        cap.computeNormals()
        var parts = [
            Clay.blob(at: v(lean * 0.15, 0.42, 0), size: Vec3(0.17, 0.46, 0.17), color: 0xf3ead8, top: 0xfffaf0, turn: v(0, 0, -lean * 0.4)),
            Clay.blob(at: v(lean * 0.25, 0.56, 0), size: Vec3(0.25, 0.035, 0.25), color: 0xfff6e6),
            cap,
        ]
        for i in 0..<10 {
            let out = 0.1 + Float(i) * 0.045, a = Float(i) * 2.399963
            parts.append(Clay.blob(at: v(lean * 0.35 + cos(a) * out, 0.86 + 0.33 * sqrt(1 - pow(out / 0.6, 2)), sin(a) * out), size: Vec3(0.058, 0.03, 0.058), color: 0xfffaf0))
        }
        return Plant(shape: Geometry.join(parts), top: v(lean * 0.35, 1.22, 0))
    }

    /// A weathered stone with a smaller one leaning on it; the second kind has moss settled on top.
    static func stone(_ k: Float) -> Plant {
        var parts = [
            Clay.blob(at: v(0, 0.42, 0), size: Vec3(1.0, 0.62, 0.8), color: 0x9c998f, top: 0xcbc8be, lumpy: 0.13),
            Clay.blob(at: v(0.78, 0.22, 0.34), size: Vec3(0.5, 0.34, 0.44), color: 0x96938a, top: 0xc2bfb5, lumpy: 0.13),
        ]
        if k > 0.5 { parts.append(Clay.blob(at: v(-0.12, 0.9, -0.05), size: Vec3(0.62, 0.17, 0.5), color: 0x7fa346, top: 0xa6c860, lumpy: 0.14)) }
        return Plant(shape: Geometry.join(parts), top: v(0, 1.05, 0))
    }

    // One declaration each: several bindings in one `static let` came out shifted (lupins held another
    // flower, stones held mushrooms), which the parity tests caught.
    static let daisies: [Plant] = [daisy(0), daisy(1)]
    static let buttercups: [Plant] = [buttercup(0), buttercup(1)]
    static let poppies: [Plant] = [poppy(0), poppy(1)]
    static let lupins: [Plant] = [lupin(0), lupin(1)]
    static let mushrooms: [Plant] = [mushroom(0), mushroom(1)]
    static let stones: [Plant] = [stone(0), stone(1)]

    // MARK: The meadow editor's plants (the Mac's own)

    /// A small, smooth ball for parts there are many of (a fern's leaflets): a few dozen faces where a blob has
    /// hundreds, which no one sees at their size.
    private static let bead = Shapes.sphere(1, 8, 5)
    /// `bead` stretched to `size` along `along` (its x), its flat side (y) facing as near `up` as it can.
    private static func bead(at: Vec3, along: Vec3, up: Vec3, size: Vec3, color: UInt32, top: UInt32) -> Geometry {
        let x = simd_normalize(along), z = simd_normalize(simd_cross(x, up)), y = simd_cross(z, x)
        let m = Mat4(columns: (Vec4(x * size.x, 0), Vec4(y * size.y, 0), Vec4(z * size.z, 0), Vec4(at, 1)))
        return bead.applied(m).painted(color, top)
    }
    /// A `Clay.blob` made of a `bead`: for a plant's many small parts (florets, leaflets), which a brushed meadow
    /// may hold thousands of.
    private static func bead(at: Vec3, size: Vec3, color: UInt32, top: UInt32? = nil, turn: Vec3 = .zero) -> Geometry {
        bead.applied(.compose(at, euler: turn, scale: size)).painted(color, top)
    }

    /// Cornflower: on wiry grey-green stems, ragged rosettes of deep blue funnel florets round a tuft of violet
    /// ones, each head held in a scaly green urn; a second head lower on a branch, and a bud.
    static let cornflowers: [Plant] = [cornflower()]
    private static func cornflower() -> Plant {
        let way: Float = 0.8, stalkGreen: (UInt32, UInt32) = (0x6c8c62, 0x95ae86)
        func head(_ at: Vec3, _ lean: Float, _ scale: Float) -> [Geometry] {
            var parts = [Clay.thrown([Vec2(0, -0.1), Vec2(0.05, -0.09), Vec2(0.085, -0.03), Vec2(0.08, 0.02), Vec2(0, 0.03)], 0x7f9a66, 0xb2c08a, around: 12, steps: 8)]
            parts += ring(10) { a, k in
                let long: Float = k % 2 == 0 ? 0.15 : 0.125
                return bead(at: v(cos(a) * 0.12, 0.04, sin(a) * 0.12), size: Vec3(long, 0.035, 0.055), color: 0x3459c9, top: 0x6f95f0, turn: v(0, -a, 0.42))
            }
            parts += ring(5) { a, _ in bead(at: v(cos(a) * 0.035, 0.075, sin(a) * 0.035), size: Vec3(0.04, 0.05, 0.04), color: 0x4a2f86, top: 0x7a55b8) }
            return Clay.seat(parts.map { $0.applied(.scale(Vec3(repeating: scale))) }, at, facing(lean, 0.3))
        }
        let end = v(cos(way) * 0.2, 2.1, sin(way) * 0.2)
        let main = Clay.limb(Clay.bow(end, v(-cos(way) * 0.12, 0, -sin(way) * 0.12)), 0.04, 0.026, stalkGreen.0, stalkGreen.1, sides: 6, rings: 9)
        var parts = [main.shape] + head(end, way, 1.25)
        let from = main.curve.pointAt(0.55), out = way + 2.4
        let side = v(from.x + cos(out) * 0.42, from.y + 0.45, from.z + sin(out) * 0.42)
        parts.append(Clay.limb(QuadraticBezier(from, v(from.x + cos(out) * 0.3, from.y + 0.15, from.z + sin(out) * 0.3), side), 0.026, 0.02, stalkGreen.0, stalkGreen.1, sides: 5, rings: 6).shape)
        parts += head(side, out, 1.1)
        // A bud still closed in its urn.
        let budFrom = main.curve.pointAt(0.72), budOut = way - 2
        let bud = v(budFrom.x + cos(budOut) * 0.25, budFrom.y + 0.3, budFrom.z + sin(budOut) * 0.25)
        parts.append(Clay.limb(QuadraticBezier(budFrom, v(budFrom.x + cos(budOut) * 0.2, budFrom.y + 0.1, budFrom.z + sin(budOut) * 0.2), bud), 0.022, 0.018, stalkGreen.0, stalkGreen.1, sides: 5, rings: 5).shape)
        parts.append(Clay.blob(at: bud + v(0, 0.05, 0), size: Vec3(0.06, 0.08, 0.06), color: 0x7f9a66, top: 0x5a76c8))
        // Narrow, downy leaves up the stem.
        parts += [leaf(main.curve.pointAt(0.18), 0.42, way + 1.3, 0.55, 0.16), leaf(main.curve.pointAt(0.3), 0.36, way - 1.7, 0.6, 0.16),
                  leaf(main.curve.pointAt(0.45), 0.28, way + 3, 0.7, 0.15)]
        return Plant(shape: Geometry.join(parts), top: Vec3(end.x, end.y + 0.12, end.z))
    }

    /// Foxglove: a tall spire hung on one side with rosy-purple bells, each a tube flaring to a pale, speckled
    /// mouth, opening from the bottom up with green buds at the tip; at its foot a rosette of broad, soft
    /// grey-green leaves.
    static let foxgloves: [Plant] = [foxglove()]
    private static func foxglove() -> Plant {
        let way: Float = 2.2, height: Float = 3.3
        let end = v(cos(way) * 0.12, height, sin(way) * 0.12)
        let stalk = Clay.limb(Clay.bow(end, v(-cos(way) * 0.08, 0, -sin(way) * 0.08)), 0.055, 0.03, green.0, green.1, sides: 7, rings: 12)
        var parts = [stalk.shape]
        let bells = 15
        for i in 0..<bells {
            let t = Float(i) / Float(bells - 1)
            let at = stalk.curve.pointAt(0.36 + t * 0.6)
            // Mostly to one side (`way`), spreading a little round it.
            let yaw = -way + Float(i % 3 - 1) * 0.55 + sin(Float(i) * 2.3) * 0.2
            let out = Vec3(cos(yaw), 0, -sin(yaw))
            if t > 0.8 {
                // Buds: small, green, pointing up and out.
                parts.append(Clay.blob(at: at + out * 0.06, size: Vec3(0.05, 0.08 - (t - 0.8) * 0.12, 0.05), color: 0x6f9a48, top: 0x9fbf6a, turn: v(0, yaw, -0.5)))
                continue
            }
            let scale = 1.05 - t * 0.45
            var bell = Clay.thrown([Vec2(0, 0), Vec2(0.045, 0.01), Vec2(0.075, 0.09), Vec2(0.095, 0.2), Vec2(0.125, 0.28), Vec2(0.14, 0.31), Vec2(0.1, 0.305), Vec2(0, 0.25)],
                                   0x93367c, 0xd88cbf, around: 10, steps: 8)
            // Dark spots ringed in white on the lower lip of the open bells.
            if t < 0.5 {
                bell = Geometry.join([bell, Clay.blob(at: v(0.08, 0.29, 0.02), size: 0.022, color: 0x5e2450), Clay.blob(at: v(0.07, 0.285, -0.04), size: 0.018, color: 0x5e2450)])
            }
            bell.apply(.compose(at + out * 0.1, euler: v(0, yaw, -(.pi / 2 + 0.9)), scale: Vec3(repeating: scale)))
            parts.append(bell)
        }
        // The rosette at its foot, and smaller leaves up the stem.
        parts += ring(6) { a, k in
            bead(at: v(cos(a) * 0.5, 0.12, -sin(a) * 0.5), size: Vec3(0.62 - Float(k % 2) * 0.1, 0.04, 0.24), color: 0x56814a, top: 0x8eae74, turn: v(0, a + 0.3, 0.22))
        }
        parts += [leaf(stalk.curve.pointAt(0.18), 0.4, way + 1.1, 0.4, 0.3), leaf(stalk.curve.pointAt(0.28), 0.3, way - 2, 0.5, 0.3)]
        return Plant(shape: Geometry.join(parts), top: Vec3(end.x, height * 0.75, end.z))
    }

    /// A fern (male fern, as in shady woods): a shuttlecock of fronds rising from one crown and arching out, each
    /// a midrib lined with leaflets that shorten toward its tip, and one young frond still curled.
    static let ferns: [Plant] = [fern()]
    private static func fern() -> Plant {
        var parts: [Geometry] = []
        let fronds = 7, up = Vec3(0, 1, 0)
        for f in 0..<fronds {
            let yaw = Float(f) / Float(fronds) * 2 * .pi + sin(Float(f) * 1.7) * 0.25
            let out = Vec3(cos(yaw), 0, sin(yaw)), long = 1 + 0.12 * sin(Float(f) * 2.9)
            let rachis = CubicBezier(out * 0.06, out * 0.3 * long + up * 1.3, out * 1.45 * long + up * 2.15, out * 2.35 * long + up * 1.25)
            parts.append(Clay.limb(rachis, 0.04, 0.018, 0x6f7f3a, 0x7fa848, sides: 5, rings: 12).shape)
            let pinnae = 8
            for k in 0..<pinnae {
                let t = 0.14 + Float(k) / Float(pinnae - 1) * 0.82
                let at = rachis.pointAt(t), along = rachis.tangentAt(t)
                let side = simd_normalize(simd_cross(along, up))
                let length = 0.4 * pow(sin(.pi * (t - 0.06) / 0.94), 0.7) * long + 0.06
                for s: Float in [-1, 1] {
                    let reach = simd_normalize(side * s + along * 0.45)
                    parts.append(bead(at: at + reach * length * 0.8, along: reach, up: up, size: Vec3(length, 0.022, length * 0.34), color: 0x4c8536, top: 0x9acb62))
                }
            }
        }
        // A fiddlehead: a young frond still coiled, brown-furred, in the middle.
        let coil = CatmullRom((0...8).map { k in
            let a = Float(k) * 0.75, r = 0.16 * (1 - Float(k) / 10)
            return k < 3 ? Vec3(0.02 * Float(k), 0.35 * Float(k), 0) : Vec3(0.1 + r * sin(a), 0.75 + r * cos(a) - 0.05, 0)
        })
        parts.append(Clay.limb(coil, 0.045, 0.035, 0x7a6a3a, 0x9fae5c, sides: 6, rings: 16).shape)
        return Plant(shape: Geometry.join(parts), top: v(0, 2.1, 0))
    }

    /// White clover: a low patch of trefoil leaves, each of three rounded leaflets with a pale chevron, and round
    /// white flower heads, a blush of pink at their base, held on stalks just above the leaves.
    static let clovers: [Plant] = [clover()]
    private static func clover() -> Plant {
        var parts: [Geometry] = []
        let leaves = 9
        for k in 0..<leaves {
            let a = Float(k) * 2.399963, out = 0.1 + 0.3 * sqrt(Float(k) / Float(leaves))
            let at = v(cos(a) * out, 0.26 + 0.12 * sin(Float(k) * 1.3), sin(a) * out)
            parts.append(Clay.limb(Clay.bow(at, v(-cos(a) * 0.05, 0, -sin(a) * 0.05)), 0.024, 0.018, green.0, green.1, sides: 5, rings: 5).shape)
            parts += ring(3) { b, _ in
                let around = b + a
                return bead(at: at + v(cos(around) * 0.11, 0.01, sin(around) * 0.11), size: Vec3(0.13, 0.022, 0.11), color: 0x3f7a30, top: 0x6aa748, turn: v(0, -around, 0.08))
            }
            parts += ring(3) { b, _ in
                let around = b + a
                return bead(at: at + v(cos(around) * 0.085, 0.026, sin(around) * 0.085), size: Vec3(0.04, 0.012, 0.026), color: 0x9cc47c, turn: v(0, -around, 0))
            }
        }
        for (a, out, high) in [(Float(0.6), Float(0.18), Float(0.66)), (2.9, 0.26, 0.56), (4.6, 0.12, 0.72)] {
            let at = v(cos(a) * out, high, sin(a) * out)
            parts.append(Clay.limb(Clay.bow(at, v(cos(a) * 0.05, 0, sin(a) * 0.05)), 0.024, 0.02, green.0, green.1, sides: 5, rings: 6).shape)
            // The head's lowest florets fade first, pink-brown under the white.
            parts.append(Clay.blob(at: at + v(0, 0.05, 0), size: Vec3(0.1, 0.09, 0.1), color: 0xc9a39a, top: 0xfbfaf2, lumpy: 0.25))
        }
        return Plant(shape: Geometry.join(parts), top: v(0.1, 0.82, 0.1))
    }
}
