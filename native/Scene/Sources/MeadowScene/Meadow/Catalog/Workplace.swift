import Foundation
import simd

// The meadow editor's Workplace things: made things, cat-sized and never scaled, each modelled on the real
// thing, then simplified into the meadow's clay; those with a palette wear its first swatch.

enum Workplace {
    /// A square floor cushion (a zabuton; its first swatch, oat) a cat can sit on: the picnic's cushion made big
    /// enough for one, plump in the middle and thinner at its seams, tufted at the centre with a little tie.
    static let cushion: Plant = {
        var soft = Picnic.cushion()
        soft.apply(.scale(Vec3(2.3, 1.45, 2.3)))
        soft.paint(0xbfa881, 0xefe4cc)
        let tie = (0..<3).map { k -> Geometry in
            let a = Float(k) / 3 * 2 * .pi
            return Clay.blob(at: Vec3(cos(a) * 0.06, 0.62, sin(a) * 0.06), size: Vec3(0.09, 0.045, 0.045), color: 0x8f7a58, top: 0xa8916c, turn: Vec3(0, -a, 0))
        }
        return Plant(shape: Geometry.join([soft] + tie).roughened(0.95), top: Vec3(0, 0.75, 0))
    }()
}
