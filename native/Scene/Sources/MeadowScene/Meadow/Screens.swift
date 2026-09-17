import Foundation
import simd

// Port of src/meadow/screens.ts: anything tall enough to stand between you and a picnic (a tree, a
// sapling, the fallen log) fades to see-through while it is in the way, and fades back when it is not.
// Each is a trunk (a line with a thickness) and, for trees, a ball of leaves; each thing worth seeing is a
// ball, so from the camera it fills a cone; every frame each trunk and crown is tested against each cone.

struct Screen {
    var from: Vec3          // bottom of the trunk
    var to: Vec3            // top of the trunk
    var thick: Float        // radius round the trunk line
    var crown: Vec3?
    var crownSize: Float
    var fade: Float = 1     // 1 solid … SEEN_THROUGH
}

enum Occlusion {
    static let seenThrough: Float = 0.2   // faint, but its shape still reads
    static let fadeRate: Float = 6        // per second

    /// Distance between segments a–b and c–d (Ericson, Real-Time Collision Detection 5.1.9), and how far
    /// along a–b the nearest point lies.
    static func apart(_ a: Vec3, _ b: Vec3, _ c: Vec3, _ d: Vec3) -> (Float, Float) {
        let ab = b - a, cd = d - c, ac = a - c
        let aa = simd_dot(ab, ab), cc = simd_dot(cd, cd), f = simd_dot(cd, ac)
        var s: Float = 0, t: Float = 0
        if aa < 1e-9 && cc < 1e-9 { return (simd_distance(a, c), 0) }
        if aa < 1e-9 {
            s = 0
            t = clamp(f / cc, 0, 1)
        } else {
            let e = simd_dot(ab, ac)
            if cc < 1e-9 {
                t = 0
                s = clamp(-e / aa, 0, 1)
            } else {
                let g = simd_dot(ab, cd), den = aa * cc - g * g
                s = den > 1e-9 ? clamp((g * f - e * cc) / den, 0, 1) : 0
                t = (g * s + f) / cc
                if t < 0 { t = 0; s = clamp(-e / aa, 0, 1) } else if t > 1 { t = 1; s = clamp((g - e) / aa, 0, 1) }
            }
        }
        return (simd_distance(a + ab * s, c + cd * t), s)
    }

    /// Distance from p to segment a–b, and how far along it the nearest point lies.
    static func reach(_ a: Vec3, _ b: Vec3, _ p: Vec3) -> (Float, Float) {
        let ab = b - a
        let along = clamp(simd_dot(p - a, ab) / max(simd_length_squared(ab), 1e-9), 0, 1)
        return (simd_distance(a + ab * along, p), along)
    }

    /// How far in front of a ball a screen's nearest point must be to hide it, in units: one nearest at the ball
    /// itself stands under or behind it (a cat on a bookcase's top, on a shed's doorstep), and hides nothing.
    static let inFront: Float = 0.3

    /// Whether a screen hides any of the balls from the eye.
    static func blocks(_ s: Screen, eye: Vec3, sights: [Ball], count: Int) -> Bool {
        for i in 0..<count {
            let ball = sights[i]
            let before = 1 - inFront / max(simd_distance(eye, ball.center), inFront)
            // The cone widens from nothing at the eye to the ball's own size at the ball.
            let (d, along) = apart(eye, ball.center, s.from, s.to)
            if along < before && d < s.thick + ball.radius * along { return true }
            if let crown = s.crown {
                let (d2, along2) = reach(eye, ball.center, crown)
                if along2 < before && d2 < s.crownSize + ball.radius * along2 { return true }
            }
        }
        return false
    }

    static func update(_ screens: inout [Screen], dt: Float, eye: Vec3, sights: [Ball], count: Int) {
        let step = min(1, dt * fadeRate)
        for i in screens.indices {
            let goal = blocks(screens[i], eye: eye, sights: sights, count: count) ? seenThrough : 1
            if screens[i].fade == goal { continue }
            screens[i].fade += (goal - screens[i].fade) * step
            if abs(screens[i].fade - goal) < 0.01 { screens[i].fade = goal }
        }
    }
}
