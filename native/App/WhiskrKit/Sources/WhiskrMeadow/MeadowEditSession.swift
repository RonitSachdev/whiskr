import Foundation
import MeadowFile
import MeadowScene
import simd

// Editing a meadow (docs/DESIGN.md, "Edit Meadow"): its document, each thing known by an id that lasts as
// long as the editing does (whatever is added or taken away before it), what the scene draws of it, and every
// edit as a change that can be undone and done again. The editor's rules (`SceneryRules`) decide where a thing
// may stand; this applies them to what an edit moves, turns, sizes, copies or adds, and to nothing else.

/// One edit, as it can be undone: things taken away (where each stood in the meadow's order before),
/// things added (where each stands after), and things changed, by id.
public struct MeadowChange: Equatable, Sendable {
    public struct Placed: Equatable, Sendable {
        public var position: Int
        public var id: Int
        public var entry: MeadowEntry
    }

    public struct Edited: Equatable, Sendable {
        public var id: Int
        public var before: MeadowEntry
        public var after: MeadowEntry
    }

    /// In ascending order of where each stood before.
    public var removed: [Placed]
    /// In ascending order of where each stands after.
    public var added: [Placed]
    public var edited: [Edited]
    /// The painted ground's cells it changed (a stroke of the Ground tool).
    public var ground: MeadowGroundPatch?

    public init(removed: [Placed] = [], added: [Placed] = [], edited: [Edited] = [], ground: MeadowGroundPatch? = nil) {
        self.removed = removed
        self.added = added
        self.edited = edited
        self.ground = ground
    }

    public var isEmpty: Bool { removed.isEmpty && added.isEmpty && edited.isEmpty && ground == nil }

    /// What undoes it.
    public var inverse: MeadowChange {
        MeadowChange(removed: added, added: removed, edited: edited.map { Edited(id: $0.id, before: $0.after, after: $0.before) }, ground: ground?.inverse)
    }

    /// The things there after it that it added or changed: what to choose once it is done.
    public var touched: [Int] { added.map(\.id) + edited.map(\.id) }
}

/// Why an edit was not made. Each is said in the app's words.
public enum MeadowEditRefusal: Equatable, Sendable {
    /// Past the meadow's edge.
    case outsideMeadow
    /// A big thing on the picnic ground, kept for the workspaces.
    case keptForWorkspaces
    /// Too close to a thing of this kind (its asset id).
    case tooClose(to: String)
    /// The meadow holds as many of a kind as it can (nil: things in all), and how many that is.
    case full(MeadowCatalog.Cap?, limit: Int)
    /// No spot near enough where copies could stand.
    case noRoom
    /// As large, or as small, as a thing of this kind grows.
    case largest(String)
    case smallest(String)
    /// Made and found things keep their size; only living things grow.
    case keepsItsSize(String)
    /// The painted ground holds as much detail as a meadow file can (`MeadowDocument.groundRoom`).
    case groundFull
}

/// An edit refused, and which thing (by id) it was refused for, when it was one thing.
public struct MeadowEditRefused: Error, Equatable, Sendable {
    public var refusal: MeadowEditRefusal
    public var id: Int?

    public init(_ refusal: MeadowEditRefusal, id: Int? = nil) {
        self.refusal = refusal
        self.id = id
    }
}

public struct MeadowEditSession: Sendable {
    public let catalog: MeadowCatalog
    public internal(set) var document: MeadowDocument
    /// Each entry's id, in the document's order.
    public private(set) var ids: [Int]
    /// The id the next thing added takes.
    private(set) var nextID: Int
    /// What the scene draws: the things this Whiskr can draw, in the document's order, and while
    /// `showsParcels` each thing from a newer Whiskr that says where it stands, as a parcel.
    public internal(set) var scenery = MeadowScenery()
    /// Things from a newer Whiskr shown as parcels (`MeadowScenery.parcel`), to be moved or taken away: while
    /// the meadow is edited. Out of editing they are kept and not drawn.
    public var showsParcels = false {
        didSet { if showsParcels != oldValue { rebuild() } }
    }
    /// For each of the scenery's things, the id of the entry it draws.
    public private(set) var shown: [Int] = []
    private var drawnIndex: [Int: Int] = [:]
    private var positions: [Int: Int] = [:]

    public init(_ document: MeadowDocument, catalog: MeadowCatalog = .current) {
        self.catalog = catalog
        self.document = document
        ids = document.entries.indices.map { $0 + 1 }
        nextID = document.entries.count + 1
        rebuild()
        scenery.ground = MeadowScenery.Ground(document.ground, catalog: catalog)
    }

    /// The scenery's things, and the ids and positions behind them, from the document as it is now (the
    /// painted ground is kept as it is drawn: only a change of the ground changes it).
    private mutating func rebuild() {
        var things: [MeadowScenery.Thing] = []
        things.reserveCapacity(document.entries.count)
        shown = []
        drawnIndex = [:]
        positions = [:]
        for (position, entry) in document.entries.enumerated() {
            let id = ids[position]
            positions[id] = position
            guard let thing = thing(entry) else { continue }
            drawnIndex[id] = things.count
            shown.append(id)
            things.append(thing)
        }
        scenery.things = things
    }

    /// The scene's form of an entry, when it is one drawn: a thing the scene draws, or, while parcels are
    /// shown, a thing it cannot draw (from a newer Whiskr, or of the catalog with no model yet) as a parcel
    /// where it stands, turned as it says.
    func thing(_ entry: MeadowEntry) -> MeadowScenery.Thing? {
        switch entry {
        case .item(let item):
            if let thing = Self.thing(item, catalog) { return thing }
            guard showsParcels else { return nil }
            return MeadowScenery.Thing(id: MeadowScenery.parcel, x: Float(item.at.x), z: Float(item.at.z), turn: Float(item.turn))
        case .parcel(let parcel):
            guard showsParcels, let at = parcel.at else { return nil }
            let turn = parcel.fields["turn"]?.double.flatMap { $0.isFinite ? $0 : nil } ?? 0
            return MeadowScenery.Thing(id: MeadowScenery.parcel, x: Float(at.x), z: Float(at.z), turn: Float(Self.normalTurn(turn)))
        }
    }

    /// The things the scene cannot draw: from a newer Whiskr, or of the catalog with no model yet (kept, and
    /// shown as parcels while editing). What "6 things can't be shown here" counts.
    public var undrawnCount: Int {
        document.entries.reduce(0) { count, entry in
            if case .item(let item) = entry, Self.thing(item, catalog) != nil { return count }
            return count + 1
        }
    }

    /// Whether `id` is shown as a parcel while editing: it can be moved or taken away, and nothing more.
    public func isParcel(_ id: Int) -> Bool {
        guard let position = positions[id] else { return false }
        if case .item(let item) = document.entries[position] { return Self.thing(item, catalog) == nil }
        return true
    }

    /// The scene's form of an item, when it is one the scene draws (at a spot, of an id it has a builder for).
    static func thing(_ item: MeadowFile.MeadowItem, _ catalog: MeadowCatalog) -> MeadowScenery.Thing? {
        MeadowScenery.Thing(item, catalog)
    }

    // MARK: Looking things up

    /// The id of the scenery's thing at `index`.
    public func id(ofThing index: Int) -> Int? { shown.indices.contains(index) ? shown[index] : nil }
    /// Where a thing is in the scenery (nil: not drawn).
    public func thingIndex(of id: Int) -> Int? { drawnIndex[id] }
    /// A thing this Whiskr knows, by id.
    public func item(_ id: Int) -> MeadowFile.MeadowItem? {
        guard let position = positions[id], case .item(let item) = document.entries[position] else { return nil }
        return item
    }
    /// A thing from a newer Whiskr, by id.
    public func parcel(_ id: Int) -> MeadowParcel? {
        guard let position = positions[id], case .parcel(let parcel) = document.entries[position] else { return nil }
        return parcel
    }
    /// Where a thing stands, by id, whatever it is (one from a newer Whiskr: where it says, when it says).
    public func spot(_ id: Int) -> MeadowPoint? {
        guard let position = positions[id] else { return nil }
        switch document.entries[position] {
        case .item(let item): return item.at
        case .parcel(let parcel): return parcel.at
        }
    }
    /// Every thing drawn, by id, in order.
    public var drawnIDs: [Int] { shown }

    /// The things of the same kind as `id` standing within `within` units of it (itself among them).
    public func ids(like id: Int, within: Double) -> [Int] {
        guard let item = item(id) else { return [] }
        return shown.filter { other in
            guard let o = self.item(other), o.asset == item.asset else { return false }
            return hypot(o.at.x - item.at.x, o.at.z - item.at.z) <= within
        }
    }

    /// The things drawn, nearest to a spot first (ties in the meadow's order).
    public func idsByDistance(from spot: SIMD2<Double>) -> [Int] {
        func distance(_ id: Int) -> Double {
            guard let at = item(id)?.at else { return .infinity }
            return hypot(at.x - spot.x, at.z - spot.y)
        }
        let measured: [(order: Int, id: Int, distance: Double)] = shown.enumerated().map { ($0.offset, $0.element, distance($0.element)) }
        return measured.sorted { $0.distance != $1.distance ? $0.distance < $1.distance : $0.order < $1.order }.map(\.id)
    }

    /// The middle of some things' spots.
    public func middle(of ids: some Collection<Int>) -> SIMD2<Double>? {
        let spots = ids.compactMap { item($0)?.at }
        guard !spots.isEmpty else { return nil }
        return SIMD2(spots.map(\.x).reduce(0, +), spots.map(\.z).reduce(0, +)) / Double(spots.count)
    }

    // MARK: Changing

    /// Makes `change` (one made here, or the inverse of one): things away, things in, things changed, the
    /// ground painted.
    public mutating func apply(_ change: MeadowChange) {
        if let patch = change.ground { apply(patch) }
        guard !change.removed.isEmpty || !change.added.isEmpty || !change.edited.isEmpty else { return }
        // Only things after the rest (a placing, a Brush's dab): those alone are added to what is drawn.
        if change.removed.isEmpty, change.edited.isEmpty, !change.added.isEmpty,
           change.added.enumerated().allSatisfy({ $0.element.position == document.entries.count + $0.offset }) {
            for placed in change.added { append(placed) }
            return
        }
        for placed in change.removed.sorted(by: { $0.position > $1.position }) where ids.indices.contains(placed.position) {
            document.entries.remove(at: placed.position)
            ids.remove(at: placed.position)
        }
        for placed in change.added.sorted(by: { $0.position < $1.position }) {
            let at = min(placed.position, document.entries.count)
            document.entries.insert(placed.entry, at: at)
            ids.insert(placed.id, at: at)
            nextID = max(nextID, placed.id + 1)
        }
        var where_: [Int: Int] = [:]
        for (position, id) in ids.enumerated() { where_[id] = position }
        for edited in change.edited {
            if let position = where_[edited.id] { document.entries[position] = edited.after }
        }
        rebuild()
    }

    /// One thing at the end of the meadow, and in the scenery when it is drawn.
    private mutating func append(_ placed: MeadowChange.Placed) {
        let position = document.entries.count
        document.entries.append(placed.entry)
        ids.append(placed.id)
        positions[placed.id] = position
        nextID = max(nextID, placed.id + 1)
        guard let thing = thing(placed.entry) else { return }
        drawnIndex[placed.id] = scenery.things.count
        shown.append(placed.id)
        scenery.things.append(thing)
    }

    /// Gives the meadow a name (the first edit of the Default makes "My Meadow").
    public mutating func rename(_ name: String) {
        document.name = name
    }

    /// The meadow's things as the scene draws them with `ids` moved by `offset` (a drag under way): the
    /// document is not changed.
    public func scenery(moving ids: Set<Int>, by offset: SIMD2<Float>) -> MeadowScenery {
        var moved = scenery
        for id in ids {
            guard let i = drawnIndex[id] else { continue }
            moved.things[i].move(by: offset)
        }
        return moved
    }

    /// What a drag of `ids` is judged against, made once for the drag: every other thing, and what each
    /// moved thing was too close to already where it stood.
    public struct MoveCheck: Sendable {
        let field: SceneryRules.Field
        let moved: [(id: Int, thing: MeadowScenery.Thing, excused: Set<Int>, onPicnic: Bool)]
    }

    public func moveCheck(_ ids: Set<Int>) -> MoveCheck {
        let leaving = Set(ids.compactMap { drawnIndex[$0] })
        let field = SceneryRules.Field(scenery, leavingOut: leaving)
        let moved = ids.sorted().compactMap { id -> (Int, MeadowScenery.Thing, Set<Int>, Bool)? in
            guard let i = drawnIndex[id] else { return nil }
            let thing = scenery.things[i]
            return (id, thing, field.overlapping(thing), SceneryRules.isOnPicnicGround(thing))
        }
        return MoveCheck(field: field, moved: moved)
    }

    /// Why each of the moved things may not stand where `offset` would put it, by id (empty: all may).
    public func refusals(_ check: MoveCheck, by offset: SIMD2<Float>) -> [Int: MeadowEditRefusal] {
        var found: [Int: MeadowEditRefusal] = [:]
        for moved in check.moved {
            var thing = moved.thing
            thing.move(by: offset)
            if let refusal = check.field.refusal(for: thing, excusing: moved.excused, wasOnPicnicGround: moved.onPicnic) {
                found[moved.id] = said(refusal)
            }
        }
        return found
    }

    /// A refusal in the session's terms (the thing in the way named by its kind).
    public func said(_ refusal: SceneryRules.Refusal) -> MeadowEditRefusal {
        switch refusal {
        case .outsideMeadow: .outsideMeadow
        case .keptForWorkspaces: .keptForWorkspaces
        case .tooClose(let index): .tooClose(to: scenery.things.indices.contains(index) ? scenery.things[index].id : "")
        }
    }

    /// Moves `ids` by `offset` (a drag let go, an arrow key), keeping the group's shape, when each may stand
    /// there; else nothing changes and the first thing refused says why. Things from a newer Whiskr move too.
    public mutating func move(_ ids: Set<Int>, by offset: SIMD2<Double>) -> Result<MeadowChange, MeadowEditRefused> {
        edit(ids, parcels: { $0.move(by: offset.x, offset.y) }) { item, _ in item.move(by: offset.x, offset.y) }
    }

    /// Turns `ids` by `radians` about up (positive turns counter-clockwise, seen from above): one thing about
    /// its own middle, several about the middle of the group, which keeps its shape. A run (a fence) is turned by
    /// its points, alone about their middle; it has no turn of its own.
    public mutating func turn(_ ids: Set<Int>, by radians: Double) -> Result<MeadowChange, MeadowEditRefused> {
        let middle = ids.count > 1 ? self.middle(of: ids) : nil
        let c = cos(radians), s = sin(radians)
        // As the scene turns things about up: x' = x cos + z sin, z' = −x sin + z cos.
        func turned(_ p: MeadowPoint, about m: SIMD2<Double>) -> MeadowPoint {
            let dx = p.x - m.x, dz = p.z - m.y
            return MeadowPoint(m.x + dx * c + dz * s, m.y - dx * s + dz * c)
        }
        return edit(ids) { item, _ in
            switch item.placement {
            case .at(let at):
                item.turn = Self.normalTurn(item.turn + radians)
                if let middle { item.placement = .at(turned(at, about: middle)) }
            case .run(let points):
                let about = middle ?? Self.middle(of: points)
                item.placement = .run(points.map { turned($0, about: about) })
            }
        }
    }

    /// The middle of a run's points (its first point not counted twice when it closes on itself).
    static func middle(of points: [MeadowPoint]) -> SIMD2<Double> {
        let closes = points.count > 2 && points.first == points.last
        let counted = closes ? Array(points.dropLast()) : points
        guard !counted.isEmpty else { return .zero }
        return SIMD2(counted.map(\.x).reduce(0, +), counted.map(\.z).reduce(0, +)) / Double(counted.count)
    }

    /// Grows or shrinks `ids` by `factor` on every axis (living things only, within what their kind grows to).
    public mutating func resize(_ ids: Set<Int>, by factor: Double) -> Result<MeadowChange, MeadowEditRefused> {
        for id in ids.sorted() {
            guard let item = item(id), let asset = catalog.asset(item.asset) else { continue }
            guard asset.nature == .living, let range = asset.size else { return .failure(MeadowEditRefused(.keepsItsSize(item.asset), id: id)) }
            let size = (item.size ?? [1, 1, 1]).map { $0 * factor }
            if size.contains(where: { $0 > range.upperBound + 1e-9 }) { return .failure(MeadowEditRefused(.largest(item.asset), id: id)) }
            if size.contains(where: { $0 < range.lowerBound - 1e-9 }) { return .failure(MeadowEditRefused(.smallest(item.asset), id: id)) }
        }
        return edit(ids) { item, _ in
            let size = (item.size ?? [1, 1, 1]).map { MeadowJSON.quantized($0 * factor) }
            item.size = size.allSatisfy { $0 == 1 } ? nil : size
        }
    }

    /// Whether a thing grows (and so may be sized).
    public func grows(_ id: Int) -> Bool {
        item(id).flatMap { catalog.asset($0.asset) }.map { $0.nature == .living && $0.size != nil } ?? false
    }

    /// Takes `ids` away.
    public mutating func delete(_ ids: Set<Int>) -> MeadowChange {
        let removed = document.entries.indices.filter { ids.contains(self.ids[$0]) }.map {
            MeadowChange.Placed(position: $0, id: self.ids[$0], entry: document.entries[$0])
        }
        let change = MeadowChange(removed: removed)
        if !change.isEmpty { apply(change) }
        return change
    }

    /// Copies of `ids` beside them (`toward`: which way to look first, a step of about two units), at the
    /// nearest spot where each may stand; the copies are the same things (a tree the same tree).
    public mutating func duplicate(_ ids: Set<Int>, toward: SIMD2<Double>) -> Result<MeadowChange, MeadowEditRefused> {
        let items = document.entries.indices.compactMap { position -> MeadowFile.MeadowItem? in
            guard ids.contains(self.ids[position]), case .item(let item) = document.entries[position] else { return nil }
            return item
        }
        let step = simd_length(toward) > 0 ? simd_normalize(toward) * 2 : SIMD2(2, 2) / 2.squareRoot()
        return add(items, offset: step)
    }

    /// Things put down near `spot` (pasted), each the same as it was, at the nearest spot round there where
    /// each may stand; their middle goes to `spot` when it can.
    public mutating func add(_ items: [MeadowFile.MeadowItem], around spot: SIMD2<Double>) -> Result<MeadowChange, MeadowEditRefused> {
        let middle = Self.middle(of: items)
        return add(items, offset: spot - middle)
    }

    /// Copies of `ids` moved by exactly `offset` (an ⌥-drag let go), when each may stand there; else nothing
    /// is added and the first refused says why.
    public mutating func duplicate(_ ids: Set<Int>, movedBy offset: SIMD2<Double>) -> Result<MeadowChange, MeadowEditRefused> {
        let items = document.entries.indices.compactMap { position -> MeadowFile.MeadowItem? in
            guard ids.contains(self.ids[position]), case .item(let item) = document.entries[position] else { return nil }
            return item
        }
        return add(items, offset: offset, searching: false)
    }

    /// Why copies of `ids` moved by `offset` could not stand there, by the id each was copied from (an ⌥-drag
    /// under way); every thing in the meadow counts, the originals too.
    public func copyRefusals(_ ids: Set<Int>, by offset: SIMD2<Float>, field: SceneryRules.Field) -> [Int: MeadowEditRefusal] {
        var found: [Int: MeadowEditRefusal] = [:]
        for id in ids {
            guard let i = drawnIndex[id] else { continue }
            var thing = scenery.things[i]
            thing.move(by: offset)
            if let refusal = field.refusal(for: thing) { found[id] = said(refusal) }
        }
        return found
    }

    /// The scenery with copies of `ids` moved by `offset` drawn after the rest (an ⌥-drag under way), and
    /// where the copies are in it.
    public func scenery(copying ids: Set<Int>, by offset: SIMD2<Float>) -> (scenery: MeadowScenery, copies: [Int]) {
        var withCopies = scenery
        var copies: [Int] = []
        for id in shown where ids.contains(id) {
            guard let i = drawnIndex[id] else { continue }
            var thing = scenery.things[i]
            thing.move(by: offset)
            copies.append(withCopies.things.count)
            withCopies.things.append(thing)
        }
        return (withCopies, copies)
    }

    /// Living things drawn again (the selection's Shuffle): a new turn, lean and size within what their kind
    /// is usually given, and for a tree a new seed, so it grows anew. Made and found things are left as they are.
    public mutating func shuffle(_ ids: Set<Int>, using random: inout some RandomNumberGenerator) -> Result<MeadowChange, MeadowEditRefused> {
        var draws: [Int: (turn: Double, size: [Double]?, tilt: [Double]?, seed: UInt32?)] = [:]
        for id in ids.sorted() {
            guard let item = item(id), let asset = catalog.asset(item.asset), asset.nature == .living else { continue }
            let usual = Self.usualSize(asset)
            let base = Double.random(in: usual, using: &random)
            let size = asset.size.map { range in
                [base * .random(in: 0.92...1.08, using: &random), base * .random(in: 0.88...1.12, using: &random), base * .random(in: 0.92...1.08, using: &random)]
                    .map { min(max($0, range.lowerBound), range.upperBound) }
            }
            let tilt = asset.tilt.map { lean in [Double.random(in: -lean...lean, using: &random) * 0.8, Double.random(in: -lean...lean, using: &random) * 0.8] }
            draws[id] = (.random(in: 0..<(2 * .pi), using: &random), size, tilt, asset.seeded ? random.next() : nil)
        }
        return edit(Set(draws.keys)) { item, id in
            guard let draw = draws[id] else { return }
            item.turn = Self.normalTurn(draw.turn)
            item.size = draw.size.map { $0.map(MeadowJSON.quantized) }.flatMap { $0.allSatisfy { $0 == 1 } ? nil : $0 }
            item.tilt = draw.tilt.map { $0.map(MeadowJSON.quantized) }.flatMap { $0.allSatisfy { $0 == 0 } ? nil : $0 }
            if let seed = draw.seed { item.seed = seed }
        }
    }

    /// The sizes a new living thing of a kind is given (narrower than what a file may hold, which keeps the
    /// Default's own): trees 0.8–1.2, young trees 0.85–1.25, flowers and plants 0.85–1.15, mushrooms 0.7–1.3.
    static func usualSize(_ asset: MeadowAsset) -> ClosedRange<Double> {
        switch asset.id {
        case "tree.young": 0.85...1.25
        case "fungus.flyAgaric": 0.7...1.3
        default: asset.category == .trees ? 0.8...1.2 : 0.85...1.15
        }
    }

    /// `items` moved by `offset`, or by the nearest offset round it where every one may stand (`searching`),
    /// added at the end of the meadow.
    mutating func add(_ items: [MeadowFile.MeadowItem], offset: SIMD2<Double>, searching: Bool = true) -> Result<MeadowChange, MeadowEditRefused> {
        guard !items.isEmpty else { return .success(MeadowChange()) }
        if let full = capacity(for: items) { return .failure(MeadowEditRefused(full)) }
        let field = SceneryRules.Field(scenery)
        func fits(_ d: SIMD2<Double>) -> Bool {
            for item in items {
                var moved = item
                moved.move(by: d.x, d.y)
                if case .run(let points) = moved.placement, points.contains(where: { $0.reach > MeadowFormat.reach }) { return false }
                if moved.at.reach > MeadowFormat.reach { return false }
                if let thing = Self.thing(moved, catalog), field.refusal(for: thing) != nil { return false }
            }
            return true
        }
        // Rings round the first choice, nearer first, a few directions each.
        var found: SIMD2<Double>? = fits(offset) ? offset : nil
        var ring = 0.75
        if !searching, found == nil {
            for item in items {
                var moved = item
                moved.move(by: offset.x, offset.y)
                if let thing = Self.thing(moved, catalog), let refusal = field.refusal(for: thing) { return .failure(MeadowEditRefused(said(refusal))) }
            }
            return .failure(MeadowEditRefused(.outsideMeadow))
        }
        while found == nil, ring <= 30 {
            let around = max(8, Int((2 * .pi * ring / 1.2).rounded()))
            for k in 0..<around {
                let a = Double(k) / Double(around) * 2 * .pi
                let d = offset + SIMD2(cos(a), sin(a)) * ring
                if fits(d) { found = d; break }
            }
            ring += 0.75
        }
        guard let d = found else { return .failure(MeadowEditRefused(.noRoom)) }
        let start = document.entries.count
        let added = items.enumerated().map { k, item -> MeadowChange.Placed in
            var copy = item
            copy.move(by: d.x, d.y)
            copy.placement = Self.quantized(copy.placement)
            return MeadowChange.Placed(position: start + k, id: nextID + k, entry: .item(copy))
        }
        let change = MeadowChange(added: added)
        apply(change)
        return .success(change)
    }

    /// Why the meadow cannot take `items` as well (nil: it can): a cap of their kinds, or things in all.
    public func capacity(for items: [MeadowFile.MeadowItem]) -> MeadowEditRefusal? {
        if document.entries.count + items.count > MeadowFormat.maxItems { return .full(nil, limit: MeadowFormat.maxItems) }
        var counts = document.counts(catalog)
        for (cap, n) in MeadowDocument(entries: items.map { .item($0) }).counts(catalog) { counts[cap, default: 0] += n }
        for cap in MeadowCatalog.Cap.allCases where counts[cap, default: 0] > cap.limit { return .full(cap, limit: cap.limit) }
        return nil
    }

    /// Changes `ids` with `change` (and the things from a newer Whiskr among them with `parcels`, when given)
    /// when each may stand where it ends up; refused, nothing changes.
    mutating func edit(_ ids: Set<Int>, parcels: ((inout MeadowParcel) -> Void)? = nil,
                       _ change: (inout MeadowFile.MeadowItem, Int) -> Void) -> Result<MeadowChange, MeadowEditRefused> {
        let leaving = Set(ids.compactMap { drawnIndex[$0] })
        let field = SceneryRules.Field(scenery, leavingOut: leaving)
        var edited: [MeadowChange.Edited] = []
        for (position, id) in self.ids.enumerated() where ids.contains(id) {
            if case .parcel(let before) = document.entries[position], let parcels {
                var after = before
                parcels(&after)
                guard after != before else { continue }
                // It stays where this Whiskr can read its spot: in the meadow.
                guard after.at != nil else { return .failure(MeadowEditRefused(.outsideMeadow, id: id)) }
                if let old = thing(.parcel(before)), let new = thing(.parcel(after)),
                   let refusal = field.refusal(for: new, excusing: field.overlapping(old), wasOnPicnicGround: SceneryRules.isOnPicnicGround(old)) {
                    return .failure(MeadowEditRefused(said(refusal), id: id))
                }
                edited.append(MeadowChange.Edited(id: id, before: .parcel(before), after: .parcel(after)))
                continue
            }
            guard case .item(let before) = document.entries[position] else { continue }
            var after = before
            change(&after, id)
            after.placement = Self.quantized(after.placement)
            guard after != before else { continue }
            if case .run(let points) = after.placement, points.contains(where: { $0.reach > MeadowFormat.reach }) {
                return .failure(MeadowEditRefused(.outsideMeadow, id: id))
            }
            if let old = thing(.item(before)), let new = thing(.item(after)),
               let refusal = field.refusal(for: new, excusing: field.overlapping(old), wasOnPicnicGround: SceneryRules.isOnPicnicGround(old)) {
                return .failure(MeadowEditRefused(said(refusal), id: id))
            } else if after.at.reach > MeadowFormat.reach {
                return .failure(MeadowEditRefused(.outsideMeadow, id: id))
            }
            edited.append(MeadowChange.Edited(id: id, before: .item(before), after: .item(after)))
        }
        let made = MeadowChange(edited: edited)
        if !made.isEmpty { apply(made) }
        return .success(made)
    }

    // MARK: Copying

    /// The pasteboard's type for things copied from a meadow: a meadow file of just them, round their middle.
    public static let pasteboardType = "app.whiskr.meadow-items"

    /// `ids` as the pasteboard holds them: a meadow file of copies round their middle, data only, read
    /// back with every check a meadow file from anyone gets.
    public func copied(_ ids: Set<Int>, writtenBy version: String) -> Data? {
        let items = document.entries.indices.compactMap { position -> MeadowFile.MeadowItem? in
            guard ids.contains(self.ids[position]), case .item(let item) = document.entries[position] else { return nil }
            return item
        }
        guard !items.isEmpty else { return nil }
        let middle = Self.middle(of: items)
        let around = items.map { item -> MeadowEntry in
            var copy = item
            copy.move(by: -middle.x, -middle.y)
            copy.placement = Self.quantized(copy.placement)
            return .item(copy)
        }
        return try? MeadowDocument(entries: around).fileData(writtenBy: version, catalog: catalog)
    }

    /// The things in pasteboard data (`copied`), round (0, 0); nil when it is not something copied from a meadow.
    public static func pasted(_ data: Data, catalog: MeadowCatalog = .current) -> [MeadowFile.MeadowItem]? {
        guard let reading = try? MeadowDocument.read(data, catalog: catalog) else { return nil }
        let items = reading.document.items
        return items.isEmpty ? nil : items
    }

    // MARK: Numbers as a file holds them

    private static func middle(of items: [MeadowFile.MeadowItem]) -> SIMD2<Double> {
        guard !items.isEmpty else { return .zero }
        return SIMD2(items.map(\.at.x).reduce(0, +), items.map(\.at.z).reduce(0, +)) / Double(items.count)
    }

    /// A turn in [0, 2π), rounded as a file rounds it.
    public static func normalTurn(_ radians: Double) -> Double {
        var t = radians.truncatingRemainder(dividingBy: 2 * .pi)
        if t < 0 { t += 2 * .pi }
        let q = MeadowJSON.quantized(t)
        return q >= MeadowJSON.quantized(2 * .pi) ? 0 : q
    }

    /// Points rounded as a file rounds them, so what is edited is what is saved and read back.
    static func quantized(_ placement: MeadowFile.MeadowItem.Placement) -> MeadowFile.MeadowItem.Placement {
        switch placement {
        case .at(let p): .at(MeadowPoint(MeadowJSON.quantized(p.x), MeadowJSON.quantized(p.z)))
        case .run(let points): .run(points.map { MeadowPoint(MeadowJSON.quantized($0.x), MeadowJSON.quantized($0.z)) })
        }
    }
}
