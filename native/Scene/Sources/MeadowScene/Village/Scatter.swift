import Foundation

// Port of src/village/scatter.ts: placing things so they look set down by hand: loosely, never
// overlapping, and always the same for the same thing, so nothing jumps about when something else arrives.

/// Something already set down: where, and how much room it needs around its middle.
struct Spot: Equatable { var x: Float; var z: Float; var reach: Float }

/// A place for something needing `reach` of room, somewhere between `near` and `far` from (x, z). Of a
/// handful of random tries, the clear one (keeping `gap` from everything already placed) nearest to
/// (x, z) wins, so things settle close together without touching. If none is clear, the one with the
/// most room wins, and `clear` says so. `fits` can rule places out, such as off the edge of a blanket.
func settle(_ random: inout Seeded, _ placed: [Spot], _ reach: Float, _ gap: Float, _ x: Float, _ z: Float,
            _ near: Float, _ far: Float, fits: (Float, Float) -> Bool = { _, _ in true }) -> (x: Float, z: Float, clear: Bool) {
    var best = (x: x, z: z, clear: false)
    var bestRoom = -Float.infinity, bestOut = Float.infinity
    for _ in 0..<18 {
        let angle = Float(random.next() * Double.pi * 2)
        // Square root spreads tries evenly over the ring rather than bunching them at its inner edge.
        let out = Float((Double(near * near) + random.next() * Double(far * far - near * near)).squareRoot())
        let tx = x + cos(angle) * out, tz = z + sin(angle) * out
        if !fits(tx, tz) { continue }
        var room = Float.infinity
        for other in placed { room = min(room, hypot(tx - other.x, tz - other.z) - other.reach - reach) }
        let clear = room >= gap
        if clear ? (!best.clear || out < bestOut) : (!best.clear && room > bestRoom) {
            best = (tx, tz, clear)
            bestRoom = room
            bestOut = out
        }
    }
    return best
}
