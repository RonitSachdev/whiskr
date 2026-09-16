import Foundation
import simd

/// The scenery a meadow holds (trees, flowers, mushrooms, stones, the log, and later whatever a person
/// places), as plain values: what a meadow file's `items` say, in the scene's own terms. Give it to
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

        public init(id: String, x: Float, z: Float, turn: Float = 0, size: Vec3 = Vec3(1, 1, 1), tilt: Vec2 = .zero, seed: UInt32 = 0,
                    variant: Int = 0) {
            self.id = id
            self.x = x
            self.z = z
            self.turn = turn
            self.size = size
            self.tilt = tilt
            self.seed = seed
            self.variant = variant
        }
    }

    /// In the order they are drawn.
    public var things: [Thing]

    public init(things: [Thing] = []) {
        self.things = things
    }

    /// Grass, hills and sky, and nothing else.
    public static let empty = MeadowScenery()

    /// The Default: the meadow as it always was (`StandardMeadow`).
    public static var standard: MeadowScenery { StandardMeadow.grown.scenery }

    /// Whether the scene can draw things with this id. A meadow can hold ids it cannot (yet) draw; they are
    /// kept in its file and left out of the picture.
    public static func draws(_ id: String) -> Bool { SceneryCatalog.kinds[id] != nil }

    /// Every id the scene can draw.
    public static var drawnIds: Set<String> { Set(SceneryCatalog.kinds.keys) }

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
