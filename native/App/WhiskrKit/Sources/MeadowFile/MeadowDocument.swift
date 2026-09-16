import Foundation

/// A meadow: the scenery a person made, as plain values. Read from and written to a `.whiskrmeadow`
/// file by `MeadowFile`; it knows nothing of workspaces, folders, accounts or themes.
///
/// What this Whiskr does not understand (things, fields, parameters, choices, shapes, sections and
/// paints from a newer one) is kept here as it was read and written back unchanged, so a meadow made
/// with a newer Whiskr survives being edited in an older one.
public struct MeadowDocument: Equatable, Sendable {
    /// The world it is laid out on. Only `meadow` exists so far.
    public var base: String
    /// Plain text, sanitised (`MeadowText`). Empty is allowed; the app shows its own "Untitled Meadow".
    public var name: String
    public var author: String
    public var description: String
    /// Every placed thing, in the file's order (things from a newer Whiskr in their place among them).
    public var entries: [MeadowEntry]
    /// The painted ground; nil for a meadow with no paint.
    public var ground: GroundGrid?
    /// Top-level sections from a newer Whiskr, by key.
    public var unknownSections: [String: MeadowJSON]
    /// What the file it was read from said about itself; nil for a meadow made here.
    public var readFrom: Provenance?

    /// What a file says about how it was written.
    public struct Provenance: Equatable, Sendable {
        public var formatMajor: Int
        public var formatMinor: Int
        /// The Whiskr version that saved it, when it named a well-formed one.
        public var writtenBy: String?
        public var catalog: Int
        public var needsCatalog: Int

        public init(formatMajor: Int, formatMinor: Int, writtenBy: String?, catalog: Int, needsCatalog: Int) {
            self.formatMajor = formatMajor
            self.formatMinor = formatMinor
            self.writtenBy = writtenBy
            self.catalog = catalog
            self.needsCatalog = needsCatalog
        }
    }

    public init(base: String = MeadowFormat.meadowBase, name: String = "", author: String = "", description: String = "",
                entries: [MeadowEntry] = [], ground: GroundGrid? = nil, unknownSections: [String: MeadowJSON] = [:],
                readFrom: Provenance? = nil) {
        self.base = base
        self.name = name
        self.author = author
        self.description = description
        self.entries = entries
        self.ground = ground
        self.unknownSections = unknownSections
        self.readFrom = readFrom
    }

    /// Empty Meadow: grass, hills and sky, nothing else.
    public static let empty = MeadowDocument()

    /// The things this Whiskr knows, in order.
    public var items: [MeadowItem] {
        entries.compactMap { if case .item(let item) = $0 { item } else { nil } }
    }

    /// The things from a newer Whiskr, in order.
    public var parcels: [MeadowParcel] {
        entries.compactMap { if case .parcel(let parcel) = $0 { parcel } else { nil } }
    }

    /// Whether anything here is kept only because a newer Whiskr wrote it.
    public func hasNewerContent(_ catalog: MeadowCatalog) -> Bool {
        if !unknownSections.isEmpty { return true }
        if let ground, ground.hasNewerContent(catalog) { return true }
        for entry in entries {
            switch entry {
            case .parcel: return true
            case .item(let item): if item.hasNewerContent(catalog) { return true }
            }
        }
        return false
    }

    /// How much of each kind with a cap the meadow holds (`MeadowCatalog.Cap`): things, or fence posts.
    public func counts(_ catalog: MeadowCatalog) -> [MeadowCatalog.Cap: Int] {
        var counts: [MeadowCatalog.Cap: Int] = [:]
        for item in items {
            guard let asset = catalog.asset(item.asset) else { continue }
            for cap in asset.caps {
                if cap == .fencePosts, case .run(let points) = item.placement {
                    counts[cap, default: 0] += MeadowCatalog.posts(along: points)
                } else {
                    counts[cap, default: 0] += 1
                }
            }
        }
        return counts
    }

    /// The oldest catalog that holds every asset, parameter, choice, variant and paint used here: what a
    /// file says it needs. Content kept from a newer Whiskr needs at least what its file needed.
    public func needsCatalog(_ catalog: MeadowCatalog) -> Int {
        var needs = 1
        for item in items {
            guard let asset = catalog.asset(item.asset) else { continue }
            needs = max(needs, asset.since)
            if item.variant > 0, item.variant < asset.variants.count { needs = max(needs, asset.variants[item.variant]) }
            for (name, value) in item.params {
                guard let parameter = asset.parameter(name) else { continue }
                needs = max(needs, parameter.since)
                if case .choice(let choices) = parameter.kind, let chosen = value.string,
                   let choice = choices.first(where: { $0.name == chosen }) {
                    needs = max(needs, choice.since)
                }
            }
        }
        for paint in ground?.paints ?? [] {
            if let asset = catalog.asset(paint) { needs = max(needs, asset.since) }
        }
        if hasNewerContent(catalog), let readFrom { needs = max(needs, readFrom.needsCatalog) }
        return needs
    }
}

/// One entry in a meadow's `items`.
public enum MeadowEntry: Equatable, Sendable {
    /// A thing this Whiskr knows.
    case item(MeadowItem)
    /// A thing from a newer Whiskr, kept whole.
    case parcel(MeadowParcel)
}

/// A point on the ground, in units (1 unit ≈ 13 cm; the cat is 2.3 units tall). Height is never stored:
/// things stand on the land.
public struct MeadowPoint: Equatable, Sendable, Hashable {
    public var x: Double
    public var z: Double

    public init(_ x: Double, _ z: Double) {
        self.x = x
        self.z = z
    }

    /// Distance from the meadow's middle.
    public var reach: Double { hypot(x, z) }
}

/// A thing this Whiskr knows, placed.
public struct MeadowItem: Equatable, Sendable {
    /// Where it stands: one spot, or a run of points (`MeadowAsset.Shape`).
    public enum Placement: Equatable, Sendable {
        case at(MeadowPoint)
        case run([MeadowPoint])
    }

    /// The asset's current id (an old id read through an alias is written as its new one).
    public var asset: String
    public var placement: Placement
    /// Radians about up, in [0, 2π). Single things only.
    public var turn: Double
    /// Scale of x, y and z, each within the asset's range; nil is 1. Living and natural things only.
    public var size: [Double]?
    /// Lean about x and about z, radians, each within the asset's range; nil is upright.
    public var tilt: [Double]?
    /// The 32-bit seed it is grown from, for things grown from one (trees).
    public var seed: UInt32?
    /// Which of the asset's shapes; one this Whiskr does not have is kept and drawn as shape 0.
    public var variant: Int
    /// Options by name, as written: known ones checked and clamped, unknown ones kept as they were.
    public var params: [String: MeadowJSON]
    /// Fields from a newer Whiskr (or ones this asset does not take), kept as they were.
    public var unknownFields: [String: MeadowJSON]

    public init(asset: String, placement: Placement, turn: Double = 0, size: [Double]? = nil, tilt: [Double]? = nil,
                seed: UInt32? = nil, variant: Int = 0, params: [String: MeadowJSON] = [:], unknownFields: [String: MeadowJSON] = [:]) {
        self.asset = asset
        self.placement = placement
        self.turn = turn
        self.size = size
        self.tilt = tilt
        self.seed = seed
        self.variant = variant
        self.params = params
        self.unknownFields = unknownFields
    }

    /// Where it stands: its spot, or the first point of its run.
    public var at: MeadowPoint {
        switch placement {
        case .at(let point): point
        case .run(let points): points.first ?? MeadowPoint(0, 0)
        }
    }

    /// The shape to draw: its variant, or 0 for one this Whiskr does not have.
    public func drawnVariant(_ catalog: MeadowCatalog) -> Int {
        guard let asset = catalog.asset(asset), variant < asset.variants.count else { return 0 }
        return variant
    }

    /// A parameter's value to draw: as written when this Whiskr knows it, else the default.
    public func value(of name: String, _ catalog: MeadowCatalog) -> MeadowParameterValue? {
        guard let parameter = catalog.asset(asset)?.parameter(name) else { return nil }
        switch parameter.kind {
        case .integer(_, let fallback):
            return .integer(params[name]?.integer ?? fallback)
        case .choice(let choices):
            if let chosen = params[name]?.string, choices.contains(where: { $0.name == chosen }) { return .choice(chosen) }
            return .choice(choices[0].name)
        }
    }

    /// Whether anything on it is kept only because a newer Whiskr wrote it.
    public func hasNewerContent(_ catalog: MeadowCatalog) -> Bool {
        guard let asset = catalog.asset(asset) else { return true }
        if !unknownFields.isEmpty || variant >= asset.variants.count { return true }
        for (name, value) in params {
            guard let parameter = asset.parameter(name) else { return true }
            if case .choice(let choices) = parameter.kind, !choices.contains(where: { $0.name == value.string }) { return true }
        }
        return false
    }

    /// Moved by `dx`, `dz` (the editor checks the new spot is in the meadow).
    public mutating func move(by dx: Double, _ dz: Double) {
        switch placement {
        case .at(let point): placement = .at(MeadowPoint(point.x + dx, point.z + dz))
        case .run(let points): placement = .run(points.map { MeadowPoint($0.x + dx, $0.z + dz) })
        }
    }
}

/// A parameter's value, as drawn.
public enum MeadowParameterValue: Equatable, Sendable {
    case integer(Int)
    case choice(String)
}

/// A thing from a newer Whiskr: every field kept as it was read. In edit mode it shows as a parcel at
/// its spot, which can be moved or deleted but not otherwise changed.
public struct MeadowParcel: Equatable, Sendable {
    public var fields: [String: MeadowJSON]

    public init(fields: [String: MeadowJSON]) {
        self.fields = fields
    }

    /// Its asset id, as written.
    public var asset: String { fields["id"]?.string ?? "" }

    /// Where to show it: its `at`, or else the first of its `points`, when that is a point in the
    /// meadow; nil when it gives none this Whiskr can read (it is kept, and not shown).
    public var at: MeadowPoint? {
        if let point = Self.point(fields["at"]) { return point }
        return fields["points"]?.array?.first.flatMap(Self.point)
    }

    /// Moved by `dx`, `dz`: its `at` and each of its `points` that is a point this Whiskr can read;
    /// everything else stays as it was. (The editor keeps the spot in the meadow; a move that is not a
    /// distance on the meadow does nothing.)
    public mutating func move(by dx: Double, _ dz: Double) {
        guard dx.isFinite, dz.isFinite, abs(dx) <= 2 * MeadowFormat.reach, abs(dz) <= 2 * MeadowFormat.reach else { return }
        func moved(_ value: MeadowJSON) -> MeadowJSON {
            guard let point = Self.point(value) else { return value }
            return .array([.number(point.x + dx), .number(point.z + dz)])
        }
        if let at = fields["at"] { fields["at"] = moved(at) }
        if let points = fields["points"]?.array { fields["points"] = .array(points.map(moved)) }
    }

    private static func point(_ value: MeadowJSON?) -> MeadowPoint? {
        guard let pair = value?.array, pair.count == 2, let x = pair[0].double, let z = pair[1].double,
              x.isFinite, z.isFinite else { return nil }
        let point = MeadowPoint(x, z)
        return point.reach <= MeadowFormat.reach ? point : nil
    }
}
