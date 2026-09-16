import Foundation
import simd

// The garden lamps after dark. Like real ones on a light sensor, they come on by themselves as the sun goes down
// (`Light.lampsLit`) and go out after sunrise, each when its own sensor decides: one by one over half a minute,
// not all in one frame, each warming up with a stutter or two as an old bulb catches, then burning steadily. With
// Reduce Motion, the meadow's animation off, or when the meadow is first drawn, they are simply lit or out.
//
// Their light is baked into the ground's map (`GroundMap.light`) only when a lamp's light changes (one warming up,
// one placed, moved or taken away, the editor's ghost carried about), and only round that lamp; a steady night
// changes nothing from frame to frame.

struct MeadowLamps {
    /// One lamp: where it stands, the middle of its glass in the meadow, when its sensor answers, and how lit it is.
    struct Lamp: Equatable {
        var x: Float
        var z: Float
        var head: Vec3
        /// Seconds after the light turns that this one comes on (and, a little sooner, goes out).
        var delay: Float
        /// Its own stutter while it warms up.
        var phase: Float
        /// How lit it is now, 0 (out) … 1.
        var level: Float = 0
        /// Placed since the light last turned: lit or out as the others are meant to be, at once, never warming up.
        var settled = false
        /// How much of it stands, 1 … 0: a blanket laid over its spot shrinks it away (as every rooted thing makes
        /// way), and its light with it.
        var standing: Float = 1
        /// The light it gives now: how lit, as much as stands of it.
        var shine: Float { level * standing }
    }

    /// Over how many seconds the lamps of a meadow come on, the first to the last.
    static let spread: Float = 24
    /// How long one takes to warm up from its first stutter to burning steadily.
    static let warming: Float = 1.6
    /// How long one takes to go out.
    static let cooling: Float = 0.5

    private(set) var lamps: [Lamp] = []
    /// The editor's ghost of a lamp about to be placed, lit as the lamps are so its light can be seen where it would
    /// fall; nil when there is none.
    private(set) var ghost: Lamp?
    /// Whether the lamps are lit (or coming on), and the seconds since that last turned; nil before it was first told.
    private(set) var lit: Bool?
    private var since: Float = 0

    /// The texels of the ground's map whose lamplight changed since this was last asked (nil: none).
    private(set) var changed: GroundMap.Region?

    /// A lamp standing at (x, z), its glass at `head`: when it answers the dusk, and its stutter, from where it
    /// stands, so the same meadow always lights in the same order.
    static func lamp(x: Float, z: Float, head: Vec3) -> Lamp {
        // A hash of where it stands to a quarter unit: two lamps never share a sensor's mood unless they share a spot.
        let h = latticeHash(Double(x * 4), Double(z * 4) + 7_919), h2 = latticeHash(Double(z * 4) - 3_571, Double(x * 4))
        return Lamp(x: x, z: z, head: head, delay: Float(h) * spread, phase: Float(h2) * 2 * .pi)
    }

    /// How lit a lamp is `t` seconds after its sensor answered, coming on: a short stutter as it catches, then up
    /// to full over `warming`.
    static func warmth(_ t: Float, phase: Float) -> Float {
        guard t > 0 else { return 0 }
        guard t < warming else { return 1 }
        let rise = smoothstep(t, 0, warming)
        // Two or three quick dips in its first second, each lamp its own.
        let flicker = max(0, sin(t * 23 + phase) * sin(t * 37 + phase * 1.7))
        let stutter = 1 - 0.85 * flicker * (1 - smoothstep(t, 0.15, 1.1))
        return max(0, min(1, (0.25 + 0.75 * rise) * stutter * smoothstep(t, 0, 0.12)))
    }

    /// The lamps of a newly laid scenery: those standing where lamps stood keep how lit they were, new ones are lit
    /// as the rest are now (no warming up for a lamp just placed). The light is baked where any changed.
    mutating func lay(_ placed: [(x: Float, z: Float, head: Vec3)]) {
        let old = lamps
        let steady: Float = lit == true ? 1 : 0
        lamps = placed.map { p in
            var lamp = Self.lamp(x: p.x, z: p.z, head: p.head)
            if let was = old.first(where: { $0.x == p.x && $0.z == p.z }) {
                lamp.level = was.level
                lamp.settled = was.settled
            } else {
                lamp.level = steady
                lamp.settled = true
            }
            return lamp
        }
        let before = Set(old.map { SIMD3($0.x, $0.z, $0.level) }), after = Set(lamps.map { SIMD3($0.x, $0.z, $0.level) })
        for lamp in old where !after.contains(SIMD3(lamp.x, lamp.z, lamp.level)) { touch(lamp) }
        for lamp in lamps where !before.contains(SIMD3(lamp.x, lamp.z, lamp.level)) { touch(lamp) }
    }

    /// Lamp `i` moved to (x, z), its glass now at `head`: its light baked again where it was and where it is.
    mutating func move(_ i: Int, x: Float, z: Float, head: Vec3) {
        guard lamps.indices.contains(i), lamps[i].x != x || lamps[i].z != z || lamps[i].head != head else { return }
        touch(lamps[i])
        let was = lamps[i]
        lamps[i] = Self.lamp(x: x, z: z, head: head)
        lamps[i].level = was.level
        lamps[i].settled = was.settled
        lamps[i].standing = was.standing
        touch(lamps[i])
    }

    /// The editor's ghost of a lamp (nil: none), lit as fully as the lamps are once warmed.
    mutating func carry(_ head: Vec3?) {
        let level: Float = lit == true ? 1 : 0
        let new = head.map { Lamp(x: $0.x, z: $0.z, head: $0, delay: 0, phase: 0, level: level) }
        guard new != ghost else { return }
        if let ghost { touch(ghost) }
        ghost = new
        if let new { touch(new) }
    }

    /// Moves the lamps on by `dt` seconds: `lit`, whether lamps should be lit now; `steady`, to light or put
    /// them out at once, with no warming and no stutter (Reduce Motion, the animation off).
    mutating func update(_ dt: Float, lit now: Bool, steady: Bool) {
        if lit == nil {
            // First told: as they are, at once.
            lit = now
            since = .infinity
            for i in lamps.indices { lamps[i].level = now ? 1 : 0; touch(lamps[i]) }
            carry(ghost?.head)
            return
        }
        if now != lit {
            lit = now
            // Lit or put out at once is as if long since: a later frame without `steady` goes on from there.
            since = steady ? .infinity : 0
            for i in lamps.indices { lamps[i].settled = false }
            carry(ghost?.head)
        } else {
            since += dt
        }
        for i in lamps.indices {
            let lamp = lamps[i]
            let level: Float
            if steady || lamp.settled {
                level = now ? 1 : 0
            } else if now {
                level = Self.warmth(since - lamp.delay, phase: lamp.phase)
            } else {
                // Going out after sunrise, in the order they came on, half as spread out, and without a stutter.
                level = 1 - smoothstep(since - lamp.delay * 0.5, 0, Self.cooling)
            }
            guard level != lamp.level else { continue }
            lamps[i].level = level
            touch(lamps[i])
        }
    }

    /// How much of lamp `i` stands, as the shaders shrink a rooted thing round a blanket (`Meadow.standing`).
    mutating func stand(_ i: Int, _ standing: Float) {
        guard lamps[i].standing != standing else { return }
        lamps[i].standing = standing
        touch(lamps[i])
    }

    /// Whether any lamp, or the ghost, gives light now.
    var shining: Bool { ghost.map { $0.level > 0 } ?? false || lamps.contains { $0.shine > 0 } }

    /// What the ground's map holds of them, written into `lights` (kept by the caller, so nothing is allocated):
    /// every lamp, then the ghost.
    func lights(into lights: inout [GroundMap.Lamp]) {
        lights.removeAll(keepingCapacity: true)
        for lamp in lamps { lights.append(GroundMap.Lamp(x: lamp.x, z: lamp.z, level: lamp.shine)) }
        if let ghost { lights.append(GroundMap.Lamp(x: ghost.x, z: ghost.z, level: ghost.level)) }
    }

    /// The region changed since last asked, forgotten.
    mutating func takeChanged() -> GroundMap.Region? {
        defer { changed = nil }
        return changed
    }

    private mutating func touch(_ lamp: Lamp) {
        guard let region = GroundMap.reached(by: GroundMap.Lamp(x: lamp.x, z: lamp.z, level: 1)) else { return }
        changed = changed.map { $0.union(region) } ?? region
    }
}
