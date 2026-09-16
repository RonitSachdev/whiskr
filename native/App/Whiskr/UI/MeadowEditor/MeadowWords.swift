import Foundation
import MeadowFile
import MeadowScene
import WhiskrMeadow

/// What the meadow's editor says, in the app's words (docs/DESIGN.md, "Words"): the names of the things a
/// meadow holds, why an edit was not made, and each step's name in Edit › Undo ("Undo Move Oak").
enum MeadowWords {
    /// A thing's name, as a label ("Oak").
    static func name(_ id: String) -> String {
        switch id {
        case "tree.oak": String(localized: "Oak", comment: "Meadow editor: a thing's name")
        case "tree.birch": String(localized: "Birch", comment: "Meadow editor: a thing's name")
        case "tree.cherry": String(localized: "Cherry tree", comment: "Meadow editor: a thing's name")
        case "tree.young": String(localized: "Young tree", comment: "Meadow editor: a thing's name")
        case "tree.apple": String(localized: "Apple tree", comment: "Meadow editor: a thing's name")
        case "tree.pine": String(localized: "Pine", comment: "Meadow editor: a thing's name (a Scots pine)")
        case "flower.daisy": String(localized: "Daisy", comment: "Meadow editor: a thing's name")
        case "flower.buttercup": String(localized: "Buttercup", comment: "Meadow editor: a thing's name")
        case "flower.lupin": String(localized: "Lupin", comment: "Meadow editor: a thing's name")
        case "flower.poppy": String(localized: "Poppy", comment: "Meadow editor: a thing's name")
        case "flower.cornflower": String(localized: "Cornflower", comment: "Meadow editor: a thing's name")
        case "flower.foxglove": String(localized: "Foxglove", comment: "Meadow editor: a thing's name")
        case "plant.fern": String(localized: "Fern", comment: "Meadow editor: a thing's name")
        case "plant.clover": String(localized: "Clover", comment: "Meadow editor: a thing's name (white clover)")
        case "fungus.flyAgaric": String(localized: "Fly agaric", comment: "Meadow editor: a thing's name")
        case "stone.stone": String(localized: "Stone", comment: "Meadow editor: a thing's name")
        case "stone.mossy": String(localized: "Mossy stone", comment: "Meadow editor: a thing's name")
        case "stone.boulder": String(localized: "Boulder", comment: "Meadow editor: a thing's name")
        case "stone.stepping": String(localized: "Stepping stone", comment: "Meadow editor: a thing's name")
        case "wood.fallenLog": String(localized: "Fallen log", comment: "Meadow editor: a thing's name")
        case "wood.stump": String(localized: "Tree stump", comment: "Meadow editor: a thing's name")
        case "wood.logPile": String(localized: "Log pile", comment: "Meadow editor: a thing's name")
        case "work.cushion": String(localized: "Floor cushion", comment: "Meadow editor: a thing's name (a square cushion to sit on, a zabuton)")
        case "cat.box": String(localized: "Cardboard box", comment: "Meadow editor: a thing's name (one a cat sits in)")
        case "cat.scratchingPost": String(localized: "Scratching post", comment: "Meadow editor: a thing's name (a cat's)")
        case "cat.yarn": String(localized: "Ball of yarn", comment: "Meadow editor: a thing's name")
        case "cat.bed": String(localized: "Cat bed", comment: "Meadow editor: a thing's name")
        case "cat.bowl": String(localized: "Food bowl", comment: "Meadow editor: a thing's name (a cat's)")
        case "ground.path": String(localized: "Path", comment: "Meadow editor: a ground paint's name (worn earth)")
        case "ground.lawn": String(localized: "Lawn", comment: "Meadow editor: a ground paint's name (grass mown short)")
        case "ground.soil": String(localized: "Soil", comment: "Meadow editor: a ground paint's name (bare earth for flower beds)")
        case wildGround: String(localized: "Wild Grass", comment: "Meadow editor: the Ground tool's paint that brings back the meadow's own long grass")
        case MeadowScenery.parcel: MeadowFileWords.parcelName
        default: String(localized: "Thing", comment: "Meadow editor: a thing with no name of its own")
        }
    }

    /// A clump of one kind, for VoiceOver ("Daisies, 9").
    static func clump(_ id: String, count: Int) -> String {
        String(localized: "\(clumpName(id)), \(count)", comment: "VoiceOver: a clump of one kind of plant or stone, and how many")
    }

    /// The things an edit is about, in a step's name: one by its name, several by how many.
    static func things(_ ids: [String]) -> String {
        if ids.count == 1, let id = ids.first { return name(id) }
        return String(localized: "\(ids.count) Things", comment: "Meadow editor: several things, in a step's name (Move 3 Things)")
    }

    /// Why an edit was not made, as the badge by the pointer and VoiceOver say it.
    static func refusal(_ refusal: MeadowEditRefusal) -> String {
        switch refusal {
        case .outsideMeadow:
            String(localized: "Outside the meadow", comment: "Meadow editor: why a thing cannot stand there")
        case .keptForWorkspaces:
            String(localized: "Kept clear for your workspaces", comment: "Meadow editor: why a big thing cannot stand on the picnic ground")
        case .tooClose(MeadowScenery.parcel):
            String(localized: "Too close to a thing from a newer Whiskr", comment: "Meadow editor: why a thing cannot stand there (a parcel is in the way)")
        case .tooClose(let id):
            String(localized: "Too close to the \(name(id).lowercased())", comment: "Meadow editor: why a thing cannot stand there (the thing in the way)")
        case .full(.trees, let limit):
            String(localized: "The meadow has as many trees as it can hold (\(limit))", comment: "Meadow editor: a cap reached")
        case .full(.tall, let limit):
            String(localized: "The meadow has as many tall things as it can hold (\(limit))", comment: "Meadow editor: a cap reached (trees, the log and other tall things)")
        case .full(.lamps, let limit):
            String(localized: "The meadow has as many lamps as it can hold (\(limit))", comment: "Meadow editor: a cap reached")
        case .full(.fencePosts, let limit):
            String(localized: "The meadow has as much fence as it can hold (\(limit) posts)", comment: "Meadow editor: a cap reached")
        case .full(.madeThings, let limit):
            String(localized: "The meadow has as many made things as it can hold (\(limit))", comment: "Meadow editor: a cap reached (benches, boxes and the like)")
        case .full(nil, let limit):
            String(localized: "The meadow has as many things as it can hold (\(limit))", comment: "Meadow editor: a cap reached")
        case .noRoom:
            String(localized: "No room nearby", comment: "Meadow editor: copies found no free ground near")
        case .largest:
            String(localized: "As large as it grows", comment: "Meadow editor: a living thing cannot grow more")
        case .smallest:
            String(localized: "As small as it grows", comment: "Meadow editor: a living thing cannot shrink more")
        case .keepsItsSize:
            String(localized: "Only living things change size", comment: "Meadow editor: stones and made things keep their size")
        case .groundFull:
            String(localized: "The ground holds as much painting as a meadow can keep", comment: "Meadow editor: the painted ground's detail reached what a meadow file holds")
        }
    }

    // The tray's words.

    /// A shelf's category, as its tab says it.
    static func categoryName(_ category: MeadowAsset.Category?) -> String {
        switch category {
        case .trees: String(localized: "Trees", comment: "Meadow editor's tray: a category")
        case .flowers: String(localized: "Flowers", comment: "Meadow editor's tray: a category (flowers, plants, mushrooms)")
        case .stonesAndWood: String(localized: "Stones & Wood", comment: "Meadow editor's tray: a category")
        case .ground: String(localized: "Ground", comment: "Meadow editor's tray: a category (paths, lawn, soil)")
        case .garden: String(localized: "Garden", comment: "Meadow editor's tray: a category")
        case .workplace: String(localized: "Workplace", comment: "Meadow editor's tray: a category")
        case .catThings: String(localized: "Cat Things", comment: "Meadow editor's tray: a category")
        case nil: ""
        }
    }

    /// A category's symbol, where the tray is narrow.
    static func categorySymbol(_ category: MeadowAsset.Category) -> String {
        switch category {
        case .trees: "tree"
        case .flowers: "camera.macro"
        case .stonesAndWood: "mountain.2"
        case .ground: "square.split.diagonal.2x2"
        case .garden: "leaf"
        case .workplace: "chair.lounge"
        case .catThings: "pawprint"
        }
    }

    /// The Brush's mix of the meadow's own wildflowers, and the Eraser's choice of any small thing.
    static var wildflowers: String { String(localized: "Wildflowers", comment: "Meadow editor's tray: the Brush's mix of daisies, buttercups, lupins and poppies") }
    static var anyKind: String { String(localized: "Any Kind", comment: "Meadow editor's tray: the Eraser clears whatever small thing it passes") }
    /// The Ground tool's paint that brings the meadow's own long grass back (the catalog's eraser of paints).
    static let wildGround = "ground.wild"

    static func density(_ density: MeadowBrush.Density) -> String {
        switch density {
        case .sparse: String(localized: "Sparse", comment: "Meadow editor's tray: how thickly the Brush plants")
        case .natural: String(localized: "Natural", comment: "Meadow editor's tray: how thickly the Brush plants")
        case .dense: String(localized: "Dense", comment: "Meadow editor's tray: how thickly the Brush plants")
        }
    }

    /// What to do now, in the tray's line.
    static func hint(_ tool: EditorTray.Tool, armed: Bool) -> String {
        switch tool {
        case .select where armed:
            String(localized: "Click to place it · ⇧-click to place more · R turns it · Esc puts it back", comment: "Meadow editor's tray: what to do with a thing armed")
        case .select:
            String(localized: "Choose a thing to place, or drag it onto the meadow", comment: "Meadow editor's tray: what to do with the Select tool")
        case .brush:
            String(localized: "Drag on the grass to plant · ⌥-drag clears · [ and ] change the size", comment: "Meadow editor's tray: what to do with the Brush")
        case .erase:
            String(localized: "Click a thing to take it away · drag to sweep plants and stones · [ and ] change the size",
                   comment: "Meadow editor's tray: what to do with the Eraser")
        case .ground:
            String(localized: "Drag to paint the ground · ⌥-drag brings the wild grass back · [ and ] change the size",
                   comment: "Meadow editor's tray: what to do with the Ground tool")
        }
    }

    /// How full the meadow is, in the tray's top row ("4,212 of 5,000 things", "40 of 48 trees").
    static func fullness(_ count: Int, of limit: Int, _ cap: MeadowCatalog.Cap?) -> String {
        switch cap {
        case .trees: String(localized: "\(count) of \(limit) trees", comment: "Meadow editor's tray: how full the meadow is")
        case .tall: String(localized: "\(count) of \(limit) tall things", comment: "Meadow editor's tray: how full the meadow is")
        default: String(localized: "\(count) of \(limit) things", comment: "Meadow editor's tray: how full the meadow is")
        }
    }

    /// A change other than moving or taking away, asked of things shown as parcels.
    static var parcelsOnlyMove: String {
        String(localized: "Things from a newer Whiskr can only be moved or taken away", comment: "Meadow editor: why a parcel cannot be turned, sized or copied")
    }

    /// The Eraser's click on a thing of another kind than the one it clears.
    static func onlyErasing(_ id: String) -> String {
        String(localized: "The Eraser clears only \(clumpName(id).lowercased()) now", comment: "Meadow editor: the Eraser's kind is set to another")
    }

    /// The name of several of a kind ("Daisies").
    static func clumpName(_ id: String) -> String {
        switch id {
        case "flower.daisy": String(localized: "Daisies", comment: "Meadow editor: a clump of them, for VoiceOver")
        case "flower.buttercup": String(localized: "Buttercups", comment: "Meadow editor: a clump of them, for VoiceOver")
        case "flower.lupin": String(localized: "Lupins", comment: "Meadow editor: a clump of them, for VoiceOver")
        case "flower.poppy": String(localized: "Poppies", comment: "Meadow editor: a clump of them, for VoiceOver")
        case "fungus.flyAgaric": String(localized: "Fly agarics", comment: "Meadow editor: a clump of them, for VoiceOver")
        case "stone.stone": String(localized: "Stones", comment: "Meadow editor: a clump of them, for VoiceOver")
        case "stone.mossy": String(localized: "Mossy stones", comment: "Meadow editor: a clump of them, for VoiceOver")
        case "stone.stepping": String(localized: "Stepping stones", comment: "Meadow editor: a clump of them, for VoiceOver")
        case "flower.cornflower": String(localized: "Cornflowers", comment: "Meadow editor: a clump of them, for VoiceOver")
        case "flower.foxglove": String(localized: "Foxgloves", comment: "Meadow editor: a clump of them, for VoiceOver")
        case "plant.fern": String(localized: "Ferns", comment: "Meadow editor: a clump of them, for VoiceOver")
        case EditorTray.wildflowers: wildflowers
        default: name(id)
        }
    }

    /// Other words people look for a thing by, for the tray's filter (besides its name and its shelf's): what it
    /// is also called, and what it is for. In Japanese, the readings of names written in kanji too.
    static func keywords(_ id: String) -> String {
        switch id {
        case "tree.cherry": String(localized: "blossom, sakura", comment: "Meadow editor's filter: other words for the cherry tree, comma-separated")
        case "tree.young": String(localized: "sapling", comment: "Meadow editor's filter: other words for the young tree, comma-separated")
        case "tree.apple": String(localized: "fruit, orchard", comment: "Meadow editor's filter: other words for the apple tree, comma-separated")
        case "tree.pine": String(localized: "Scots pine, conifer, evergreen, fir", comment: "Meadow editor's filter: other words for the pine, comma-separated")
        case "flower.lupin": String(localized: "lupine", comment: "Meadow editor's filter: other words for the lupin, comma-separated")
        case "flower.cornflower": String(localized: "blue, bachelor's button", comment: "Meadow editor's filter: other words for the cornflower, comma-separated")
        case "flower.foxglove": String(localized: "digitalis, bells", comment: "Meadow editor's filter: other words for the foxglove, comma-separated")
        case "plant.fern": String(localized: "bracken, frond, shade", comment: "Meadow editor's filter: other words for the fern, comma-separated")
        case "plant.clover": String(localized: "shamrock, trefoil, white clover", comment: "Meadow editor's filter: other words for clover, comma-separated")
        case "fungus.flyAgaric": String(localized: "mushroom, toadstool", comment: "Meadow editor's filter: other words for the fly agaric, comma-separated")
        case "stone.stone", "stone.mossy": String(localized: "rock, pebble", comment: "Meadow editor's filter: other words for a stone, comma-separated")
        case "stone.boulder": String(localized: "rock, seat", comment: "Meadow editor's filter: other words for the boulder, comma-separated")
        case "stone.stepping": String(localized: "path, paving", comment: "Meadow editor's filter: other words for the stepping stone, comma-separated")
        case "wood.fallenLog": String(localized: "trunk, timber", comment: "Meadow editor's filter: other words for the fallen log, comma-separated")
        case "wood.stump": String(localized: "seat, wood", comment: "Meadow editor's filter: other words for the tree stump, comma-separated")
        case "wood.logPile": String(localized: "logs, firewood, woodpile", comment: "Meadow editor's filter: other words for the log pile, comma-separated")
        case "work.cushion": String(localized: "zabuton, pillow, seat", comment: "Meadow editor's filter: other words for the floor cushion, comma-separated")
        case "cat.box": String(localized: "carton, cat", comment: "Meadow editor's filter: other words for the cardboard box, comma-separated")
        case "cat.scratchingPost": String(localized: "scratcher, cat tree, cat", comment: "Meadow editor's filter: other words for the scratching post, comma-separated")
        case "cat.yarn": String(localized: "wool, toy, cat", comment: "Meadow editor's filter: other words for the ball of yarn, comma-separated")
        case "cat.bed": String(localized: "basket, nap, sleep, cat", comment: "Meadow editor's filter: other words for the cat bed, comma-separated")
        case "cat.bowl": String(localized: "dish, food, kibble, cat", comment: "Meadow editor's filter: other words for the food bowl, comma-separated")
        default: ""
        }
    }

    // Each step's name, as Edit › Undo and the top bar's Undo say it.
    static func move(_ ids: [String]) -> String { String(localized: "Move \(things(ids))", comment: "Meadow editor: a step's name") }
    static func turn(_ ids: [String]) -> String { String(localized: "Turn \(things(ids))", comment: "Meadow editor: a step's name") }
    static func resize(_ ids: [String]) -> String { String(localized: "Resize \(things(ids))", comment: "Meadow editor: a step's name") }
    static func duplicate(_ ids: [String]) -> String { String(localized: "Duplicate \(things(ids))", comment: "Meadow editor: a step's name") }
    static func delete(_ ids: [String]) -> String { String(localized: "Delete \(things(ids))", comment: "Meadow editor: a step's name") }
    static func cut(_ ids: [String]) -> String { String(localized: "Cut \(things(ids))", comment: "Meadow editor: a step's name") }
    static func paste(_ ids: [String]) -> String { String(localized: "Paste \(things(ids))", comment: "Meadow editor: a step's name") }
    static func shuffle(_ ids: [String]) -> String { String(localized: "Shuffle \(things(ids))", comment: "Meadow editor: a step's name") }
    static func place(_ ids: [String]) -> String { String(localized: "Place \(things(ids))", comment: "Meadow editor: a step's name") }
    static func erase(_ ids: [String]) -> String { String(localized: "Erase \(things(ids))", comment: "Meadow editor: a step's name") }
    /// A Ground stroke: "Paint Path", "Paint Wild Grass".
    static func paint(_ id: String) -> String {
        String(localized: "Paint \(name(id))", comment: "Meadow editor: a step's name (a Ground stroke and what it painted)")
    }
    /// A row of stepping stones laid along a drag: "Lay 9 Stepping Stones" (one alone is placed).
    static func lay(_ count: Int) -> String {
        guard count != 1 else { return place(["stone.stepping"]) }
        return String(localized: "Lay \(count) Stepping Stones", comment: "Meadow editor: a step's name (stepping stones laid along a drag)")
    }
    /// A Brush stroke: "Brush Daisies", "Brush Wildflowers".
    static func brush(_ kind: String) -> String {
        String(localized: "Brush \(clumpName(kind))", comment: "Meadow editor: a step's name (a Brush stroke and what it planted)")
    }

    /// Where a thing is, for VoiceOver: "12 units north-west of the picnic ground", or on it.
    static func whereIs(_ at: MeadowPoint) -> String {
        let g = (minX: -20.0, maxX: 20.0, minZ: -3.0, maxZ: 120.0)
        let dx = at.x < g.minX ? at.x - g.minX : at.x > g.maxX ? at.x - g.maxX : 0
        let dz = at.z < g.minZ ? at.z - g.minZ : at.z > g.maxZ ? at.z - g.maxZ : 0
        let far = Int(hypot(dx, dz).rounded())
        guard far > 0 else { return String(localized: "on the picnic ground", comment: "VoiceOver: where a thing stands in the meadow") }
        // North is away along the meadow (−z), east to the right (+x).
        let angle = atan2(dx, -dz) * 180 / .pi
        let names = [String(localized: "north", comment: "VoiceOver: a direction in the meadow"), String(localized: "north-east", comment: "VoiceOver: a direction in the meadow"),
                     String(localized: "east", comment: "VoiceOver: a direction in the meadow"), String(localized: "south-east", comment: "VoiceOver: a direction in the meadow"),
                     String(localized: "south", comment: "VoiceOver: a direction in the meadow"), String(localized: "south-west", comment: "VoiceOver: a direction in the meadow"),
                     String(localized: "west", comment: "VoiceOver: a direction in the meadow"), String(localized: "north-west", comment: "VoiceOver: a direction in the meadow")]
        let direction = names[(Int(((angle + 360 + 22.5).truncatingRemainder(dividingBy: 360)) / 45)) % 8]
        return String(localized: "\(far) units \(direction) of the picnic ground", comment: "VoiceOver: how far and which way a thing stands from the picnic ground")
    }
}
