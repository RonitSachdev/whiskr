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
        /// A plant, mushroom, stone or other thing standing at a spot (a stump, a cat's bed): one of a few shapes
        /// (made when first drawn), drawn rooted and instanced; `sway` in the wind; `blooms` where butterflies
        /// and bees settle; `base` how far round its root it stands on the ground at its own size
        /// (`SceneryRules.footprint`).
        case plant(@Sendable () -> [Plant], sway: Float, blooms: Bool, base: Float)
        /// A fallen log: ground blankets keep off along it, and it fades when in the way.
        case log
        /// A fence: a run of posts along the thing's points, two rails a span and perhaps a gate (`Fences`), each
        /// part instanced, drawn rooted.
        case fence
    }

    static let kinds: [String: Kind] = [
        "tree.oak": .tree(.oak),
        "tree.birch": .tree(.birch),
        "tree.cherry": .tree(.cherry),
        "tree.young": .youngTree(.sapling),
        "tree.apple": .tree(.apple),
        "tree.pine": .tree(.pine),
        "flower.daisy": .plant({ Flora.daisies }, sway: 0.12, blooms: true, base: 0.3),
        "flower.buttercup": .plant({ Flora.buttercups }, sway: 0.12, blooms: true, base: 0.3),
        "flower.lupin": .plant({ Flora.lupins }, sway: 0.12, blooms: true, base: 0.32),
        "flower.poppy": .plant({ Flora.poppies }, sway: 0.12, blooms: true, base: 0.3),
        "flower.cornflower": .plant({ Flora.cornflowers }, sway: 0.12, blooms: true, base: 0.3),
        // Tall and top-heavy: it sways less at its root and more at its tip (the sway grows with height).
        "flower.foxglove": .plant({ Flora.foxgloves }, sway: 0.06, blooms: true, base: 0.5),
        "plant.fern": .plant({ Flora.ferns }, sway: 0.05, blooms: false, base: 0.75),
        "plant.clover": .plant({ Flora.clovers }, sway: 0.1, blooms: true, base: 0.4),
        "fungus.flyAgaric": .plant({ Flora.mushrooms }, sway: 0, blooms: false, base: 0.42),
        "stone.stone": .plant({ [Flora.stones[0]] }, sway: 0, blooms: false, base: 1.25),
        "stone.mossy": .plant({ [Flora.stones[1]] }, sway: 0, blooms: false, base: 1.25),
        "stone.boulder": .plant({ [StonesAndWood.boulder] }, sway: 0, blooms: false, base: 2.3),
        // The worktrees' own stepping stone, set flat in the turf; its ground is round its narrower middle, so
        // a path of them a stride apart (`MeadowEditSession.stepping`) keeps a strip of grass between each two.
        "stone.stepping": .plant({ [Plant(shape: steppingStone, top: Vec3(0, 0.05, 0))] }, sway: 0, blooms: false, base: 0.42),
        "wood.fallenLog": .log,
        "wood.stump": .plant({ [StonesAndWood.stump] }, sway: 0, blooms: false, base: 1.35),
        "wood.logPile": .plant({ [StonesAndWood.logPile] }, sway: 0, blooms: false, base: 1.45),
        // Made things: one shape each, in the swatch of its palette it wears (`painted`), the first here.
        "garden.fence": .fence,
        "garden.flowerPot": .plant({ [Garden.flowerPot(0)] }, sway: 0, blooms: false, base: 0.62),
        "garden.planter": .plant({ [Garden.planter] }, sway: 0, blooms: false, base: 1.78),
        "garden.wateringCan": .plant({ [Garden.wateringCan(0)] }, sway: 0, blooms: false, base: 0.6),
        "garden.birdhouse": .plant({ [Garden.birdhouse] }, sway: 0, blooms: false, base: 0.5),
        "garden.skep": .plant({ [Garden.skep] }, sway: 0, blooms: false, base: 0.82),
        "work.desk": .plant({ [Workplace.desk] }, sway: 0, blooms: false, base: 1.7),
        "work.cushion": .plant({ [Workplace.cushion(0)] }, sway: 0, blooms: false, base: 1.2),
        "work.bookshelf": .plant({ [Workplace.bookshelf] }, sway: 0, blooms: false, base: 1.4),
        "work.bench": .plant({ [Workplace.bench(0)] }, sway: 0, blooms: false, base: 2.2),
        "work.signpost": .plant({ [Workplace.signpost] }, sway: 0, blooms: false, base: 0.5),
        "work.mailbox": .plant({ [Workplace.mailbox(0)] }, sway: 0, blooms: false, base: 0.5),
        "work.noticeboard": .plant({ [Workplace.noticeboard] }, sway: 0, blooms: false, base: 1.35),
        "place.shed": .plant({ [Places.shed(0)] }, sway: 0, blooms: false, base: 2.9),
        "place.tent": .plant({ [Places.tent(0)] }, sway: 0, blooms: false, base: 2.75),
        "cat.box": .plant({ [CatThings.box] }, sway: 0, blooms: false, base: 1.5),
        "cat.scratchingPost": .plant({ [CatThings.scratchingPost] }, sway: 0, blooms: false, base: 0.95),
        "cat.yarn": .plant({ [CatThings.yarn(0)] }, sway: 0, blooms: false, base: 0.5),
        "cat.bed": .plant({ [CatThings.bed(0)] }, sway: 0, blooms: false, base: 1.6),
        "cat.bowl": .plant({ [CatThings.bowl(0)] }, sway: 0, blooms: false, base: 0.6),
        // Lit after dark (`MeadowLamps`), kept off the picnic ground and fading when in front of a cat.
        "work.lampPost": .plant({ [Lamps.post] }, sway: 0, blooms: false, base: 0.8),
        // Not a catalog thing: what a thing from a newer Whiskr shows as while the meadow is edited (Parcel.swift).
        MeadowScenery.parcel: parcelKind,
    ]

    /// The swatches each made thing with a palette may wear, by name, its own first: the same names, in the same
    /// order, as the catalog's `colour` choices (a test holds them together). Their colours are `Palette`'s.
    static let palettes: [String: [String]] = [
        "garden.flowerPot": ["terracotta", "glazeMoss", "glazeCeladon", "glazeBottle"],
        "garden.wateringCan": ["zinc", "sage", "cream", "duckEgg"],
        "work.cushion": ["oat", "sage", "mustard", "rose", "lavender"],
        "work.bench": ["wood", "sage", "cream", "slate"],
        "work.mailbox": ["forest", "cream", "charcoal", "mustard"],
        "place.shed": ["sage", "cream", "forest", "mustard", "lavender"],
        "place.tent": ["canvas", "olive", "ochre", "dove"],
        "cat.yarn": ["oat", "sage", "mustard", "lavender", "rose"],
        "cat.bed": ["oat", "sage", "charcoal", "lavender"],
        "cat.bowl": ["cream", "sage", "terracotta", "charcoal"],
    ]

    /// How each thing with a palette is built in one of its swatches (by index).
    static let painted: [String: @Sendable (Int) -> Plant] = [
        "garden.flowerPot": Garden.flowerPot, "garden.wateringCan": Garden.wateringCan, "work.cushion": Workplace.cushion, "work.bench": Workplace.bench,
        "work.mailbox": Workplace.mailbox, "place.shed": Places.shed, "place.tent": Places.tent, "cat.yarn": CatThings.yarn, "cat.bed": CatThings.bed,
        "cat.bowl": CatThings.bowl,
    ]

    /// The shape a thing standing at a spot is drawn with: its kind's shape for its variant, in the swatch it
    /// wears; the same key, the same shape, so each is made once. Nil for a thing that is not a plant's kind.
    static func shape(of thing: MeadowScenery.Thing) -> (key: ShapeKey, make: () -> Plant)? {
        guard case .plant(let shapes, _, _, _) = kinds[thing.id] else { return nil }
        if let paint = painted[thing.id] {
            let swatch = (palettes[thing.id] ?? []).indices.contains(thing.swatch) ? thing.swatch : 0
            return (ShapeKey(id: thing.id, swatch: swatch), { paint(swatch) })
        }
        let all = shapes()
        let variant = all.indices.contains(thing.variant) ? thing.variant : 0
        return (ShapeKey(id: thing.id, variant: variant), { all[variant] })
    }

    /// Big things beside trees and the log: kept off the picnic ground (a shed, a tent, a fence across it would be
    /// cut through by every blanket laid there; a lamp's light would fall on the blankets and their lanterns, and a
    /// lit lamp among them could be taken for one).
    static let big: Set<String> = ["place.shed", "place.tent", "garden.fence", "work.lampPost"]

    /// Tall made things: each fades on its own when it stands in front of a cat, as a young tree does (a lamp with
    /// a screen of its own, `Meadow.lampScreen`: it has no body to hide a cat behind, only its post).
    static let tall: Set<String> = ["garden.birdhouse", "work.bookshelf", "place.shed", "place.tent", "work.lampPost"]

    /// Things that stand alone (a boulder, wood, made things): placed and taken away one at a time (a click of
    /// the Eraser, never its sweep) and each read out by VoiceOver on its own, never as one of a clump. The other
    /// rooted things (plants, mushrooms, stones) are brushed and swept in numbers.
    static let alone: Set<String> = ["stone.boulder", "wood.stump", "wood.logPile", "work.cushion", "cat.box", "cat.scratchingPost", "cat.yarn", "cat.bed", "cat.bowl",
                                     "garden.flowerPot", "garden.planter", "garden.wateringCan", "garden.birdhouse", "garden.skep", "work.desk", "work.bookshelf",
                                     "work.bench", "work.signpost", "work.mailbox", "work.noticeboard", "place.shed", "place.tent", "work.lampPost"]

    /// Where a cat likes to be at each thing that invites one, on the thing as it is made (its own size and turn,
    /// y up from the ground): sitting on a stump's or a boulder's top, in a box or by a bowl, napping in a bed or
    /// on a cushion, scratching at a post. A thing has one at most.
    static let catSpots: [String: MeadowScenery.CatSpot] = [
        "cat.box": .init(.sit, at: Vec3(0, 0.09, 0), toward: Vec2(0, 1)),
        "cat.bed": .init(.nap, at: Vec3(0, 0.24, 0), toward: Vec2(0, 1)),
        "work.cushion": .init(.nap, at: Vec3(0, 0.62, 0), toward: Vec2(0, 1)),
        "cat.scratchingPost": .init(.scratch, at: Vec3(0, 0, 1.25), toward: Vec2(0, -1)),
        "cat.bowl": .init(.sit, at: Vec3(0, 0, 1.45), toward: Vec2(0, -1)),
        "wood.stump": .init(.sit, at: Vec3(0, 1.05, 0), toward: Vec2(0, 1)),
        "stone.boulder": .init(.sit, at: Vec3(-0.2, 1.62, 0), toward: Vec2(0, 1)),
        "wood.logPile": .init(.sit, at: Vec3(0, 1.73, 0.5), toward: Vec2(0, 1)),
        "wood.fallenLog": .init(.sit, at: Vec3(0, 2.02, 0.5), toward: Vec2(0, 1)),
        // On the bench's seat, on the desk among its things (cats will), on the planter's front board between its
        // lettuces and marigolds, napping on the bookcase's top, on the shed's doorstep, curled on the tent's
        // threshold (its canvas is solid clay: the dark doorway is drawn on its front), and sitting under the nest
        // box looking up at it.
        "work.bench": .init(.sit, at: Vec3(-0.9, 1.1, 0.05), toward: Vec2(0, 1)),
        "work.desk": .init(.sit, at: Vec3(-0.15, 1.36, 0.2), toward: Vec2(0, 1)),
        "garden.planter": .init(.sit, at: Vec3(0.45, 0.88, 0.69), toward: Vec2(0, 1)),
        "work.bookshelf": .init(.nap, at: Vec3(-0.45, 3.3, 0), toward: Vec2(0, 1)),
        "place.shed": .init(.sit, at: Vec3(0, 0, 2.55), toward: Vec2(0, 1)),
        "place.tent": .init(.nap, at: Vec3(0, 0, 3.3), toward: Vec2(0, 1)),
        "garden.birdhouse": .init(.sit, at: Vec3(0, 0, 1.3), toward: Vec2(0, -1)),
    ]

    /// The worktrees' stepping stone (`Picnic.steppingStone`) as a meadow's are laid: its top levelled, a flat
    /// slab sitting a finger's width proud of the turf, its worn face a little less pale so a row of them reads
    /// as stone in the grass rather than as pebbles.
    static let steppingStone: Geometry = {
        var stone = Picnic.steppingStone
        let level: Float = 0.036
        for i in stone.positions.indices where stone.positions[i].y > level {
            stone.positions[i].y = level + (stone.positions[i].y - level) * 0.25
        }
        stone.computeNormals()
        stone.colors = stone.colors.map { $0 * 0.86 }
        return stone
    }()

    /// Things walked on or used, which wear the turf round them (`GroundMap.treads`): the grass short and parted
    /// at their edges, as round real stepping stones in a lawn or a meadow, and as it is flattened round a cat's
    /// bed, bowl or box that stands out in the grass (and gone from under it, so none grows through its floor).
    /// Each with how far it reaches each way along its own x and z at its own size, and whether it is walked on
    /// (a stepping stone) or round (a bed). Found things (a stump, a boulder) stand in the long grass as they are.
    static let treads: [String: (half: Vec2, walked: Bool)] = [
        "stone.stepping": (Vec2(0.64, 0.48), true),
        "cat.box": (Vec2(1.22, 0.97), false),
        "cat.bed": (Vec2(1.45, 1.45), false),
        "cat.bowl": (Vec2(0.5, 0.5), false),
        "cat.scratchingPost": (Vec2(0.85, 0.85), false),
        "cat.yarn": (Vec2(0.38, 0.38), false),
        "work.cushion": (Vec2(0.85, 0.85), false),
        // Made things people come and go to: the grass flattened round a bench's and a desk's feet, gone from under
        // a shed's and a tent's floor, a pot's or a planter's.
        "garden.flowerPot": (Vec2(0.55, 0.55), false),
        "garden.planter": (Vec2(1.65, 0.8), false),
        "garden.wateringCan": (Vec2(0.5, 0.4), false),
        "garden.skep": (Vec2(0.75, 0.75), false),
        "work.desk": (Vec2(1.55, 0.85), false),
        "work.bookshelf": (Vec2(1.3, 0.5), false),
        "work.bench": (Vec2(2.1, 0.7), false),
        "work.noticeboard": (Vec2(1.25, 0.4), false),
        "place.shed": (Vec2(2.35, 1.85), false),
        "place.tent": (Vec2(2.0, 2.45), false),
        // Mown and trodden round a lamp post's base, as round any post in a lawn.
        "work.lampPost": (Vec2(0.7, 0.7), false),
    ]
    static func isTread(_ id: String) -> Bool { treads[id] != nil }

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
