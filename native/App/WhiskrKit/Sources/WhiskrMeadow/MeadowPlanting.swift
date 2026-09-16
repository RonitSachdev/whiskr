import Foundation
import MeadowFile
import MeadowScene
import simd

// Putting new things into a meadow (docs/DESIGN.md, "Edit Meadow"): a thing placed from the tray, plants
// painted with the Brush, and things swept away with the Eraser. A new thing is drawn as it would grow, never
// stamped: its own turn, size and lean within what its kind is given, a tree its own seed. The Brush lays
// clumps of one kind, thicker toward their middle, never an even sprinkle, each plant clear of every other
// thing with grass between, as anything moved must be.

/// What the Brush paints and how: one kind of plant or a mix, how wide, and how thickly.
public struct MeadowBrush: Equatable, Sendable {
    /// How thickly each dab plants.
    public enum Density: String, CaseIterable, Sendable {
        case sparse, natural, dense

        /// Plants in a dab of the usual size: a clump of five to twelve, as the meadow's own grow.
        var plants: ClosedRange<Int> {
            switch self {
            case .sparse: 3...6
            case .natural: 5...12
            case .dense: 9...18
            }
        }
    }

    /// One kind it paints, and how often among the others.
    public struct Kind: Equatable, Sendable {
        public var asset: String
        public var weight: Double

        public init(_ asset: String, _ weight: Double = 1) {
            self.asset = asset
            self.weight = weight
        }
    }

    public var kinds: [Kind]
    /// The circle's radius, in units (`radii`).
    public var radius: Double
    public var density: Density

    public init(_ kinds: [Kind], radius: Double = MeadowBrush.usualRadius, density: Density = .natural) {
        self.kinds = kinds
        self.radius = min(max(radius, Self.radii.lowerBound), Self.radii.upperBound)
        self.density = density
    }

    /// How wide the circle can be, and how wide it starts.
    public static let radii: ClosedRange<Double> = 2...12
    public static let usualRadius = 4.0

    /// The meadow's own wildflowers in the shares it grows them: daisies, buttercups, lupins and poppies.
    public static let wildflowers: [Kind] = [Kind("flower.daisy", 0.4), Kind("flower.buttercup", 0.3), Kind("flower.lupin", 0.17), Kind("flower.poppy", 0.13)]

    /// Whether the Brush paints this asset: a living thing of the flowers' shelf (flowers, plants, mushrooms)
    /// that stands at one spot. Trees, stones, wood and made things are placed one by one.
    public static func paints(_ asset: MeadowAsset) -> Bool {
        asset.category == .flowers && asset.nature == .living && asset.shape == .single
    }

    /// One kind, by its share.
    func pick(using random: inout some RandomNumberGenerator) -> String? {
        let total = kinds.reduce(0) { $0 + max($1.weight, 0) }
        guard total > 0 else { return kinds.first?.asset }
        var roll = Double.random(in: 0..<total, using: &random)
        for kind in kinds {
            roll -= max(kind.weight, 0)
            if roll < 0 { return kind.asset }
        }
        return kinds.last?.asset
    }
}

extension MeadowEditSession {
    // MARK: A new thing

    /// A new thing of `asset` at `spot`, turned `turn`, as a person placing it finds it: a living thing with
    /// a size and lean of its own within what its kind is usually given, one of its kind's shapes and, for a
    /// tree, a seed of its own (so no two oaks are alike); a stone a size of its own; the log as it is. Nil for
    /// an asset this meadow cannot draw.
    public func fresh(_ asset: String, at spot: SIMD2<Double>, turn: Double, using random: inout some RandomNumberGenerator) -> MeadowFile.MeadowItem? {
        guard let kind = catalog.asset(asset), kind.shape == .single, MeadowScenery.draws(kind.id) else { return nil }
        var item = MeadowFile.MeadowItem(asset: kind.id, placement: Self.quantized(.at(MeadowPoint(spot.x, spot.y))), turn: Self.normalTurn(turn))
        if let range = kind.size {
            let usual = kind.nature == .living ? Self.usualSize(kind) : 0.75...1.25
            let base = Double.random(in: usual, using: &random)
            let size = [base * .random(in: 0.92...1.08, using: &random), base * .random(in: 0.88...1.12, using: &random), base * .random(in: 0.92...1.08, using: &random)]
                .map { MeadowJSON.quantized(min(max($0, range.lowerBound), range.upperBound)) }
            item.size = size.allSatisfy { $0 == 1 } ? nil : size
        }
        if let lean = kind.tilt {
            let tilt = [Double.random(in: -lean...lean, using: &random) * 0.8, Double.random(in: -lean...lean, using: &random) * 0.8].map(MeadowJSON.quantized)
            item.tilt = tilt.allSatisfy { $0 == 0 } ? nil : tilt
        }
        if kind.seeded { item.seed = random.next() }
        if kind.variants.count > 1 { item.variant = Int.random(in: 0..<kind.variants.count, using: &random) }
        return item
    }

    /// The scene's form of a thing not yet in the meadow (the ghost of one about to be placed).
    public func thing(_ item: MeadowFile.MeadowItem) -> MeadowScenery.Thing? { Self.thing(item, catalog) }

    /// What a thing about to be placed is judged against: everything in the meadow now.
    public var placingField: SceneryRules.Field { SceneryRules.Field(scenery) }

    /// Why `item` may not be placed where it is (nil: it may): a cap reached, or a rule of where things stand.
    public func placingRefusal(_ item: MeadowFile.MeadowItem, field: SceneryRules.Field) -> MeadowEditRefusal? {
        if let full = capacity(for: [item]) { return full }
        if item.at.reach > MeadowFormat.reach { return .outsideMeadow }
        guard let thing = thing(item) else { return nil }
        return field.refusal(for: thing).map(said)
    }

    /// Places `item` exactly where it is, when it may stand there; else nothing changes and the reason is given.
    public mutating func place(_ item: MeadowFile.MeadowItem) -> Result<MeadowChange, MeadowEditRefused> {
        if let full = capacity(for: [item]) { return .failure(MeadowEditRefused(full)) }
        return add([item], offset: .zero, searching: false)
    }

    // MARK: The Brush

    /// One dab of `brush` at `spot`: a clump of one of its kinds (chosen by share), scattered round the spot
    /// thicker toward its middle, each plant turned, sized and leant its own way. A plant goes only where it
    /// may stand (`field`, which each one joins so the next keeps clear of it), and none past the meadow's
    /// caps: `full` says which was reached. `adding` counts the things a stroke has added before this dab.
    public func dab(_ brush: MeadowBrush, at spot: SIMD2<Double>, field: inout SceneryRules.Field, adding: Int,
                    using random: inout some RandomNumberGenerator) -> (items: [MeadowFile.MeadowItem], full: MeadowEditRefusal?) {
        guard let asset = brush.pick(using: &random) else { return ([], nil) }
        let usual = brush.density.plants
        let count = max(1, Int((Double(Int.random(in: usual, using: &random)) * min(max(brush.radius / MeadowBrush.usualRadius, 0.6), 3)).rounded()))
        var items: [MeadowFile.MeadowItem] = []
        for _ in 0..<count {
            let room = MeadowFormat.maxItems - document.entries.count - adding - items.count
            guard room > 0 else { return (items, .full(nil, limit: MeadowFormat.maxItems)) }
            // A few tries for each, nearer the middle more often: a clump thins toward its edge.
            for _ in 0..<3 {
                let out = brush.radius * Double.random(in: 0...1, using: &random), angle = Double.random(in: 0..<(2 * .pi), using: &random)
                let at = spot + SIMD2(cos(angle), sin(angle)) * out
                guard hypot(at.x, at.y) <= MeadowFormat.reach,
                      let item = fresh(asset, at: at, turn: .random(in: 0..<(2 * .pi), using: &random), using: &random),
                      let thing = thing(item), field.refusal(for: thing) == nil else { continue }
                field.add(thing)
                items.append(item)
                break
            }
        }
        return (items, nil)
    }

    /// `items` at the end of the meadow, as they are, in order: a stroke's dab. One change.
    public mutating func append(_ items: [MeadowFile.MeadowItem]) -> MeadowChange {
        let start = document.entries.count
        let change = MeadowChange(added: items.enumerated().map { k, item in
            MeadowChange.Placed(position: start + k, id: nextID + k, entry: .item(item))
        })
        if !change.isEmpty { apply(change) }
        return change
    }

    // MARK: Stepping stones

    /// The stepping stones' id, laid in a row along a drag rather than one by one.
    public static let steppingStone = "stone.stepping"
    /// How far apart stepping stones are laid along a drag, middle to middle, in units: a cat's easy stride,
    /// a strip of grass between each two, as a garden's are laid a person's stride apart.
    public static let steppingStride = 1.1

    /// A stepping stone laid at `spot` on a path heading along `heading`, as a person sets one: across the way
    /// (its long side square to the path, give or take a little), a hair off the line, a found stone's own
    /// size, a little wider than deep so the path reads as slabs a stride apart and not as a strip.
    public func steppingStone(at spot: SIMD2<Double>, heading: SIMD2<Double>, using random: inout some RandomNumberGenerator) -> MeadowFile.MeadowItem? {
        guard let kind = catalog.asset(Self.steppingStone), let range = kind.size, simd_length(heading) > 0 else { return nil }
        let along = simd_normalize(heading), across = SIMD2(-along.y, along.x)
        let at = spot + across * Double.random(in: -0.1...0.1, using: &random) + along * Double.random(in: -0.03...0.03, using: &random)
        // The stone's long side is its own x, which a turn t lays along (cos t, −sin t).
        let turn = atan2(-across.y, across.x) + Double.random(in: -0.3...0.3, using: &random)
        guard var item = fresh(Self.steppingStone, at: at, turn: turn, using: &random) else { return nil }
        let size = [Double.random(in: 0.92...1.15, using: &random), .random(in: 0.9...1.1, using: &random), .random(in: 0.82...0.95, using: &random)]
            .map { MeadowJSON.quantized(min(max($0, range.lowerBound), range.upperBound)) }
        item.size = size
        return item
    }

    // MARK: The Eraser

    /// What one sweep of the Eraser at `spot` takes: the plants, mushrooms and stones standing within `radius`
    /// of it (of `kind` only, when one is given). Trees, young trees and the log are never swept away: only a
    /// click takes one, so none is lost by a stroke passing it. Things kept from a newer Whiskr are never taken.
    public func swept(at spot: SIMD2<Double>, radius: Double, kind: String?) -> [Int] {
        shown.filter { id in
            guard let item = item(id), !SceneryRules.isBig(item.asset), kind == nil || item.asset == kind else { return false }
            return hypot(item.at.x - spot.x, item.at.z - spot.y) <= radius
        }
    }
}
