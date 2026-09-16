import Foundation
import simd

// What the scene draws for each catalog id: the builders behind `MeadowScenery`. An id the catalog
// (`MeadowFile`'s `MeadowCatalog`) lists and this table does not is one the scene cannot draw yet; a
// meadow keeps such things and leaves them out of the picture (WhiskrMeadow's tests hold the list of
// those still to come).

enum SceneryCatalog {
    enum Kind {
        /// A landmark tree, grown from the thing's seed: one mesh of its own, shade on the ground below it,
        /// ground blankets keep off round its roots, and it fades when it stands in front of a cat.
        case tree(Species)
        /// A young tree, grown from the thing's seed, drawn rooted like a plant (it makes way under a
        /// blanket), each fading on its own when in the way.
        case youngTree(Species)
        /// A plant, mushroom or stone: one of a few shapes (made when first drawn), drawn rooted and
        /// instanced; `sway` in the wind; `blooms` where butterflies and bees settle; `base` how far round
        /// its root it stands on the ground at its own size (`SceneryRules.footprint`).
        case plant(@Sendable () -> [Plant], sway: Float, blooms: Bool, base: Float)
        /// A fallen log: ground blankets keep off along it, and it fades when in the way.
        case log
    }

    static let kinds: [String: Kind] = [
        "tree.oak": .tree(.oak),
        "tree.birch": .tree(.birch),
        "tree.cherry": .tree(.cherry),
        "tree.young": .youngTree(.sapling),
        "flower.daisy": .plant({ Flora.daisies }, sway: 0.12, blooms: true, base: 0.3),
        "flower.buttercup": .plant({ Flora.buttercups }, sway: 0.12, blooms: true, base: 0.3),
        "flower.lupin": .plant({ Flora.lupins }, sway: 0.12, blooms: true, base: 0.32),
        "flower.poppy": .plant({ Flora.poppies }, sway: 0.12, blooms: true, base: 0.3),
        "fungus.flyAgaric": .plant({ Flora.mushrooms }, sway: 0, blooms: false, base: 0.42),
        "stone.stone": .plant({ [Flora.stones[0]] }, sway: 0, blooms: false, base: 1.25),
        "stone.mossy": .plant({ [Flora.stones[1]] }, sway: 0, blooms: false, base: 1.25),
        "wood.fallenLog": .log,
    ]

    /// A fallen trunk lying in the long grass along its own x axis, its cut ends pale and moss settling
    /// along the top; shaped lying on y = 0.
    static let fallenLog: Geometry = {
        let along = QuadraticBezier(Vec3(-7.5, 0.95, 0), Vec3(0, 1.1, 0.9), Vec3(7.5, 0.9, 0.2))
        let trunk = Clay.limb(along, 1.05, 0.9, 0x6f523a, 0x8f6d4b, sides: 16, rings: 14) { _, angle in 1 + sin(angle * 7) * 0.035 }
        func cut(_ x: Float, _ z: Float, _ r: Float) -> Geometry { Clay.blob(at: Vec3(x, 0.95, z), size: Vec3(0.12, r, r), color: 0xcdb089, top: 0xe6cfa6) }
        let moss = [(Float(-3.5), Float(0.3), Float(1.9)), (0.6, 0.75, 2.6), (4.2, 0.45, 1.6)].map { x, z, size in
            Clay.blob(at: Vec3(x, 1.95, z), size: Vec3(size, 0.22, 0.75), color: 0x79a043, top: 0xa9cb62, lumpy: 0.15)
        }
        return Geometry.join([trunk.shape, cut(-7.5, 0, 1.0), cut(7.42, 0.2, 0.86)] + moss).roughened(0.9)
    }()
    /// How far a fallen log reaches each way along its length.
    static let logHalfLength: Float = 7.5

    static func species(_ id: String) -> Species? {
        switch kinds[id] {
        case .tree(let species), .youngTree(let species): species
        default: nil
        }
    }
}
