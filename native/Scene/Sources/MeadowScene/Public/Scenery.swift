import Foundation
import simd

/// The scenery a meadow holds (trees, flowers, mushrooms, stones, the log, stepping stones, the painted
/// ground, and later whatever a person places), as plain values: what a meadow file's `items` and `ground`
/// say, in the scene's own terms. Give it to
/// `MeadowView.scenery`; the meadow draws exactly this. The sky, hills, clouds, grass, weather, blankets,
/// cats and everything on and between the blankets are not scenery.
///
/// Every thing stands on the land (height is never given) and is drawn rooted: it makes way where a
/// blanket is laid and goes down with the land where that is levelled for one.
public struct MeadowScenery: Equatable, Sendable {
    /// One placed thing.
    public struct Thing: Equatable, Sendable {
        /// The catalog's id (`tree.oak`, `flower.daisy`). One the scene cannot draw (`MeadowScenery.draws`)
        /// is left out of the picture.
        public var id: String
        /// Where it stands, in units (1 unit ≈ 13 cm; the cat is 2.3 units tall).
        public var x: Float
        public var z: Float
        /// Radians about up.
        public var turn: Float
        /// Its scale along x, y and z (1 for its own size).
        public var size: Vec3
        /// How far it leans about x and about z, radians.
        public var tilt: Vec2
        /// What it grows from, for things grown from a seed (trees): the same seed grows the same tree.
        public var seed: UInt32
        /// Which of its shapes; one it does not have draws as shape 0.
        public var variant: Int
        /// Which swatch of its palette it wears (`MeadowScenery.palette(of:)`), 0 for the first; one it does not
        /// have, or a thing with no palette, draws as the first.
        public var swatch: Int
        /// A run's points along the ground (x, z), in units: a fence's posts stand at each and evenly between
        /// (`MeadowScenery.fencePosts`). Empty for a thing at one spot; for a run, `x` and `z` are its first point.
        public var points: [Vec2]
        /// The span of a run (1-based, between its points) that holds a gate; 0 for none.
        public var gate: Int

        public init(id: String, x: Float, z: Float, turn: Float = 0, size: Vec3 = Vec3(1, 1, 1), tilt: Vec2 = .zero, seed: UInt32 = 0,
                    variant: Int = 0, swatch: Int = 0) {
            self.id = id
            self.x = x
            self.z = z
            self.turn = turn
            self.size = size
            self.tilt = tilt
            self.seed = seed
            self.variant = variant
            self.swatch = swatch
            points = []
            gate = 0
        }

        /// A run (a fence) along `points` (at least two), a gate in span `gate` (0: none).
        public init(id: String, points: [Vec2], gate: Int = 0) {
            self.init(id: id, x: points.first?.x ?? 0, z: points.first?.y ?? 0)
            self.points = points
            self.gate = gate
        }

        /// Whether it lies along a run of points (a fence) rather than standing at one spot.
        public var isRun: Bool { !points.isEmpty }

        /// Moved along the ground by `offset` (x, z), a run's every point with it.
        public mutating func move(by offset: Vec2) {
            x += offset.x
            z += offset.y
            for i in points.indices { points[i] += offset }
        }

        /// Where a cat likes to be at this thing (`MeadowScenery.catSpot(of:)`), in the meadow: turned, leant and
        /// sized as the thing is, standing on the land as it lies before any blanket levels it (a thing within a
        /// blanket's reach makes way, and its spot with it). Nil for a kind that invites none.
        public var catSpot: CatSpot? {
            guard let spot = MeadowScenery.catSpot(of: id), let matrix = Meadow.alone(self)?.matrix else { return nil }
            let toward = matrix.direction(Vec3(spot.toward.x, 0, spot.toward.y))
            let across = Vec2(toward.x, toward.z)
            return CatSpot(spot.kind, at: matrix.point(spot.at), toward: simd_length(across) > 0 ? simd_normalize(across) : spot.toward)
        }
    }

    /// The painted ground: paths, lawn and soil over the meadow's own long grass, as a meadow file's
    /// `ground` grid holds it. Nil for a meadow with nothing painted.
    public struct Ground: Equatable, Sendable {
        /// What a cell is painted with. A file's paints this Whiskr does not know are drawn as `wild`.
        public enum Paint: UInt8, CaseIterable, Sendable {
            /// The meadow's own long grass.
            case wild = 0
            /// Worn earth, the grass closing in over its edges.
            case path
            /// Grass mown short, with the mower's stripes.
            case lawn
            /// Bare, dark tilled earth for beds.
            case soil

            /// The catalog's id of the paint (`ground.path`); the wild grass's is the tray's eraser, never stored.
            public var id: String {
                switch self {
                case .wild: "ground.wild"
                case .path: "ground.path"
                case .lawn: "ground.lawn"
                case .soil: "ground.soil"
                }
            }

            public init?(id: String) {
                guard let paint = Self.allCases.first(where: { $0.id == id }) else { return nil }
                self = paint
            }
        }

        /// Cells along each side, over x, z ∈ [−`reach`, `reach`] (about 0.59 units a cell).
        public static let side = 512
        public static let reach: Float = 150
        /// A cell's width, in units.
        public static var cell: Float { 2 * reach / Float(side) }

        /// `side` × `side` paints (`Paint.rawValue`), row by row from z = −`reach`, each row from x = −`reach`.
        public private(set) var cells: [UInt8]

        /// Nothing painted.
        public init() {
            cells = [UInt8](repeating: 0, count: Self.side * Self.side)
        }

        /// `cells` as given: `side` × `side` of them, each a `Paint`'s raw value (any other is drawn as wild).
        public init(cells: [UInt8]) {
            precondition(cells.count == Self.side * Self.side, "a ground holds side × side cells")
            self.cells = cells.map { Paint(rawValue: $0) == nil ? 0 : $0 }
        }

        public subscript(column: Int, row: Int) -> Paint {
            get { Paint(rawValue: cells[row * Self.side + column]) ?? .wild }
            set { cells[row * Self.side + column] = newValue.rawValue }
        }

        /// The cell a ground point lies in, or nil off the grid.
        public static func cell(at x: Float, _ z: Float) -> (column: Int, row: Int)? {
            let column = Int(((x + reach) / cell).rounded(.down)), row = Int(((z + reach) / cell).rounded(.down))
            guard (0..<side).contains(column), (0..<side).contains(row) else { return nil }
            return (column, row)
        }
    }

    /// In the order they are drawn.
    public var things: [Thing]
    /// The painted ground, nil when nothing is painted.
    public var ground: Ground?

    public init(things: [Thing] = [], ground: Ground? = nil) {
        self.things = things
        self.ground = ground
    }

    /// Grass, hills and sky, and nothing else.
    public static let empty = MeadowScenery()

    /// The Default: the meadow as it always was (`StandardMeadow`).
    public static var standard: MeadowScenery { StandardMeadow.grown.scenery }

    /// Whether the scene can draw things with this id. A meadow can hold ids it cannot (yet) draw; they are
    /// kept in its file and left out of the picture.
    public static func draws(_ id: String) -> Bool { SceneryCatalog.kinds[id] != nil }

    /// Every catalog id the scene can draw (the parcel a thing from a newer Whiskr shows as is not one).
    public static var drawnIds: Set<String> { Set(SceneryCatalog.kinds.keys).subtracting([parcel]) }

    /// A place at a thing where a cat likes to be: sitting on a stump, in a box or by a bowl, napping in a bed,
    /// scratching at a post. For the meadow's cats to go to; nothing in the scene uses it yet.
    public struct CatSpot: Equatable, Sendable {
        public enum Kind: String, Sendable, CaseIterable {
            /// Sits there (on top of it, in it, or in front of it).
            case sit
            /// Curls up there to sleep.
            case nap
            /// Stands there, stretched up, scratching.
            case scratch
        }

        public var kind: Kind
        /// Where its paws are: on the thing as it is made (its own size and turn, y up from the ground under
        /// it), or, from `MeadowScenery.Thing.catSpot`, in the meadow.
        public var at: Vec3
        /// Which way a cat there faces, across the ground (x, z), a unit long.
        public var toward: Vec2

        public init(_ kind: Kind, at: Vec3, toward: Vec2) {
            self.kind = kind
            self.at = at
            self.toward = toward
        }
    }

    /// Where a cat likes to be at a thing of this kind, on the thing as it is made; nil for a kind that invites
    /// none (a flower, a tree, a ball of yarn).
    public static func catSpot(of id: String) -> CatSpot? { SceneryCatalog.catSpots[id] }

    /// One colour a made thing can wear: its name (as a meadow file writes it) and how it looks, in sRGB, for the
    /// editor's swatches. The colours are the meadow's own clay, drawn from the blankets' gingham.
    public struct Swatch: Equatable, Sendable {
        public var name: String
        public var color: MeadowColor
    }

    /// The colours a thing of this kind can wear, the first its own; empty for a kind with no palette.
    public static func palette(of id: String) -> [Swatch] {
        (SceneryCatalog.palettes[id] ?? []).map { Swatch(name: $0, color: Palette.swatch($0).color) }
    }

    /// The posts a run along `points` stands on: one at each point, and evenly between them, never more than
    /// `fencePostSpacing` apart (as a meadow file's catalog counts them). A run closed on itself (its last point
    /// on its first) has no second post where it closes.
    public static func fencePosts(along points: [Vec2]) -> [Vec2] { Fences.posts(along: points).map(\.at) }

    /// Between a fence's posts at most, in units.
    public static let fencePostSpacing: Float = Fences.spacing

    /// The most the meadow draws of each kind of thing: what a meadow file may hold (its catalog's caps).
    /// Past one, further things of that kind are left out, in order.
    public enum Limits {
        /// Things in all.
        public static let things = 5_000
        /// Trees, young ones included.
        public static let trees = 48
        /// Tall things, each of which fades to see-through when it stands in front of a cat.
        public static let tall = 120
        /// How far from the meadow's middle a thing may stand, in units.
        public static let reach: Float = 160
    }
}
