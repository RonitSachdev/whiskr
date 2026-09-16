import Foundation
import simd

/// What the meadow draws on the ground for its editor: rings under the chosen things (in the focus colour,
/// as a chosen cat's; a chosen tree also ringed where its crown shades the ground, and lit a little), a
/// dashed ring under each one that may not stand where it is now, a faint ring under the one the pointer is
/// on, the keyboard's cursor, the thing about to be placed, the Brush's or the Eraser's circle, and the
/// picnic ground's dashed outline. Things are named by their index in the scenery shown.
public struct MeadowEditMarks: Equatable, Sendable {
    /// Chosen: a ring of the focus colour round each one's ground.
    public var selected: [Int]
    /// May not stand where they are now (a drag over a spot it cannot go): a dashed ring instead.
    public var refused: [Int]
    /// Under the pointer: a faint ring.
    public var hovered: Int?
    /// Where the keyboard's cursor is on the ground (x, z), when it shows.
    public var cursor: SIMD2<Float>?
    /// The thing about to be placed (the tray's item, armed): drawn see-through where it would stand, its
    /// ground ringed and its turn marked by a tick on the ring. It is not part of the scenery: nothing
    /// shades, blooms or makes way for it.
    public var ghost: MeadowScenery.Thing?
    /// The ghost may not stand where it is: drawn greyed, its ring dashed (never told by colour alone).
    public var ghostRefused: Bool
    /// The Brush's or the Eraser's circle on the ground.
    public var brush: BrushCircle?
    /// Increase Contrast: rings and the picnic ground's outline at 3:1 against the grass.
    public var highContrast: Bool

    /// A circle of ground the Brush paints or the Eraser clears.
    public struct BrushCircle: Equatable, Sendable {
        /// Its middle (x, z) and radius, in units.
        public var center: SIMD2<Float>
        public var radius: Float
        /// The Eraser's (drawn dashed, in the ink) rather than the Brush's (the focus colour).
        public var erasing: Bool

        public init(center: SIMD2<Float>, radius: Float, erasing: Bool) {
            self.center = center
            self.radius = radius
            self.erasing = erasing
        }
    }

    public init(selected: [Int] = [], refused: [Int] = [], hovered: Int? = nil, cursor: SIMD2<Float>? = nil, ghost: MeadowScenery.Thing? = nil,
                ghostRefused: Bool = false, brush: BrushCircle? = nil, highContrast: Bool = false) {
        self.selected = selected
        self.refused = refused
        self.hovered = hovered
        self.cursor = cursor
        self.ghost = ghost
        self.ghostRefused = ghostRefused
        self.brush = brush
        self.highContrast = highContrast
    }
}

extension Stage {
    /// Looking down on the meadow while it is edited: about 55° above the ground.
    static let editPitch: Float = 55 * .pi / 180
    /// The closest the view comes while editing, for detail.
    static let editClosest: Float = 5

    /// The ground the view may roam while editing: the whole meadow a thing may stand on.
    static var editableGround: Ground {
        Ground(x: 0, z: 0, across: SceneryRules.reach, deep: SceneryRules.reach)
    }

    /// What the view frames on entering edit mode, and again with `0`: the blankets and the picnic ground
    /// round them, with the nearest scenery about them.
    var editGround: Ground {
        var minX: Float = -42, maxX: Float = 42, minZ: Float = -34, maxZ: Float = 40
        if let village, village.count > 0 {
            let b = village.bounds
            minX = Swift.min(minX, b.x - b.across - 14)
            maxX = Swift.max(maxX, b.x + b.across + 14)
            minZ = Swift.min(minZ, b.z - b.deep - 16)
            maxZ = Swift.max(maxZ, b.z + b.deep + 16)
        }
        return Ground(x: (minX + maxX) / 2, z: (minZ + maxZ) / 2, across: (maxX - minX) / 2, deep: (maxZ - minZ) / 2)
    }

    // MARK: pointing at scenery

    /// The scenery's thing under a point of the view (points, origin top left), the nearest of those whose
    /// shape is under it; nil over grass, sky, cats and blankets.
    func pickScenery(_ point: Vec2) -> Int? {
        guard let meadow else { return nil }
        var best: (thing: Int, depth: Float)?
        for i in meadow.scenery.things.indices {
            for ball in meadow.picking(i) {
                let c = screen(ball.center)
                guard c.z <= 1 else { continue }
                let e = screen(ball.center + surroundings.up * ball.radius)
                guard hypot(c.x - point.x, c.y - point.y) < hypot(e.x - c.x, e.y - c.y), c.z < (best?.depth ?? .infinity) else { continue }
                best = (i, c.z)
            }
        }
        return best?.thing
    }

    /// The things standing inside a rectangle of the view (by the spot each stands on), in order.
    func scenery(inside box: ScreenBox) -> [Int] {
        guard let meadow else { return [] }
        return meadow.scenery.things.indices.filter { i in
            guard meadow.laid[i] != .none else { return false }
            let thing = meadow.scenery.things[i]
            // A fence: any of its points inside.
            return (thing.isRun ? thing.points : [Vec2(thing.x, thing.z)]).contains { spot in
                let p = screen(Vec3(spot.x, Land.height(spot.x, spot.y), spot.y))
                return p.z <= 1 && box.contains(Vec2(p.x, p.y))
            }
        }
    }

    /// Where some things are drawn on screen, all of them together (nil: none is drawn).
    func screenBox(ofScenery things: [Int]) -> ScreenBox? {
        guard let meadow else { return nil }
        var box = ScreenBox.empty
        for i in things {
            for ball in meadow.picking(i) {
                let c = screen(ball.center)
                guard c.z <= 1 else { continue }
                let e = screen(ball.center + surroundings.up * ball.radius)
                let r = hypot(e.x - c.x, e.y - c.y)
                box = box.union(ScreenBox(left: c.x - r, top: c.y - r, right: c.x + r, bottom: c.y + r))
            }
        }
        return box.isEmpty ? nil : box
    }

    /// The spot on the land under a point of the view (points, origin top left), if the view looks at land there.
    func groundPoint(_ point: Vec2) -> Vec2? {
        let (o, d) = camera.ray(point)
        guard d.y < -1e-4 else { return nil }
        // The plane at the level middle's height first, then down the land's own rise, a few times over.
        var height = Float(Land.ground)
        var hit = Vec2.zero
        for _ in 0..<4 {
            let t = (height - o.y) / d.y
            guard t > 0 else { return nil }
            let p = o + d * t
            hit = Vec2(p.x, p.z)
            height = Land.height(p.x, p.z)
        }
        return hit
    }
}
