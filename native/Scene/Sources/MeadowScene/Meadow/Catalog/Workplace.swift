import Foundation
import simd

// The meadow editor's Workplace things: made things, cat-sized and never scaled, each modelled on the real
// thing, then simplified into the meadow's clay. Cat-sized: what a person uses, drawn as a cat would use it, at
// about a fortieth of a unit to a centimetre (a bench's seat 43 cm high stands 1.1 units, a stump's height). Those
// with a palette are built in the swatch asked for (`Palette`), the first their own. Nothing here is a working cat's
// prop (no laptop, book or paper lying loose, docs/DESIGN.md rule 8): books stand on a shelf, paper is pinned to a
// board.

enum Workplace {
    private static func v(_ x: Float, _ y: Float, _ z: Float) -> Vec3 { Vec3(x, y, z) }

    /// A box of `size` with soft edges, its middle at `at`, painted from `colour.0` at its foot to `colour.1` at its top.
    private static func board(_ size: Vec3, _ at: Vec3, _ colour: (UInt32, UInt32), radius: Float = 0.04, turn: Vec3 = .zero) -> Geometry {
        var g = Shapes.roundedBox(size.x, size.y, size.z, segments: 1, radius: min(radius, size.x / 2, size.y / 2, size.z / 2))
        g.paint(colour.0, colour.1)
        g.apply(.compose(at, euler: turn))
        return g
    }

    /// Warm oiled wood for furniture (the desk, the shelf), and its darker end grain and shadows.
    static let oiled: (UInt32, UInt32) = (0x8a5a34, 0xb57f4e)

    /// A square floor cushion (a zabuton) in a swatch of its palette (oat its own) a cat can sit on: the picnic's
    /// cushion made big enough for one, plump in the middle and thinner at its seams, tufted at the centre with a
    /// little tie.
    static func cushion(_ swatch: Int) -> Plant {
        let clay = Palette.clay("work.cushion", swatch)
        var soft = Picnic.cushion()
        soft.apply(.scale(Vec3(2.3, 1.45, 2.3)))
        soft.paint(clay.shade, clay.light)
        let tie = (0..<3).map { k -> Geometry in
            let a = Float(k) / 3 * 2 * .pi
            return Clay.blob(at: Vec3(cos(a) * 0.06, 0.62, sin(a) * 0.06), size: Vec3(0.09, 0.045, 0.045), color: clay.shade, top: clay.shade, turn: Vec3(0, -a, 0)).tinted(0.78)
        }
        return Plant(shape: Geometry.join([soft] + tie).roughened(0.95), top: Vec3(0, 0.75, 0))
    }

    /// A low writing desk (a zataku, made for sitting at on a floor cushion): a thick oiled top on four square legs
    /// tapering to the ground, an apron with one shallow drawer in its middle and a round brass knob; on it a mug of
    /// tea and a little potted plant at the back corner, nothing a working cat would carry.
    static let desk: Plant = {
        let w: Float = 3.0, d: Float = 1.6, top: Float = 1.36, thick: Float = 0.13
        var parts: [Geometry] = [board(v(w, thick, d), v(0, top - thick / 2, 0), (0x9c6a3e, 0xc48d58), radius: 0.06)]
        for x: Float in [-1, 1] {
            for z: Float in [-1, 1] {
                let rings = [Clay.Ring(w: 0.07, d: 0.07, y: 0), Clay.Ring(w: 0.1, d: 0.1, y: top - thick - 0.2), Clay.Ring(w: 0.1, d: 0.1, y: top - thick)]
                parts.append(Clay.stacked(rings, around: 12, square: 6) { _, _ in 0 }.painted(oiled.0, oiled.1).applied(.translation(v(x * (w / 2 - 0.2), 0, z * (d / 2 - 0.2)))))
            }
        }
        // The apron round the legs' tops, and the drawer's front in it, a hair proud, with its knob.
        let apron: Float = 0.24, y = top - thick - apron / 2
        parts.append(board(v(w - 0.4, apron, 0.06), v(0, y, d / 2 - 0.2), oiled))
        parts.append(board(v(w - 0.4, apron, 0.06), v(0, y, -d / 2 + 0.2), oiled))
        parts.append(board(v(0.06, apron, d - 0.4), v(w / 2 - 0.2, y, 0), oiled))
        parts.append(board(v(0.06, apron, d - 0.4), v(-w / 2 + 0.2, y, 0), oiled))
        parts.append(board(v(1.2, apron - 0.06, 0.04), v(0, y, d / 2 - 0.16), (0xa77344, 0xc99460), radius: 0.02))
        parts.append(Clay.blob(at: v(0, y, d / 2 - 0.12), size: v(0.06, 0.06, 0.05), color: 0xa98236, top: 0xe2c36e).roughened(0.35))
        // A mug, cream glazed, with its handle and tea in it.
        let mug = Clay.thrown([Vec2(0, 0), Vec2(0.15, 0), Vec2(0.16, 0.02), Vec2(0.16, 0.3), Vec2(0.14, 0.31), Vec2(0.13, 0.05), Vec2(0, 0.05)], 0xe3d8c4, 0xf7f1e4, around: 16, steps: 10)
        let at = v(0.85, top, 0.25)
        parts.append(mug.applied(.translation(at)).roughened(0.4))
        parts.append(Clay.blob(at: at + v(0, 0.25, 0), size: v(0.13, 0.01, 0.13), color: 0x7a4e2c).roughened(0.3))
        parts.append(Shapes.torus(0.075, 0.025, 6, 12, arc: .pi * 1.2).applied(.compose(at + v(0.16, 0.16, 0), euler: v(0, 0, -.pi * 0.6))).painted(0xe3d8c4, 0xf7f1e4).roughened(0.4))
        // A little potted plant at the back corner.
        let pot = Clay.thrown([Vec2(0, 0), Vec2(0.13, 0), Vec2(0.18, 0.24), Vec2(0.2, 0.26), Vec2(0.19, 0.3), Vec2(0, 0.28)], 0xb4643f, 0xd68a5e, around: 16, steps: 10)
        let corner = v(-1.05, top, -0.42)
        parts.append(pot.applied(.translation(corner)).roughened(0.95))
        for k in 0..<6 {
            let a = Float(k) * 2.399963
            parts.append(Clay.blob(at: corner + v(cos(a) * 0.09, 0.4 + 0.05 * Float(k % 3), sin(a) * 0.09), size: v(0.07, 0.15, 0.04), color: 0x4f7f34, top: 0x86b55a,
                                   turn: v(0.5 * sin(a), a, 0.5 * cos(a))).roughened(0.85))
        }
        return Plant(shape: Geometry.join(parts).roughened(0.7), top: v(0, top, 0))
    }()

    /// A small bookcase, three shelves and its top: an oiled carcass with a back, rows of cloth-bound books in muted
    /// colours of varied height and thickness, the last of a row leaning, a few lying flat in a stack, and a trailing
    /// plant in a pot on its top.
    static let bookshelf: Plant = {
        let w: Float = 2.6, d: Float = 0.9, tall: Float = 3.3, side: Float = 0.12
        var parts: [Geometry] = []
        parts.append(board(v(side, tall, d), v(-w / 2 + side / 2, tall / 2, 0), oiled))
        parts.append(board(v(side, tall, d), v(w / 2 - side / 2, tall / 2, 0), oiled))
        parts.append(board(v(w, side, d + 0.04), v(0, tall - side / 2, 0.02), (0x9c6a3e, 0xc48d58), radius: 0.04))
        parts.append(board(v(w - 2 * side, 0.05, 0.02), v(0, tall / 2, -d / 2 + 0.02), (0x5e3c22, 0x7a5232)))
        parts.append(board(v(w - 2 * side, tall - 0.06, 0.04), v(0, tall / 2, -d / 2 + 0.02), (0x6e4a2c, 0x8a5e3a)))
        let shelves: [Float] = [0.18, 1.2, 2.22]
        for y in shelves { parts.append(board(v(w - 2 * side, 0.09, d - 0.04), v(0, y, 0), (0x9c6a3e, 0xc48d58))) }
        // Spines in old cloth colours: wine, bottle green, mustard, navy, cream, tan, slate, rose.
        let spines: [(UInt32, UInt32)] = [(0x6e3444, 0x8a4a5a), (0x2c5543, 0x416e5a), (0xb98a2e, 0xd6a84a), (0x2f3a56, 0x46526e), (0xcfc3a8, 0xe6dcc6),
                                          (0x9a6e46, 0xb88a5e), (0x5c6670, 0x7a848e), (0xb07070, 0xcc8e8a)]
        var seed: UInt32 = 7
        func roll() -> Float { seed = seed &* 1_664_525 &+ 1_013_904_223; return Float(seed >> 8) / Float(1 << 24) }
        for (row, y) in shelves.enumerated() {
            var x = -w / 2 + side + 0.04
            let end = w / 2 - side - (row == 1 ? 0.75 : 0.25)
            var k = row * 3
            while x < end - 0.12 {
                let thick = 0.13 + 0.09 * roll(), high = 0.62 + 0.24 * roll(), deep = 0.5 + 0.12 * roll()
                parts.append(board(v(thick, high, deep), v(x + thick / 2, y + 0.045 + high / 2, 0.08), spines[k % spines.count], radius: 0.025))
                x += thick + 0.008
                k += 1 + Int(roll() * 2)
            }
            // The last of the row leaning on it.
            let lean: Float = 0.32, high: Float = 0.7
            parts.append(board(v(0.14, high, 0.56), v(x + 0.07 + sin(lean) * high / 2, y + 0.045 + cos(lean) * high / 2, 0.08), spines[(k + 2) % spines.count],
                               radius: 0.025, turn: v(0, 0, -lean)))
            if row == 1 {
                // A few lying flat in a stack at the row's end.
                for s in 0..<3 {
                    parts.append(board(v(0.6 - 0.06 * Float(s), 0.12, 0.5), v(w / 2 - side - 0.4, y + 0.11 + Float(s) * 0.125, 0.06), spines[(s * 3 + 1) % spines.count],
                                       radius: 0.025, turn: v(0, 0.12 * Float(s) - 0.1, 0)))
                }
            }
        }
        // A trailing plant on top, its leaves spilling over the edge.
        let pot = Clay.thrown([Vec2(0, 0), Vec2(0.17, 0), Vec2(0.23, 0.3), Vec2(0.25, 0.32), Vec2(0.24, 0.36), Vec2(0, 0.34)], 0xe3d8c4, 0xf7f1e4, around: 16, steps: 10)
        let at = v(0.7, tall, 0.05)
        parts.append(pot.applied(.translation(at)).roughened(0.45))
        for k in 0..<9 {
            let a = Float(k) * 2.399963, out = 0.14 + 0.05 * Float(k % 3), droop = k > 5 ? Float(k - 5) * 0.22 : 0
            parts.append(Clay.blob(at: at + v(cos(a) * out + (k > 5 ? 0.15 : 0), 0.4 - droop, sin(a) * out + (k > 5 ? 0.3 : 0)), size: v(0.1, 0.05, 0.08), color: 0x4f7f34, top: 0x86b55a,
                                   turn: v(0.4, a, 0.2)).roughened(0.85))
        }
        return Plant(shape: Geometry.join(parts).roughened(0.75), top: v(0, tall, 0))
    }()

    /// A two-seater garden bench in a swatch of its palette (oiled wood its own): four seat slats along it, three
    /// back slats between curved back rails, two side frames whose back legs rise to carry the back and whose arms
    /// sweep forward over the front legs.
    static func bench(_ swatch: Int) -> Plant {
        let clay = Palette.clay("work.bench", swatch)
        let paint = (clay.shade, clay.light), length: Float = 4.2, seat: Float = 1.1, deep: Float = 1.2
        var parts: [Geometry] = []
        for k in 0..<4 {
            let z = deep / 2 - 0.16 - Float(k) * 0.29
            parts.append(board(v(length, 0.1, 0.24), v(0, seat - 0.05, z), paint, radius: 0.04))
        }
        // The back: three slats leaning back a little, above the seat.
        let lean: Float = 0.2
        for k in 0..<3 {
            let up = seat + 0.38 + Float(k) * 0.34
            parts.append(board(v(length, 0.22, 0.08), v(0, up, -deep / 2 + 0.1 - sin(lean) * (up - seat)), paint, radius: 0.035, turn: v(-lean, 0, 0)))
        }
        for x: Float in [-1, 1] {
            let side = x * (length / 2 - 0.12)
            // Front leg, up to the arm.
            parts.append(board(v(0.16, seat + 0.62, 0.16), v(side, (seat + 0.62) / 2, deep / 2 - 0.12), paint))
            // Back leg, raking back as it rises to carry the back.
            let back = Clay.limb(QuadraticBezier(v(side, 0, -deep / 2 + 0.16), v(side, seat, -deep / 2 + 0.12), v(side, seat + 1.32, -deep / 2 - 0.2)), 0.09, 0.08, clay.shade, clay.light, sides: 6, rings: 6)
            parts.append(back.shape)
            // Seat rail and the arm, sweeping over the front leg.
            parts.append(board(v(0.12, 0.16, deep - 0.1), v(side, seat - 0.18, 0), paint))
            parts.append(board(v(0.2, 0.09, deep + 0.05), v(side, seat + 0.66, 0.02), paint, radius: 0.04, turn: v(-0.08, 0, 0)))
            // A stretcher low between the legs.
            parts.append(board(v(0.09, 0.09, deep - 0.3), v(side, 0.3, 0), paint))
        }
        return Plant(shape: Geometry.join(parts).roughened(swatch == 0 ? 0.75 : 0.65), top: v(0, seat, 0))
    }

    /// A fingerpost at a path's turning: a square oak post with a ball finial, a collar holding two arms that point
    /// different ways, each arm a cream board with an arrow's point and two carved grooves where words would be (none
    /// is written, docs/DESIGN.md rule 5).
    static let signpost: Plant = {
        let tall: Float = 4.4
        var parts: [Geometry] = [board(v(0.24, tall + 0.1, 0.24), v(0, tall / 2 - 0.05, 0), (Fences.wood.foot, Fences.wood.top), radius: 0.05)]
        parts.append(Clay.thrown([Vec2(0, 0), Vec2(0.16, 0), Vec2(0.07, 0.07), Vec2(0.13, 0.17), Vec2(0.1, 0.27), Vec2(0, 0.29)], Fences.wood.body, Fences.wood.top, around: 14, steps: 12)
            .applied(.translation(v(0, tall, 0))))
        parts.append(board(v(0.32, 0.34, 0.32), v(0, tall - 0.42, 0), (0x5f5446, 0x7a6d5c), radius: 0.04))
        for (k, (turn, y)) in [(Float(0.35), tall - 0.42 + 0.0), (Float(-2.3), tall - 0.95)].enumerated() {
            let long: Float = 1.75, high: Float = 0.38
            let outline = [Vec2(0, -high / 2), Vec2(long - 0.3, -high / 2), Vec2(long, 0), Vec2(long - 0.3, high / 2), Vec2(0, high / 2)]
            var arm = Clay.pressed(outline, thick: 0.09, soft: 0.025, 0xd9cfb8, 0xf0e8d6)
            // Two carved grooves along the arm, darker, where a place's name would be routed.
            for g in [Float(-0.07), 0.07] {
                var groove = Shapes.roundedBox(long - 0.6 - (k == 1 && g > 0 ? 0.3 : 0), 0.04, 0.1, segments: 1, radius: 0.015)
                groove.translate(0.2 + (long - 0.6) / 2, g, 0)
                arm = Geometry.join([arm, groove.painted(0x8a8170, 0x9a917e)])
            }
            parts.append(arm.applied(.compose(v(0, y, 0), euler: v(0, turn, 0)) * .translation(v(0.12, 0, 0))))
        }
        return Plant(shape: Geometry.join(parts).roughened(0.85), top: v(0, tall + 0.3, 0))
    }()

    /// A post-mounted rural mailbox in a swatch of its palette (forest its own): a flat-sided box under a half-round
    /// tunnel roof, its front door hinged at the foot with a little pull, the signal flag on its right side, raised;
    /// on a square post with a short arm under the box.
    static func mailbox(_ swatch: Int) -> Plant {
        let clay = Palette.clay("work.mailbox", swatch)
        let post: Float = 2.6, long: Float = 1.3, wide: Float = 0.48, side: Float = 0.3
        var parts: [Geometry] = [board(v(0.26, post, 0.26), v(0, post / 2 - 0.08, -0.15), (Fences.wood.foot, Fences.wood.top), radius: 0.05)]
        parts.append(board(v(0.18, 0.12, long * 0.8), v(0, post - 0.06, 0), (Fences.wood.body, Fences.wood.top), radius: 0.04))
        var outline: [Vec2] = [Vec2(-wide / 2, 0), Vec2(wide / 2, 0), Vec2(wide / 2, side)]
        for k in 1..<12 {
            let a = Float(k) / 12 * .pi
            outline.append(Vec2(cos(a) * wide / 2, side + sin(a) * wide / 2))
        }
        outline.append(Vec2(-wide / 2, side))
        let body = Clay.pressed(outline, thick: long, soft: 0.04, clay.shade, clay.light)
        parts.append(body.applied(.translation(v(0, post, 0))))
        // The door: a slightly larger lip at the front, a shade deeper, and its pull.
        let door = Clay.pressed(outline.map { $0 * 1.04 + Vec2(0, -0.005) }, thick: 0.05, soft: 0.02, clay.shade, clay.light).tinted(0.9)
        parts.append(door.applied(.translation(v(0, post, long / 2))))
        parts.append(Clay.blob(at: v(0, post + side + 0.08, long / 2 + 0.05), size: v(0.07, 0.04, 0.04), color: 0x6a6a70, top: 0xa8a8ae).roughened(0.4))
        // The flag, up: its arm pivoting on the right side and a square plate, in a colour of its own to be seen.
        let flag: (UInt32, UInt32) = swatch == 3 ? (0x3f6a52, 0x5f8c6c) : (0xc99a3c, 0xe8c066)
        parts.append(board(v(0.04, 0.62, 0.07), v(wide / 2 + 0.04, post + 0.42, -0.25), flag, radius: 0.02))
        parts.append(board(v(0.04, 0.24, 0.32), v(wide / 2 + 0.04, post + 0.66, -0.12), flag, radius: 0.02))
        parts.append(Clay.blob(at: v(wide / 2 + 0.06, post + 0.16, -0.25), size: v(0.04, 0.05, 0.05), color: 0x4a4a50, top: 0x6a6a70))
        return Plant(shape: Geometry.join(parts).roughened(0.6), top: v(0, post + side + wide / 2, 0))
    }

    /// A noticeboard as villages and gardens keep them: a cork board in an oak frame on two posts, under a little
    /// pitched roof that keeps the rain off, blank notices pinned on it askew with coloured drawing pins.
    static let noticeboard: Plant = {
        let w: Float = 2.4, h: Float = 1.6, low: Float = 1.35, tall: Float = 3.45
        var parts: [Geometry] = []
        for x: Float in [-1, 1] { parts.append(board(v(0.2, tall + 0.1, 0.2), v(x * (w / 2 + 0.06), tall / 2 - 0.05, 0), (Fences.wood.foot, Fences.wood.top), radius: 0.05)) }
        // The frame, then the cork inside it, speckled.
        parts.append(board(v(w + 0.1, h + 0.16, 0.16), v(0, low + h / 2, 0), (0x7c6a56, 0xa08c72), radius: 0.05))
        var cork = Shapes.roundedBox(w - 0.14, h - 0.12, 0.04, segments: 2, radius: 0.015)
        cork.translate(0, low + h / 2, 0.075)
        cork.colors = cork.positions.map { p in linear(0xb98a5a) * (0.92 + 0.12 * sin(p.x * 37 + sin(p.y * 29) * 3) * sin(p.y * 23 + p.x * 11)) }
        parts.append(cork)
        // The roof: two boards meeting over the posts, overhanging front and back.
        for s: Float in [-1, 1] {
            parts.append(board(v(w + 0.6, 0.08, 0.46), v(0, tall - 0.08, s * 0.2), (0x5f5446, 0x7a6d5c), radius: 0.03, turn: v(s * 0.5, 0, 0)))
        }
        parts.append(board(v(w + 0.3, 0.12, 0.12), v(0, tall - 0.3, 0), (Fences.wood.body, Fences.wood.top)))
        // Notices: blank papers, a little askew, each with its pin.
        let notes: [(Float, Float, Float, Float, Float, UInt32, UInt32)] = [(-0.62, 0.35, 0.62, 0.8, 0.06, 0xf4efe2, 0x5f8c6c),
                                                                             (0.15, 0.55, 0.56, 0.62, -0.08, 0xf2e4c8, 0xd98c8e),
                                                                             (0.72, 0.28, 0.5, 0.56, 0.1, 0xe6eee0, 0xc99a3c),
                                                                             (0.05, -0.32, 0.8, 0.46, 0.03, 0xf4efe2, 0xa596cc)]
        for (x, y, nw, nh, turn, paper, pin) in notes {
            let at = v(x, low + h / 2 + y - 0.1, 0.1)
            parts.append(board(v(nw, nh, 0.02), at, (paper, paper), radius: 0.008, turn: v(0, 0, turn)))
            parts.append(Clay.blob(at: at + v(-sin(turn) * nh * 0.38, cos(turn) * nh * 0.38, 0.03), size: v(0.05, 0.05, 0.04), color: pin, top: pin).roughened(0.4))
        }
        return Plant(shape: Geometry.join(parts).roughened(0.85), top: v(0, tall, 0))
    }()
}
