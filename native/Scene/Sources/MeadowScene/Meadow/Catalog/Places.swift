import Foundation
import simd

// The meadow editor's places: a garden shed and a canvas tent, little buildings of their own, cat-sized (a person's
// shed drawn as a cat would use it, as the Workplace's things are) and never scaled. Big things: kept off the picnic
// ground, and tall, so each fades when it stands in front of a cat. Each built in the swatch asked for (`Palette`).

enum Places {
    private static func v(_ x: Float, _ y: Float, _ z: Float) -> Vec3 { Vec3(x, y, z) }

    private static func board(_ size: Vec3, _ at: Vec3, _ colour: (UInt32, UInt32), radius: Float = 0.04, turn: Vec3 = .zero) -> Geometry {
        var g = Shapes.roundedBox(size.x, size.y, size.z, segments: 1, radius: min(radius, size.x / 2, size.y / 2, size.z / 2))
        g.paint(colour.0, colour.1)
        g.apply(.compose(at, euler: turn))
        return g
    }

    /// A wall of horizontal shiplap facing +z at z = 0, `width` across, from `foot` up to `top(x)` (a gable's
    /// slope, or the eaves): each board's lower edge stands proud of the one below, so the light draws a line
    /// under every board.
    static func cladding(width: Float, foot: Float, board: Float, top: (Float) -> Float, _ colour: (UInt32, UInt32)) -> Geometry {
        var g = Geometry()
        let columns = 8, low: Vec3 = linear(colour.0), high: Vec3 = linear(colour.1)
        func at(_ c: Int) -> Float { -width / 2 + width * Float(c) / Float(columns) }
        var highest = foot
        for c in 0...columns { highest = max(highest, top(at(c))) }
        let rise: Float = max(highest - foot, 1e-3)
        let boards = Int(((highest - foot) / board).rounded(.up))
        for b in 0..<boards {
            let y0: Float = foot + Float(b) * board, y1: Float = y0 + board
            let base = UInt32(g.positions.count)
            // Each board a touch different, as boards are.
            let shade: Float = 0.94 + 0.08 * abs(sin(Float(b) * 2.7))
            for c in 0...columns {
                let x = at(c), t = top(x)
                let lowY = min(y0, t), highY = min(y1, t)
                g.positions.append(v(x, lowY, 0.035))
                g.positions.append(v(x, highY, 0))
                g.colors.append(mix(low, high, t: (lowY - foot) / rise) * shade)
                g.colors.append(mix(low, high, t: (highY - foot) / rise) * shade)
            }
            for c in 0..<UInt32(columns) {
                let a = base + c * 2
                g.indices += [a, a + 2, a + 1, a + 1, a + 2, a + 3]
            }
        }
        g.computeNormals()
        return g
    }

    /// A small apex garden shed: walls of honey-stained shiplap on a plinth of bearers, a felted roof overhanging
    /// at the eaves with cream barge boards and corner trims, a ledged and braced door on the gable end in the
    /// chosen colour (sage its own) with black strap hinges and a turn button, and on its side a four-paned window
    /// with a window box of flowers in the same colour.
    static func shed(_ swatch: Int) -> Plant {
        let clay = Palette.clay("place.shed", swatch), paint = (clay.shade, clay.light)
        let w: Float = 4.4, d: Float = 3.4, plinth: Float = 0.16, eaves: Float = 3.9, ridge: Float = 5.2
        let stain: (UInt32, UInt32) = (0x9a7650, 0xc4a476), trim: (UInt32, UInt32) = (0xe3d8c4, 0xf7f1e4), iron: (UInt32, UInt32) = (0x2f2e2c, 0x4a4844)
        var parts: [Geometry] = [board(v(w + 0.2, plinth, d + 0.2), v(0, plinth / 2 - 0.04, 0), (0x4f4234, 0x6c5a48), radius: 0.03)]
        let gable: (Float) -> Float = { x in eaves + (ridge - eaves) * (1 - abs(x) / (w / 2)) }
        let level: (Float) -> Float = { _ in eaves }
        // Front and back (the gables), then the sides.
        parts.append(cladding(width: w, foot: plinth, board: 0.34, top: gable, stain).applied(.translation(v(0, 0, d / 2))))
        parts.append(cladding(width: w, foot: plinth, board: 0.34, top: gable, stain).applied(.compose(v(0, 0, -d / 2), euler: v(0, .pi, 0))))
        parts.append(cladding(width: d, foot: plinth, board: 0.34, top: level, stain).applied(.compose(v(w / 2, 0, 0), euler: v(0, .pi / 2, 0))))
        parts.append(cladding(width: d, foot: plinth, board: 0.34, top: level, stain).applied(.compose(v(-w / 2, 0, 0), euler: v(0, -.pi / 2, 0))))
        for x: Float in [-1, 1] {
            for z: Float in [-1, 1] { parts.append(board(v(0.16, eaves - plinth, 0.16), v(x * w / 2, (eaves + plinth) / 2, z * d / 2), trim)) }
        }
        // The roof: two felted slopes meeting at the ridge, past the walls all round.
        let slope = hypot(w / 2, ridge - eaves), pitch = atan2(ridge - eaves, w / 2)
        for s: Float in [-1, 1] {
            parts.append(board(v(slope + 0.45, 0.14, d + 0.6), v(s * (w / 4 + 0.1), (eaves + ridge) / 2 + 0.1, 0), (0x46504a, 0x66706a), radius: 0.05, turn: v(0, 0, -s * pitch)))
            // Barge boards along the gables' slopes, front and back.
            for z: Float in [-1, 1] {
                parts.append(board(v(slope + 0.4, 0.22, 0.07), v(s * (w / 4 + 0.08), (eaves + ridge) / 2 - 0.03, z * (d / 2 + 0.31)), trim, radius: 0.03, turn: v(0, 0, -s * pitch)))
            }
        }
        parts.append(board(v(0.2, 0.16, d + 0.66), v(0, ridge + 0.18, 0), (0x3c4540, 0x56605a), radius: 0.06))
        // The door on the gable end: boards, then its three ledges and brace, in the chosen colour.
        let door = (w: Float(1.5), h: Float(2.9)), front = d / 2 + 0.04
        parts.append(board(v(door.w + 0.24, door.h + 0.14, 0.06), v(0, plinth + door.h / 2 + 0.05, front - 0.02), trim, radius: 0.03))
        var boards = Shapes.roundedBox(door.w, door.h, 0.08, segments: 1, radius: 0.03)
        boards.translate(0, plinth + door.h / 2, front)
        boards.colors = boards.positions.map { p in mix(linear(paint.0), linear(paint.1), t: (p.y - plinth) / door.h) * (0.95 + 0.06 * (cos(p.x / door.w * 5 * 2 * .pi) > 0.92 ? -1 : 0.3)) }
        parts.append(boards)
        for y in [0.35, door.h / 2, door.h - 0.35] { parts.append(board(v(door.w - 0.2, 0.2, 0.06), v(0, plinth + y, front + 0.06), paint, radius: 0.03)) }
        let brace = hypot(door.w - 0.4, door.h / 2 - 0.35), lean = atan2(door.h / 2 - 0.35, door.w - 0.4)
        for half: Float in [0, 1] {
            parts.append(board(v(brace, 0.17, 0.05), v(0, plinth + 0.35 + (door.h / 2 - 0.35) * (half + 0.5), front + 0.06), paint, radius: 0.025, turn: v(0, 0, lean)))
        }
        for y in [0.35, door.h - 0.35] { parts.append(board(v(0.85, 0.08, 0.03), v(-door.w / 2 + 0.38, plinth + y, front + 0.1), iron, radius: 0.012)) }
        parts.append(board(v(0.08, 0.26, 0.05), v(door.w / 2 - 0.15, plinth + door.h / 2 + 0.25, front + 0.11), iron, radius: 0.02))
        // The window on the side, four panes in a cream frame, with its window box of flowers.
        let side = w / 2 + 0.04, sill: Float = 2.05, win = (w: Float(1.5), h: Float(1.05))
        parts.append(board(v(0.08, win.h + 0.2, win.w + 0.2), v(side, sill + win.h / 2, 0), trim, radius: 0.03))
        for (row, col) in [(0, 0), (0, 1), (1, 0), (1, 1)] {
            let pane = Shapes.roundedBox(0.04, win.h / 2 - 0.1, win.w / 2 - 0.1, segments: 1, radius: 0.015)
            let at = v(side + 0.04, sill + 0.05 + (Float(row) + 0.5) * (win.h / 2), (Float(col) - 0.5) * (win.w / 2))
            var glass = pane.applied(.translation(at))
            // Dark glass catching the sky toward its top.
            glass.colors = glass.positions.map { p in mix(linear(0x2c3a42), linear(0x7f99a6), t: smoothstep(p.y - at.y + (p.z - at.z) * 0.6, -0.1, 0.3)) }
            parts.append(glass.roughened(0.2))
        }
        parts.append(board(v(0.12, 0.1, win.w + 0.4), v(side + 0.06, sill - 0.08, 0), trim, radius: 0.03))
        parts.append(board(v(0.4, 0.34, win.w + 0.1), v(side + 0.24, sill - 0.36, 0), paint, radius: 0.04))
        for k in 0..<9 {
            let z = -win.w / 2 + 0.12 + Float(k) * (win.w - 0.24) / 8
            let bloom: (UInt32, UInt32) = k % 3 == 0 ? (0xe27e98, 0xf6b3c2) : k % 3 == 1 ? (0xf2ece0, 0xffffff) : (0xa596cc, 0xcbbfe6)
            parts.append(Clay.blob(at: v(side + 0.24, sill - 0.12 + 0.05 * Float(k % 2), z), size: v(0.17, 0.13, 0.13), color: 0x4f7f34, top: 0x7aab4e, lumpy: 0.15))
            parts.append(Clay.blob(at: v(side + 0.26 + 0.05 * Float(k % 2), sill + 0.04 + 0.04 * Float(k % 3), z), size: v(0.09, 0.08, 0.09), color: bloom.0, top: bloom.1))
        }
        return Plant(shape: Geometry.join(parts).roughened(0.85), top: v(0, ridge, 0))
    }

    /// A cotton ridge tent for two in a swatch of its palette (natural canvas its own): short walls rising to a
    /// steep ridge carried on two wooden uprights, its front's two door flaps rolled back and tied to its sides so the
    /// shade inside shows, the uprights' spikes standing out over the ridge, wooden pegs holding its walls down.
    static func tent(_ swatch: Int) -> Plant {
        let clay = Palette.clay("place.tent", swatch)
        let wide: Float = 3.8, long: Float = 4.8, wall: Float = 0.45, ridge: Float = 3.3
        var parts: [Geometry] = []
        let outline = [Vec2(-wide / 2, 0), Vec2(wide / 2, 0), Vec2(wide / 2, wall), Vec2(0, ridge), Vec2(-wide / 2, wall)]
        var canvas = Clay.pressed(outline, thick: long, soft: 0.05, clay.shade, clay.light)
        // Weathered toward the ground, paler along the ridge where the sun bleaches it.
        canvas.colors = canvas.positions.map { p in mix(linear(clay.shade) * 0.9, linear(clay.light), t: smoothstep(p.y, 0, ridge)) }
        parts.append(canvas.roughened(1))
        // The way in: the dark inside, framed by the flaps rolled back to each side and tied.
        // Out past the canvas's soft edge (the press's bevel stands proud of its length).
        let front = long / 2 + 0.1
        let door = Clay.pressed([Vec2(-1.2, 0), Vec2(1.2, 0), Vec2(0, ridge - 0.3)], thick: 0.02, soft: 0.005, 0x2e2820, 0x463c30)
        parts.append(door.applied(.translation(v(0, 0.02, front))).roughened(1))
        for s: Float in [-1, 1] {
            // The roll shows the canvas's inside, a shade deeper.
            let roll = Clay.limb(QuadraticBezier(v(s * 0.1, ridge - 0.35, front + 0.08), v(s * 0.85, 1.7, front + 0.14), v(s * 1.35, 0.3, front + 0.08)), 0.15, 0.2,
                                 clay.shade, clay.light, sides: 10, rings: 10)
            parts.append(roll.shape.tinted(0.86).roughened(1))
            for t: Float in [0.35, 0.72] {
                let at = roll.curve.pointAt(t)
                parts.append(Shapes.torus(0.17, 0.035, 6, 14).applied(.compose(at, euler: v(0, 0, s * (0.6 + t)))).painted(0x8a7a5c, 0xa8987a))
            }
        }
        // The uprights, the front one in the doorway, and their spikes through the ridge.
        for z: Float in [-1, 1] {
            parts.append(Clay.limb(QuadraticBezier(v(0, 0, z * (long / 2 - 0.12)), v(0, ridge / 2, z * (long / 2 - 0.12)), v(0, ridge + 0.32, z * (long / 2 - 0.12))), 0.075, 0.06,
                                   0x8a6a48, 0xa8865e, sides: 8, rings: 6).shape.roughened(0.85))
            parts.append(Clay.blob(at: v(0, ridge + 0.34, z * (long / 2 - 0.12)), size: v(0.05, 0.1, 0.05), color: 0x4a4844, top: 0x6a6864))
        }
        // Pegs at the walls' feet.
        for x: Float in [-1, 1] {
            for z in [-long / 2, 0, long / 2] {
                parts.append(Clay.limb(QuadraticBezier(v(x * (wide / 2 + 0.25), -0.05, z), v(x * (wide / 2 + 0.25), 0.1, z), v(x * (wide / 2 + 0.22), 0.26, z)), 0.06, 0.05,
                                       0xa8865e, 0xc4a276, sides: 6, rings: 3).shape.roughened(0.9))
            }
        }
        return Plant(shape: Geometry.join(parts), top: v(0, ridge, 0))
    }
}
