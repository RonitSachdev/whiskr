import Foundation

/// Everything a meadow can hold, by id: what kind of thing each is, which fields and options it takes,
/// their ranges, and since which catalog each exists. A catalog is a number; each release that adds
/// assets, parameters or choices is a new one, and a meadow file says which it was written with and
/// which it needs (`MeadowDocument.needsCatalog`).
///
/// Rules (checked by the catalog tests, which hold the list of released ids):
/// 1. An id, once in a released catalog, means that thing forever; it is never reused and never removed.
/// 2. Renames go through `aliases`: reading maps the old id, writing writes the new one. An alias is
///    never removed.
/// 3. Retiring an asset takes it out of the tray only (`inTray`); files that use it still show it.
/// 4. A replacement that changes the look maps through a catalog step (`MeadowMigration`), never silently.
/// 5. Each asset, parameter, choice and variant carries `since`. Once released, an asset's ranges,
///    parameters' types, ranges and defaults never change (a value outside a range is clamped when read,
///    so a later, wider range would be lost in an older app): a change is a new parameter.
public struct MeadowCatalog: Sendable {
    /// This catalog's number.
    public let number: Int
    public let assets: [MeadowAsset]
    /// Old id → the id it is now.
    public let aliases: [String: String]
    private let byId: [String: MeadowAsset]

    public init(number: Int, assets: [MeadowAsset], aliases: [String: String] = [:]) {
        self.number = number
        self.assets = assets
        self.aliases = aliases
        byId = Dictionary(assets.map { ($0.id, $0) }) { first, _ in first }
    }

    /// The catalog this Whiskr draws.
    public static let current = one

    /// The asset `id` names, after aliases; nil when this catalog does not know it.
    public func asset(_ id: String) -> MeadowAsset? {
        byId[aliases[id] ?? id]
    }

    /// What `id` is called now: its alias's target, or itself.
    public func currentId(_ id: String) -> String {
        aliases[id] ?? id
    }

    /// Whether `id` is shaped as an asset id: a lower-case namespace and one or more dot-separated
    /// names of letters and digits, at most 64 characters (`tree.oak`, `cat.scratchingPost`).
    public static func isWellFormed(_ id: String) -> Bool {
        guard !id.isEmpty, id.utf8.count <= 64 else { return false }
        let parts = id.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2, let namespace = parts.first, !namespace.isEmpty,
              namespace.utf8.allSatisfy({ (UInt8(ascii: "a")...UInt8(ascii: "z")).contains($0) }) else { return false }
        return parts.dropFirst().allSatisfy { part in
            !part.isEmpty && part.utf8.allSatisfy { byte in
                (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte) || (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte)
                    || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
            }
        }
    }

    // MARK: - Caps

    /// How many things of a kind a meadow may hold (each cap tested at the cap). Every thing, including
    /// one from a newer Whiskr, counts toward `MeadowFormat.maxItems`.
    public enum Cap: String, Sendable, CaseIterable {
        /// Trees, young trees included.
        case trees
        /// Tall things, each with an occlusion screen that fades it when it stands in front of a cat.
        case tall
        case lamps
        /// Fence posts, across every run (`MeadowCatalog.posts(along:)`).
        case fencePosts
        /// Made things other than lamps and fences.
        case madeThings

        public var limit: Int {
            switch self {
            case .trees: 48
            case .tall: 120
            case .lamps: 32
            case .fencePosts: 600
            case .madeThings: 400
            }
        }
    }

    /// Between fence posts along a run, in units.
    public static let fencePostSpacing = 2.5

    /// The posts a fence run along `points` stands on: one at the start, then one at least every
    /// `fencePostSpacing` along each segment, and one at each segment's end.
    public static func posts(along points: [MeadowPoint]) -> Int {
        guard points.count >= 2 else { return points.count }
        var posts = 1
        for (a, b) in zip(points, points.dropFirst()) {
            posts += max(1, Int((hypot(b.x - a.x, b.z - a.z) / fencePostSpacing).rounded(.up)))
        }
        return posts
    }
}

/// One thing a meadow can hold, or one ground paint.
public struct MeadowAsset: Sendable, Equatable {
    /// The tray's categories.
    public enum Category: String, Sendable, CaseIterable {
        case trees, flowers, stonesAndWood, ground, garden, workplace, catThings
    }

    /// What it is, which decides how it is placed.
    public enum Nature: String, Sendable {
        /// Grows: real size within a range, leans, varies in size.
        case living
        /// Stones and wood: found, not made.
        case natural
        /// Made things: cat-sized, never scaled.
        case made
        /// Paint for the ground, not a thing; listed in `ground.paints`, never in `items`.
        case paint
        /// The tray's paint that brings the meadow's own long grass back: paints cell 0, so never stored.
        case eraser
    }

    /// How it is put in the meadow.
    public enum Shape: String, Sendable {
        /// At one spot (`at`), turned (`turn`).
        case single
        /// Along a run of 2–64 points (`points`): fences.
        case run
    }

    public let id: String
    /// The catalog it first came in.
    public let since: Int
    public let category: Category
    public let nature: Nature
    public let shape: Shape
    /// The scale each axis of `size` may take, around the asset's own size (always holding 1, the size
    /// of one written without `size`); nil when it never scales (no `size` field).
    public let size: ClosedRange<Double>?
    /// The largest lean either way, radians; nil when it never leans (no `tilt` field).
    public let tilt: Double?
    /// Grown from a 32-bit seed (`seed`), so no two are alike.
    public let seeded: Bool
    /// Each alternate shape's `since`, by its `variant` number; one entry for a single shape.
    public let variants: [Int]
    public let parameters: [MeadowParameter]
    /// The caps it counts toward.
    public let caps: [MeadowCatalog.Cap]
    /// Offered in the tray; false once retired.
    public let inTray: Bool

    public init(_ id: String, since: Int = 1, _ category: Category, _ nature: Nature, shape: Shape = .single,
                size: ClosedRange<Double>? = nil, tilt: Double? = nil, seeded: Bool = false, variants: [Int] = [1],
                parameters: [MeadowParameter] = [], caps: [MeadowCatalog.Cap] = [], inTray: Bool = true) {
        self.id = id
        self.since = since
        self.category = category
        self.nature = nature
        self.shape = shape
        self.size = size
        self.tilt = tilt
        self.seeded = seeded
        self.variants = variants
        self.parameters = parameters
        self.caps = caps
        self.inTray = inTray
    }

    public func parameter(_ name: String) -> MeadowParameter? {
        parameters.first { $0.name == name }
    }
}

/// One option of an asset, kept in the item's `params`. Missing means the default; a number outside
/// the range is clamped; a choice this catalog does not know is kept as written and drawn as the
/// default; a parameter this catalog does not know is kept as written.
public struct MeadowParameter: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// A whole number in a range.
        case integer(ClosedRange<Int>, default: Int)
        /// One of named choices, each with its own `since`; the default is the first.
        case choice([Choice])
    }

    public struct Choice: Sendable, Equatable {
        public let name: String
        public let since: Int
        public init(_ name: String, since: Int = 1) {
            self.name = name
            self.since = since
        }
    }

    public let name: String
    public let since: Int
    public let kind: Kind

    public init(_ name: String, since: Int = 1, _ kind: Kind) {
        self.name = name
        self.since = since
        self.kind = kind
    }

    /// A colour from the item's own small clay palette: named swatches (the scene holds their colours),
    /// never a free colour, never a state colour.
    public static func colour(_ swatches: String..., since: Int = 1) -> MeadowParameter {
        MeadowParameter("colour", since: since, .choice(swatches.map { Choice($0, since: since) }))
    }
}

// MARK: - Catalog 1

extension MeadowCatalog {
    /// Catalog 1: what the full editor ships with. Its size and lean ranges hold everything today's
    /// meadow grows (flowers 0.68–1.44 on an axis, stones 0.17–2.88, fly agarics 0.6–1.84, young
    /// trees 0.77–1.5; leans up to 0.12), so the Default is a catalog-1 meadow with nothing clamped; the tray draws new things
    /// from narrower ranges inside these.
    public static let one = MeadowCatalog(number: 1, assets: [
        // Trees: grown uniquely from a seed; real size.
        .init("tree.oak", .trees, .living, size: 0.8...1.2, tilt: 0.05, seeded: true, caps: [.trees, .tall]),
        .init("tree.birch", .trees, .living, size: 0.8...1.2, tilt: 0.05, seeded: true, caps: [.trees, .tall]),
        .init("tree.cherry", .trees, .living, size: 0.8...1.2, tilt: 0.05, seeded: true, caps: [.trees, .tall]),
        .init("tree.young", .trees, .living, size: 0.75...1.55, tilt: 0.05, seeded: true, caps: [.trees, .tall]),
        .init("tree.apple", .trees, .living, size: 0.8...1.2, tilt: 0.05, seeded: true, caps: [.trees, .tall]),
        .init("tree.pine", .trees, .living, size: 0.8...1.2, tilt: 0.05, seeded: true, caps: [.trees, .tall]),

        // Flowers and plants: brushed in clumps; the first four have today's two shapes each.
        .init("flower.daisy", .flowers, .living, size: 0.65...1.5, tilt: 0.15, variants: [1, 1]),
        .init("flower.buttercup", .flowers, .living, size: 0.65...1.5, tilt: 0.15, variants: [1, 1]),
        .init("flower.lupin", .flowers, .living, size: 0.65...1.5, tilt: 0.15, variants: [1, 1]),
        .init("flower.poppy", .flowers, .living, size: 0.65...1.5, tilt: 0.15, variants: [1, 1]),
        .init("flower.cornflower", .flowers, .living, size: 0.65...1.5, tilt: 0.15),
        .init("flower.foxglove", .flowers, .living, size: 0.65...1.5, tilt: 0.15),
        .init("plant.fern", .flowers, .living, size: 0.65...1.5, tilt: 0.15),
        .init("plant.clover", .flowers, .living, size: 0.65...1.5, tilt: 0.15),
        .init("fungus.flyAgaric", .flowers, .living, size: 0.55...1.9, tilt: 0.12, variants: [1, 1]),

        // Stones and wood. A boulder is a stone at twice a stone's size before its own `size`.
        .init("stone.stone", .stonesAndWood, .natural, size: 0.15...2.9, tilt: 0.08),
        .init("stone.mossy", .stonesAndWood, .natural, size: 0.15...2.9, tilt: 0.08),
        .init("stone.boulder", .stonesAndWood, .natural, size: 0.75...1.3, tilt: 0.08),
        .init("stone.stepping", .stonesAndWood, .natural, size: 0.8...1.2),
        .init("wood.fallenLog", .stonesAndWood, .natural, caps: [.tall]),
        .init("wood.stump", .stonesAndWood, .natural),
        .init("wood.logPile", .stonesAndWood, .natural),

        // Ground paints, and the eraser that paints them away.
        .init("ground.path", .ground, .paint),
        .init("ground.lawn", .ground, .paint),
        .init("ground.soil", .ground, .paint),
        .init("ground.wild", .ground, .eraser),

        // Garden: made things, cat-sized. A fence's `gate` is the span (1-based) that opens; 0 for none.
        .init("garden.fence", .garden, .made, shape: .run, parameters: [MeadowParameter("gate", .integer(0...63, default: 0))],
              caps: [.fencePosts]),
        .init("garden.flowerPot", .garden, .made, parameters: [.colour("terracotta", "glazeMoss", "glazeCeladon", "glazeBottle")],
              caps: [.madeThings]),
        .init("garden.planter", .garden, .made, caps: [.madeThings]),
        .init("garden.wateringCan", .garden, .made, parameters: [.colour("zinc", "sage", "cream", "duckEgg")], caps: [.madeThings]),
        .init("garden.birdhouse", .garden, .made, caps: [.madeThings, .tall]),
        .init("garden.skep", .garden, .made, caps: [.madeThings]),

        // Workplace.
        .init("work.desk", .workplace, .made, caps: [.madeThings]),
        .init("work.cushion", .workplace, .made, parameters: [.colour("oat", "sage", "mustard", "rose", "lavender")], caps: [.madeThings]),
        .init("work.bookshelf", .workplace, .made, caps: [.madeThings, .tall]),
        .init("work.bench", .workplace, .made, parameters: [.colour("wood", "sage", "cream", "slate")], caps: [.madeThings]),
        .init("work.signpost", .workplace, .made, caps: [.madeThings]),
        .init("work.mailbox", .workplace, .made, parameters: [.colour("forest", "cream", "charcoal", "mustard")], caps: [.madeThings]),
        .init("work.noticeboard", .workplace, .made, caps: [.madeThings]),
        .init("work.lampPost", .workplace, .made, caps: [.lamps, .tall]),
        .init("place.shed", .workplace, .made, parameters: [.colour("sage", "cream", "forest", "mustard", "lavender")],
              caps: [.madeThings, .tall]),
        .init("place.tent", .workplace, .made, parameters: [.colour("canvas", "olive", "ochre", "dove")], caps: [.madeThings, .tall]),

        // Cat things: decoration; cats do not use them.
        .init("cat.box", .catThings, .made, caps: [.madeThings]),
        .init("cat.scratchingPost", .catThings, .made, caps: [.madeThings]),
        .init("cat.yarn", .catThings, .made, parameters: [.colour("oat", "sage", "mustard", "lavender", "rose")], caps: [.madeThings]),
        .init("cat.bed", .catThings, .made, parameters: [.colour("oat", "sage", "charcoal", "lavender")], caps: [.madeThings]),
        .init("cat.bowl", .catThings, .made, parameters: [.colour("cream", "sage", "terracotta", "charcoal")], caps: [.madeThings]),
    ])
}
