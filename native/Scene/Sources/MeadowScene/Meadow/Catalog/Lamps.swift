import Foundation
import simd

// The meadow editor's garden lamp: a lamp post as gardens and parks have them, modelled on the real thing and
// then simplified into the meadow's clay. Made, so cat-sized (the cat is 2.3 units tall: the lamp stands a
// little over twice that, as a garden lamp stands over a person) and never scaled. Lit after dark
// (`MeadowLamps`): its glass glows and it pools warm light on the ground round it.
//
// The real thing: a cast post (60–90 mm across on a 1.9–2.3 m garden post) rising from a flared, stepped base,
// a collar where post and base meet, a ladder bar under the head on the taller ones, a cup the lantern sits in,
// and a four- or six-sided lantern widening upward, its panes held by corner bars under an overhanging roof
// with a finial; painted black or heritage green, satin, never bright metal. The glass is frosted or seeded so
// the whole lantern glows rather than showing a bulb.

enum Lamps {
    private static func v(_ x: Float, _ y: Float, _ z: Float) -> Vec3 { Vec3(x, y, z) }

    /// The ids drawn as lamps: lit after dark, kept off the picnic ground, counted toward the lamps' limit.
    static let ids: Set<String> = ["work.lampPost"]
    static func isLamp(_ id: String) -> Bool { ids.contains(id) }

    /// Where the light comes from, on the lamp as it is made: the middle of its glass.
    static let head = Vec3(0, 4.42, 0)
    /// The cast metal's paint: heritage green, deep enough to read as painted iron by day, never black (the
    /// meadow's cats are black).
    private static let paint: (low: UInt32, high: UInt32) = (0x2b4033, 0x3f5a49)
    /// The glass's roughness, marked as glass for the shaders (`LIT_LAMP`): its own roughness plus 2.
    static let glassRoughness: Float = 2 + 0.3

    /// A garden lamp post: a flared base, a fluted post with a collar at its foot and a ladder bar under the
    /// head, a cup, a lantern of four frosted panes widening upward between corner bars, an overhanging roof
    /// and a ball finial. Chunky enough that nothing thin flickers from the editor's height.
    static let post: Plant = {
        let metal = 0.55 as Float
        func cast(_ g: Geometry) -> Geometry { g.painted(paint.low, paint.high).roughened(metal) }
        // The base: a stepped plinth flaring up into the post, as cast-iron bases are.
        let base = Clay.thrown([v2(0, 0), v2(0.62, 0), v2(0.64, 0.1), v2(0.56, 0.18), v2(0.5, 0.3), v2(0.4, 0.46), v2(0.3, 0.66), v2(0.24, 0.86),
                                v2(0.22, 0.98), v2(0, 0.98)], paint.low, paint.high, around: 28, steps: 30).roughened(metal)
        // The post: fluted (eight shallow ridges), a hair slimmer at the top.
        let shaft = Clay.limb(QuadraticBezier(v(0, 0.9, 0), v(0, 2.3, 0), v(0, 3.72, 0)), 0.17, 0.145, paint.low, paint.high, sides: 24, rings: 6) { _, angle in
            1 + 0.07 * pow(abs(cos(angle * 4)), 3)
        }
        func ring(_ y: Float, _ r: Float, _ tube: Float) -> Geometry {
            cast(Shapes.torus(r, tube, 8, 28).applied(.compose(v(0, y, 0), euler: v(.pi / 2, 0, 0))))
        }
        // The ladder bar: a round crossbar with ball ends just under the head.
        let bar = Clay.limb(QuadraticBezier(v(-0.52, 3.42, 0), v(0, 3.42, 0), v(0.52, 3.42, 0)), 0.06, 0.06, paint.low, paint.low, sides: 10, rings: 2)
        let barEnds = [Float(-0.55), 0.55].map { x in Clay.blob(at: v(x, 3.42, 0), size: 0.1, color: paint.low, top: paint.high).roughened(metal) }
        // The cup the lantern sits in, and the lantern's floor.
        let cup = Clay.thrown([v2(0, 3.7), v2(0.17, 3.7), v2(0.24, 3.78), v2(0.36, 3.9), v2(0.44, 3.98), v2(0.44, 4.02), v2(0, 4.02)], paint.low, paint.high,
                              around: 24, steps: 16).roughened(metal)
        // The lantern: four panes widening upward, square with soft corners; brightest round its middle, where
        // the lamp inside is, when lit.
        let low: Float = 4.0, high: Float = 4.86
        let glass = Clay.stacked([.init(w: 0.34, d: 0.34, y: low), .init(w: 0.39, d: 0.39, y: (low + high) / 2), .init(w: 0.45, d: 0.45, y: high)],
                                 around: 32, square: 7) { ring, _ in ring == 1 ? 0xfff3d6 : 0xe9dcc0 }
            .roughened(glassRoughness)
        // Corner bars holding the panes, and the bands top and bottom.
        let corners = (0..<4).map { k -> Geometry in
            let a = Float(k) * .pi / 2 + .pi / 4, out = Vec2(cos(a), sin(a)) * 0.87 * 1.04
            return cast(Clay.limb(QuadraticBezier(v(out.x * 0.34, low, out.y * 0.34), v(out.x * 0.395, (low + high) / 2, out.y * 0.395), v(out.x * 0.45, high, out.y * 0.45)),
                                  0.05, 0.055, paint.low, paint.high, sides: 8, rings: 2).shape)
        }
        func band(_ y: Float, _ w: Float, _ tall: Float) -> Geometry {
            cast(Clay.stacked([.init(w: w, d: w, y: y - tall / 2), .init(w: w, d: w, y: y + tall / 2)], around: 32, square: 7) { _, _ in 0 })
        }
        // The roof: overhanging eaves rising to a short neck, then the finial's ball and point.
        let roof = cast(Clay.stacked([.init(w: 0.5, d: 0.5, y: high), .init(w: 0.6, d: 0.6, y: high + 0.06), .init(w: 0.58, d: 0.58, y: high + 0.12),
                                      .init(w: 0.3, d: 0.3, y: high + 0.36), .init(w: 0.12, d: 0.12, y: high + 0.5)], around: 32, square: 6) { _, _ in 0 })
        let finial = [Clay.blob(at: v(0, high + 0.6, 0), size: 0.13, color: paint.low, top: paint.high).roughened(metal),
                      Clay.blob(at: v(0, high + 0.76, 0), size: v(0.05, 0.1, 0.05), color: paint.high).roughened(metal)]
        return Plant(shape: Geometry.join([base, shaft.shape.roughened(metal), ring(0.96, 0.21, 0.05), ring(3.66, 0.18, 0.045), bar.shape.roughened(metal)]
                                          + barEnds + [cup, glass] + corners + [band(low + 0.02, 0.37, 0.05), band(high - 0.02, 0.48, 0.05), roof] + finial),
                     top: v(0, high + 0.86, 0))
    }()

    private static func v2(_ x: Float, _ y: Float) -> Vec2 { Vec2(x, y) }
}
