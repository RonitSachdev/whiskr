import Foundation
import simd

// The camp kettle on a plain terminal's blanket (docs/DESIGN.md, "Plain terminals"): a blanket whose
// terminals have no Claude is not left empty. A small enamel kettle stands on a little brass stove beside the
// hamper and shows what the shell's command marks (OSC 133) say: cold while the shell waits, lit and
// rattling with steam while a command runs (calming to a steady simmer for a long one, a dev server), one
// whistle of steam as it finishes well and the flame goes out, or the flame snuffed with a small dark puff
// and a little red flag by it when it fails, until you look at that terminal.
//
// Modelled on real camp kettles and stoves, then simplified into clay: a squat enamel kettle wider at the
// base, a short spout angled up from low on its side, a lid with a round knob under a wire bail with a
// wooden grip running front to back, black rims; a brass pressure stove (a squat tank, a burner on a short
// column, three dark pot supports) with a ring of small blue flames, and, turned up while it boils, tongues
// of yellow flame licking up round the kettle's base, which is what shows from above.

/// How large the kettle and its stove are drawn, as the picnic things are (`TREAT_SIZE`).
let KETTLE_SIZE: Float = 2.4
/// The ground the kettle and its stove stand on, for keeping cats, the picnic and lanterns clear of it,
/// with room beside it for its flag.
let KETTLE_REACH: Float = 1.5
/// A command running this long has stopped rattling: a steady simmer, which lets the meadow rest.
let KETTLE_BOIL: Float = 30
/// The flame has to have burned this long for the kettle to whistle when the command ends: a command over
/// in a moment (an `ls`) puts the flame out quietly.
let KETTLE_WHISTLE_AFTER: Float = 1.5
/// Steam puffs a kettle keeps track of.
let KETTLE_PUFFS = 22

enum Kettle {
    private static func v(_ x: Float, _ y: Float, _ z: Float) -> Vec3 { Vec3(x, y, z) }
    private static func p(_ list: [(Float, Float)]) -> [Vec2] { list.map { Vec2($0.0, $0.1) } }

    // The enamel's own small palette: a soft camp green, black rims and bail, a wooden grip.
    static let enamel: (UInt32, UInt32) = (0x3b7466, 0x5e9a88)
    static let rim: (UInt32, UInt32) = (0x23252a, 0x3a3d44)
    static let brass: (UInt32, UInt32) = (0x8f6c2c, 0xcfa653)
    /// Where the kettle's base sits on its stove, in its own units.
    static let base: Float = 0.36
    /// The spout's mouth, where steam leaves, and which way it points.
    static let spoutTip = Vec3(0.64, base + 0.4, 0)
    static let spoutOut = simd_normalize(Vec3(0.55, 1, 0))
    /// The lid's seat, where it rattles.
    static let lidSeat = Vec3(0, base + 0.37, 0)
    /// Under the kettle, where the flames burn and the snuffed stove's puff comes from.
    static let burner = Vec3(0, 0.31, 0)
    /// Where the flag stands, beside the kettle on the side away from its spout.
    static let flagFoot = Vec3(-0.62, 0, 0.32)

    /// The stove and the kettle without its lid: one mesh.
    static func body() -> Geometry {
        let b = base
        var parts: [Geometry] = [
            // The stove's brass tank, a short column and the burner's dark head.
            Clay.thrown(p([(0, 0), (0.2, 0), (0.225, 0.02), (0.232, 0.15), (0.215, 0.19), (0.13, 0.21), (0, 0.212)]), brass.0, brass.1, around: 24),
            Clay.thrown(p([(0, 0.2), (0.05, 0.2), (0.045, 0.29), (0, 0.29)]), 0x6d5222, 0x9c7a35, around: 12, steps: 6),
            Clay.thrown(p([(0, 0.28), (0.09, 0.28), (0.1, 0.3), (0.06, 0.315), (0, 0.315)]), rim.0, rim.1, around: 16, steps: 6),
            // The kettle: squat, widest low down, its shoulder rolling in to the lid's seat.
            Clay.thrown(p([(0, b), (0.33, b), (0.4, b + 0.03), (0.425, b + 0.13), (0.405, b + 0.26), (0.34, b + 0.335), (0.23, b + 0.37), (0, b + 0.37)]),
                        0x2f5e53, enamel.1, around: 32, steps: 24),
            // A black rim round the lid's seat.
            Clay.thrown(p([(0.2, b + 0.355), (0.235, b + 0.36), (0.24, b + 0.38), (0.205, b + 0.385)]), rim.0, rim.1, around: 32, steps: 6),
            // The spout, from low on the side up and out, its mouth rimmed in black.
            Clay.limb(QuadraticBezier(v(0.3, b + 0.13, 0), v(0.56, b + 0.17, 0), spoutTip - v(0.015, 0.03, 0)), 0.085, 0.045, enamel.0, enamel.1, sides: 10, rings: 10).shape,
            Clay.blob(at: spoutTip - v(0.01, 0.02, 0), size: v(0.052, 0.03, 0.052), color: rim.0, top: rim.1, turn: v(0, 0, -0.5)),
            // The bail, from an ear over the spout to one at the back, with a wooden grip in the middle.
            Clay.blob(at: v(0.3, b + 0.31, 0), size: v(0.035, 0.05, 0.03), color: rim.0, top: rim.1),
            Clay.blob(at: v(-0.3, b + 0.31, 0), size: v(0.035, 0.05, 0.03), color: rim.0, top: rim.1),
            Clay.limb(CubicBezier(v(0.3, b + 0.32, 0), v(0.34, b + 0.78, 0), v(-0.34, b + 0.78, 0), v(-0.3, b + 0.32, 0)), 0.016, 0.016, rim.0, rim.1,
                      sides: 6, rings: 20).shape,
            Clay.blob(at: v(0, b + 0.665, 0), size: v(0.15, 0.04, 0.04), color: 0x8a5a33, top: 0xb98048),
        ]
        // Three pot supports from the burner out under the kettle's base.
        for k in 0..<3 {
            let a = Float(k) / 3 * 2 * .pi + 0.4
            let c = cos(a), s = sin(a)
            parts.append(Clay.limb(QuadraticBezier(v(c * 0.07, 0.27, s * 0.07), v(c * 0.24, 0.27, s * 0.24), v(c * 0.27, b + 0.005, s * 0.27)),
                                   0.018, 0.016, rim.0, rim.1, sides: 5, rings: 6).shape)
        }
        return Geometry.join(parts).roughened(0.6)
    }

    /// The lid, at its seat (moved up and tipped when it rattles): a low dome with a round knob.
    static func lid() -> Geometry {
        Geometry.join([
            Clay.thrown(p([(0, 0), (0.215, 0), (0.21, 0.025), (0.15, 0.06), (0.06, 0.08), (0, 0.082)]), enamel.0, enamel.1, around: 28, steps: 10),
            Clay.blob(at: v(0, 0.105, 0), size: v(0.05, 0.035, 0.05), color: rim.0, top: rim.1),
        ]).roughened(0.6).applied(.translation(lidSeat))
    }

    /// The burner's ring of small blue flames, and tongues of yellow flame spreading out under the kettle and
    /// licking up round its base, standing on the burner at y = 0 (scaled up from nothing as it lights; a
    /// simmer's lower flame stays under the kettle).
    static func flame() -> Geometry {
        var parts: [Geometry] = []
        for k in 0..<6 {
            let a = Float(k) / 6 * 2 * .pi
            parts.append(Clay.thrown(p([(0, 0), (0.024, 0.006), (0.026, 0.02), (0.014, 0.045), (0, 0.06)]), 0x3d6fe0, 0x9fc0ff, around: 8, steps: 8)
                .applied(.translation(v(cos(a) * 0.075, 0, sin(a) * 0.075))))
        }
        for k in 0..<9 {
            let a = (Float(k) + 0.5) / 9 * 2 * .pi
            // Out past the kettle's widest (0.425), so from above the flames ring its base.
            let c = cos(a), s = sin(a), tall: Float = k % 2 == 0 ? 0.3 : 0.23
            let curve = QuadraticBezier(v(c * 0.1, 0.02, s * 0.1), v(c * 0.6, 0.03, s * 0.6), v(c * 0.56, tall, s * 0.56))
            parts.append(Clay.limb(curve, 0.075, 0.01, 0xff6a14, 0xffe08a, sides: 6, rings: 8).shape)
        }
        return Geometry.join(parts)
    }

    /// The little red flag a failed command puts up: a thin pole and a pennant, standing on y = 0.
    static func flag() -> Geometry {
        var o = Outline(divisions: 4)
        o.move(0, 0)
        o.quadratic(0.2, 0.04, 0.4, 0.1)
        o.quadratic(0.2, 0.16, 0, 0.24)
        o.line(0, 0)
        var pennant = Clay.pressed(o.closed, thick: 0.035, soft: 0.014, 0xb8261f, 0xdc3a2e)
        pennant.translate(0.014, 0.66, 0)
        return Geometry.join([
            Clay.limb(QuadraticBezier(v(0, 0, 0), v(0, 0.45, 0), v(0, 0.92, 0)), 0.02, 0.016, 0x5b4632, 0x7a6048, sides: 6, rings: 6).shape,
            Clay.blob(at: v(0, 0.93, 0), size: v(0.032, 0.032, 0.032), color: 0xb8261f, top: 0xdc3a2e),
            pennant,
        ]).roughened(0.6)
    }
}

/// The kettle on one blanket, as it stands this frame.
struct KettlePlace {
    /// Where it stands on the blanket (group-local), eased toward its seat, and which way it is turned.
    var spot = Vec3.zero
    var at = Vec3.zero
    var turn: Float
    var shown = Sprung()
    var placed = false
    /// Its blanket has a plain terminal and no Claude: the kettle is seated (it shows once the last cat has gone).
    var wanted = false
    /// What the marks say, over all its blanket's plain terminals: a command running in one, a failure not yet
    /// seen in one, and the last ending well.
    var lit = false
    var flagged = false
    var finished = false
    /// When the flame was lit (village time).
    var litAt: Float = 0
    /// The flame, eased: 1 burning, 0 out. And the flag, sprung up.
    var flame: Float = 0
    var flag = Sprung()
    /// When the last whistle of steam began, and the dark puff of a snuffed flame (village time).
    var whistleAt: Float = -.infinity
    var snuffedAt: Float = -.infinity
    /// The lid's lift and tip this frame.
    var lidLift: Float = 0
    var lidTip: Float = 0
    /// Steam: each puff's place along its rise (0…1; 1 for a puff not in the air), how long it takes to rise,
    /// whether it is part of a whistle's jet, its own drift, and where it is drawn (xyz in the kettle's own
    /// units, w its size) with how see-through. Fixed lists, so a frame allocates nothing.
    var life = [Float](repeating: 1, count: KETTLE_PUFFS)
    var span = [Float](repeating: 1, count: KETTLE_PUFFS)
    var jet = [Bool](repeating: false, count: KETTLE_PUFFS)
    var drift = [Vec2](repeating: .zero, count: KETTLE_PUFFS)
    var puffs = [Vec4](repeating: .zero, count: KETTLE_PUFFS)
    var puffAlpha = [Float](repeating: 0, count: KETTLE_PUFFS)
    /// Seconds until the next puff leaves the spout.
    var nextPuff: Float = 0
    var random: Seeded
    /// The dark puff of a snuffed flame: where (kettle units) and how large, and how see-through.
    var smoke = Vec4.zero
    var smokeAlpha: Float = 0

    init(id: String) {
        random = chance("\(id)/kettle")
        turn = 0.35 + random.float() * 0.5
    }

    /// The command has been running long enough to have calmed to a simmer.
    func simmering(_ time: Float) -> Bool { lit && time - litAt >= KETTLE_BOIL }
}

extension Village {
    /// What a blanket's plain terminals say, folded into its kettle: whether one runs a command, whether one
    /// failed unseen, whether the last ended well. A change sets off what it does: the flame lit, a whistle of
    /// steam as it goes out, or a dark puff and the flag.
    func tellKettle(_ plot: Plot, _ view: MeadowBlanket) {
        let commands = view.state == .ended ? [] : view.lanterns.map(\.command)
        let lit = commands.contains(.running), flagged = commands.contains(.failed)
        let finished = !lit && !flagged && commands.contains(.finished)
        var k = plot.kettle
        k.wanted = !commands.isEmpty && view.state != .ended && view.agents.isEmpty
        if lit && !k.lit { k.litAt = time }
        if !lit && k.lit && k.wanted && !hushed && k.shown.x > 0.5 {
            // The flame goes out: snuffed with a dark puff on a failure, else a whistle of steam, if it has had
            // time to boil at all. (Making way for a cat, it simply goes.)
            if flagged && !k.flagged {
                k.snuffedAt = time
            } else if time - k.litAt >= KETTLE_WHISTLE_AFTER {
                k.whistleAt = time
                k.nextPuff = 0
            }
        }
        k.lit = lit
        k.flagged = flagged
        k.finished = finished
        plot.kettle = k
    }

    /// The kettle's own motion, each frame: it comes and goes, its flame lights and goes out, the lid rattles
    /// while it boils, steam rises (a whistle's jet, or a calm simmer's wisp), the flag springs up. Worked on
    /// the plot's kettle in place, so its lists are never copied.
    func runKettle(_ plot: Plot, _ dt: Float) {
        advance(&plot.kettle, standing: plot.kettle.wanted && plot.actors.isEmpty, dt)
    }

    private func advance(_ k: inout KettlePlace, standing: Bool, _ dt: Float) {
        // It stands while wanted, and only once its blanket's cats have all gone: it never stands among them.
        if hushed { k.shown = Sprung(standing ? 1 : 0) } else { k.shown.spring(standing ? 1 : 0, standing ? 160 : 400, standing ? 15 : 40, dt) }
        k.at += (k.spot - k.at) * min(1, dt * 3)
        let burning: Float = k.lit ? (k.simmering(time) ? 0.62 : 1) : 0
        k.flame += (burning - k.flame) * min(1, dt * (k.lit ? 4 : 6))
        if k.flame < 0.002 { k.flame = 0 }
        if hushed { k.flag = Sprung(k.flagged ? 1 : 0) } else { k.flag.spring(k.flagged ? 1 : 0, 200, 14, dt) }
        // The lid: little hops off its seat now and then while it boils, and one pop with the whistle.
        var lift: Float = 0, tip: Float = 0
        if k.lit && !k.simmering(time) && !hushed {
            let beat = time * 2.2, n = floor(beat), u = beat - n
            let hit = Self.hash(n), side = Self.hash(n + 17.3)
            if hit > 0.3, u < 0.3 {
                let hop = sin(u / 0.3 * .pi)
                lift = hop * 0.045
                tip = hop * 0.2 * (side < 0.5 ? -1 : 1)
            }
        }
        let whistle = time - k.whistleAt
        if whistle >= 0 && whistle < 0.35 { lift = max(lift, sin(whistle / 0.35 * .pi) * 0.05) }
        k.lidLift = lift
        k.lidTip = tip
        steam(&k, dt)
        // The snuffed flame's dark puff: out from under the kettle, swelling and fading as it rises.
        let snuff = (time - k.snuffedAt) / 1.1
        if snuff >= 0 && snuff < 1 {
            k.smoke = Vec4(Kettle.burner.x + 0.1 + snuff * 0.45, Kettle.burner.y + snuff * 0.9, Kettle.burner.z + 0.2, 0.14 + snuff * 0.4)
            k.smokeAlpha = (1 - snuff) * 0.7 * min(1, snuff * 6)
        } else {
            k.smokeAlpha = 0
        }
    }

    /// A steady pseudo-random number in 0…1 for a beat of the lid's rattle.
    private static func hash(_ n: Float) -> Float {
        let x = sin(n * 12.9898 + 4.1414) * 43758.5453
        return x - floor(x)
    }

    /// Steam from the spout: a puff now and then while it simmers, a stream while it boils, a quick jet as it
    /// whistles. Each puff rises as it set off. With Reduce Motion or the animation off nothing drifts: a lit
    /// kettle shows one still wisp.
    private func steam(_ k: inout KettlePlace, _ dt: Float) {
        let tip = Kettle.spoutTip, out = Kettle.spoutOut
        if hushed {
            for i in 0..<KETTLE_PUFFS {
                k.life[i] = 1
                guard i < 6, k.flame > 0.3 else { k.puffAlpha[i] = 0; continue }
                let v = Float(i) / 5
                k.puffs[i] = Vec4(tip + out * (0.1 + v * 0.25) + Vec3(sin(v * 4) * 0.08, v * v * 1.3, 0), 0.08 + v * 0.26)
                k.puffAlpha[i] = 0.75 - v * 0.35
            }
            return
        }
        let whistle = time - k.whistleAt
        let jetting = whistle >= 0 && whistle < 0.7
        let simmer = k.simmering(time)
        // Seconds between puffs: a jet's stream, a boil's, a simmer's now and then; none from a cold kettle.
        let every: Float = jetting ? 0.04 : k.flame > 0.05 ? (simmer ? 0.32 : 0.1) : .infinity
        k.nextPuff -= dt
        if !every.isFinite {
            k.nextPuff = 0
        } else if k.nextPuff <= 0, let free = k.life.firstIndex(where: { $0 >= 1 }) {
            k.life[free] = 0
            k.jet[free] = jetting
            k.span[free] = jetting ? 0.9 : simmer ? 2.6 : 1.8
            k.drift[free] = Vec2((k.random.float() - 0.5) * 0.3, (k.random.float() - 0.5) * 0.3) * (jetting ? 0.3 : 1)
            k.nextPuff = every * (0.75 + k.random.float() * 0.5)
        }
        for i in 0..<KETTLE_PUFFS {
            guard k.life[i] < 1 else { k.puffAlpha[i] = 0; continue }
            k.life[i] = min(1, k.life[i] + dt / k.span[i])
            let u = k.life[i], jet = k.jet[i]
            // Out of the spout along its line first, then up, curling away with its drift; a jet shoots further.
            // A plume: out of the spout, then up well above the kettle, so it reads from above and afar.
            let reach: Float = jet ? 0.8 : 0.26
            let along = tip + out * (0.03 + reach * min(u * 2.5, 1)) + Vec3(0, u * (jet ? 0.7 : simmer ? 1.2 : 1.7), 0)
            let curl = Vec3(k.drift[i].x * u + sin(u * 5 + Float(i)) * 0.05 * u, 0, k.drift[i].y * u)
            k.puffs[i] = Vec4(along + curl, 0.06 + u * (jet ? 0.22 : simmer ? 0.24 : 0.34))
            // Thickest just out of the spout, thinning to nothing as it spreads.
            k.puffAlpha[i] = (1 - u) * min(1, u * 10) * (jet ? 0.9 : simmer ? 0.6 : 0.8)
        }
    }

    /// Nothing about the kettle is under way but a simmer's slow wisp: it may rest.
    func kettleStill(_ plot: Plot) -> Bool {
        let k = plot.kettle
        if abs(k.shown.x - (k.wanted && plot.actors.isEmpty ? 1 : 0)) > 0.01 || abs(k.flag.x - (k.flagged ? 1 : 0)) > 0.01 { return false }
        if hushed { return abs(k.flame - (k.lit ? 1 : 0)) < 0.02 || k.simmering(time) }
        if k.lit && !k.simmering(time) { return false }
        return time - k.whistleAt > 1.5 && time - k.snuffedAt > 1.1 && (k.lit || k.flame == 0)
    }
}
