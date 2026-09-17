import Foundation
import simd

// Everything in the scene and how it moves from frame to frame: main.ts's frame function. Rendering
// reads from it; it knows nothing about Metal.

final class Stage {
    enum Mode { case meadow, playground }
    let mode: Mode
    let camera = MapCamera()
    var light = Light()
    var settings = MeadowSettings() { didSet { settingsChanged(oldValue) } }
    /// Seconds since the scene began (kit.ts uTime).
    private(set) var time: Float = 0
    private(set) var frame = 0
    var surroundings = Surroundings()
    /// The cats to draw this frame.
    private(set) var cats: [Cat] = []
    let meadow: Meadow?
    let village: Village?
    /// The playground's lone cat.
    private(set) var playgroundCat: Cat?
    var pointer = Vec2.zero
    /// What every meadow shader shares: clearings, mown patches, streams, trodden paths.
    private(set) var world = WorldUniforms()
    private(set) var clearingCount = 0, streamCount = 0, pathCount = 0
    var meadowTime: Float { time }

    private var lastBearing: Float = 0
    private var sinceLit: Float = .infinity
    private var sights: [Ball] = []
    private var clearOf: [Ball] = []
    private var sightCount = 0
    private var sleepers: [Perch] = []

    init(mode: Mode) {
        self.mode = mode
        cats.reserveCapacity(256)
        sights.reserveCapacity(128)
        sleepers.reserveCapacity(64)
        switch mode {
        case .playground:
            meadow = nil
            village = nil
            light = .playground
            let cat = Cat(seed: "playground")
            playgroundCat = cat
            // stage.ts camera: (2.8, 6.6, 8.4) looking at (0, 1.2, 0.2).
            let offset = Vec3(2.8, 6.6 - 1.2, 8.4 - 0.2)
            camera.setView(CameraView(x: 0, z: 0.2, distance: simd_length(offset), pitch: asin(offset.y / simd_length(offset)), bearing: atan2(offset.x, offset.z)))
            camera.bounds = { Ground(x: 0, z: 0, across: 100, deep: 100) }
        case .meadow:
            let meadow = Meadow()
            let village = Village()
            village.obstacles = meadow.obstacles
            village.lay(meadow.scenery, shade: meadow.shade, fences: meadow.fences)
            // Cats prefer the ground they like walking on: a painted path, stepping stones.
            village.liking = { [unowned meadow] p in meadow.walkingEase(p.x, p.y) }
            self.meadow = meadow
            self.village = village
            surroundings.critters = meadow.critters.spots
            light = Daylight.light(settings)
            windToward = light.windToward
            sinceLit = 0
        }
        if mode == .meadow {
            camera.aim = { [unowned self] in self.editing ? self.editGround : self.aim() }
            camera.bounds = { [unowned self] in self.editing ? Self.editableGround : self.everything(0) }
            camera.adjust = { [unowned self] in self.editing ? $0 : self.keepingFollowed($0) }
        }
        surroundings.gust = { [unowned self] x, z in self.meadow == nil ? 0 : Meadow.gust(x, z, drift: self.gustDrift) }
    }

    private func settingsChanged(_ old: MeadowSettings) {
        if old.timeOfDay != settings.timeOfDay || old.weather != settings.weather || old.place != settings.place || old.effects != settings.effects {
            sinceLit = .infinity
        }
        village?.flagSize = settings.flagSize
        village?.setPicnic(settings.picnic)
        village?.catsWander = settings.catsWander
        if let village, village.arrangement != settings.arrangement {
            village.arrangement = settings.arrangement
            if settings.arrangement == .column {
                // Looking straight along the column from above and in front, as a sidebar reads.
                var view = camera.view
                view.bearing = 0
                view.pitch = MapCamera.columnPitch
                camera.setView(view)
            }
            focus = nil
            camera.settle()
        }
    }

    // MARK: the camera's aim (main.ts)

    /// How far below the top edge the first row's flag sits in a sidebar's column taller than the view, in
    /// points; the least room kept above and below one that fits.
    static let columnTopMargin: Float = 22

    /// What the column's framing was worked out from, and when: it is worked out again only when the
    /// workspaces, the way they are laid out, the open part of the view or the flags' size change.
    private struct FramingKey: Equatable { var lineup: Int, perRow: Int, open: Vec2, flagSize: Float }
    private var framed: (key: FramingKey, frame: Village.ColumnFrame)?

    private func framedColumn(_ village: Village) -> Village.ColumnFrame? {
        let key = FramingKey(lineup: village.lineup, perRow: village.perRow, open: camera.viewport - camera.coverGoal, flagSize: settings.flagSize)
        if let framed, framed.key == key { return framed.frame }
        guard let frame = village.columnFrame else { return nil }
        framed = (key, frame)
        return frame
    }

    /// How far back a camera looking at (x, z) must be for every blanket framed to keep 8 points inside the
    /// view's sides. `fit` frames the ground as if all of it lay at the middle's distance; a blanket nearer
    /// the camera (lower in the view) looks wider, by as much as it is nearer.
    private func sidesDistance(_ frame: Village.ColumnFrame, x: Float, z: Float) -> Float {
        let v = camera.viewport
        let room = (v.x - camera.coverGoal.x) / 2 - 8
        guard room > 1 else { return 0 }
        let pitch = camera.view.pitch
        let forward = Vec3(0, -sin(pitch), -cos(pitch))
        let target = Vec3(x, MapCamera.height, z)
        // A point's depth in front of the eye is its depth past the target plus the distance; its offset on
        // screen, in points, is its offset across over that depth, scaled by the projection.
        let across = tan(MapCamera.fovY / 2) * v.x / Swift.max(v.y, 1) / (v.x / 2)
        var least: Float = 0
        for p in frame.sides {
            least = Swift.max(least, abs(p.x - x) / (room * across) - simd_dot(p - target, forward))
        }
        return least
    }

    /// The chosen blanket (leaning a little toward a chosen cat), or else everything.
    private func aim() -> Ground {
        guard let village else { return Ground(x: 0, z: 0, across: 10, deep: 10) }
        if village.arrangement == .column, village.count == 0 {
            // Nothing open yet: a calm view over the middle of the meadow, waiting for the first blanket.
            return Self.emptyMeadow
        }
        if village.arrangement == .column, let frame = framedColumn(village) {
            return columnGround(frame, from: camera.view, flagTop: followedColumnTop(frame))
        }
        let only = village.count == 1 ? village.plots.first?.view.id : nil
        guard let id = focus?.blanketID ?? only, let spot = village.ground(of: id) else { return everything(1.5) }
        var cat: Vec3?
        if case .cat(let b, let a) = focus { cat = village.actor(b, a)?.head }
        let lean: Float = cat == nil ? 0 : 0.3
        return Ground(x: lerp(spot.x, cat?.x ?? 0, lean), z: lerp(spot.z - 0.5, cat?.z ?? 0, lean), across: spot.r + 0.8, deep: spot.r + 1.4)
    }

    /// The column's framing as seen from `view`: the workspaces centred in the open part of the view when
    /// they fit in it, else the first row's flags a little below its top edge (the rest scroll), or the flags'
    /// top at `flagTop` points when given (to keep a chosen workspace in view, `Follow.swift`). Where the
    /// content's top and bottom land is measured with the camera's own projection each frame and the aim
    /// corrected by what is left, so this holds exactly for any width, height and number of rows. The content
    /// is as laid out when the workspaces or the view last changed: helpers coming and going never move the
    /// camera.
    func columnGround(_ frame: Village.ColumnFrame, from view: CameraView, flagTop wantedTop: Float?) -> Ground {
        let open = Swift.max(camera.viewport.y - camera.coverGoal.y, 1)
        let top = screen(frame.top, from: view), bottom = screen(frame.bottom, from: view)
        let flagTop = top.y - FLAG_PIXELS * settings.flagSize
        let perPoint = 2 * tan(MapCamera.fovY / 2) * view.distance / open / Swift.max(sin(view.pitch), 0.3)
        let tall = bottom.z > 1 ? Float.infinity : bottom.y - flagTop
        let wanted = wantedTop ?? (tall + 2 * Self.columnTopMargin <= open ? (open - tall) / 2 : Self.columnTopMargin)
        let error = top.z > 1 ? -open / 2 : flagTop - wanted
        let z = view.z + error * perPoint
        return Ground(x: frame.x, z: z, across: frame.across, deep: frame.deep, least: sidesDistance(frame, x: frame.x, z: z))
    }

    /// The column as laid out now, framed (`framedColumn`).
    var columnFrame: Village.ColumnFrame? { village.flatMap { $0.arrangement == .column ? framedColumn($0) : nil } }

    /// The calm view over an empty meadow, waiting for the first blanket.
    static let emptyMeadow = Ground(x: 0, z: 2, across: 20, deep: 14)

    private func everything(_ margin: Float) -> Ground {
        if village?.count == 0 { return Self.emptyMeadow }
        let b = village?.bounds ?? Ground(x: 0, z: 0, across: 10, deep: 10)
        return Ground(x: b.x, z: b.z - margin * 0.6, across: b.across + margin, deep: b.deep + margin * 1.4)
    }

    // MARK: what is chosen, pointed at and held

    /// The meadow is being edited (`MeadowView.isEditing`): the camera frames the picnic ground from above
    /// and may roam the whole meadow, the blankets keep their rows, and the editor's marks are drawn.
    var editing = false
    /// What the editor marks on the ground (`MeadowEditMarks`).
    var editMarks = MeadowEditMarks()
    /// Blankets to a row while editing: as they were when editing began (nil: worked out from the width).
    /// Held a little past the end of editing, until the view has its width back, so the rows never re-flow
    /// for the moment the meadow is still wide.
    var heldPerRow: Int?
    /// Seconds the held rows stay held once editing has ended and the view has stopped moving.
    var heldRowsLinger: Float = 0

    var selection: MeadowItem? { didSet { village?.chosen = selection } }
    /// What has the keyboard's attention: ringed in the focus colour.
    var keyboardFocus: MeadowItem?
    /// What the camera frames when it flies (nil: everything).
    var focus: MeadowItem?
    /// What you last chose, which the camera follows (`Follow.swift`): kept in comfortable view whenever
    /// the framing is worked out again (a resize, a blanket arriving), never because of what agents do.
    var followed: MeadowItem? { didSet { followedShift = nil; followedTop = nil } }
    /// How far the framing is moved to keep `followed` comfortable, and what that was worked out for.
    var followedShift: (key: FollowKey, shift: CameraShift)?
    /// In a column, where the flags' top goes on screen to keep `followed` comfortable (nil: as framed).
    var followedTop: (key: FollowKey, y: Float?)?
    private var hoveredCat: Cat?
    private var pettedCat: Cat?

    /// Nothing on screen is moving fast, so fewer frames will do.
    var restful: Bool { (village?.restful ?? true) && (playgroundCat?.restful ?? true) }
    /// Nothing under way at all but the meadow's ambient motion and each cat's own slow loop: the scene
    /// may rest (`MeadowView`), drawn at a slow tick with everything moving at `pace`.
    var still: Bool { !camera.moving && (village?.still ?? true) && (playgroundCat?.still ?? true) }
    /// How fast the scene's own time runs, 0…1: slowed while it rests, so at the resting rate each frame
    /// moves things as little as a frame at the full rate does. The camera always keeps real time.
    var pace: Float = 1
    /// Ambient motion on (`MeadowView.animatesAmbient`). Off, the meadow's own time stands still: grass,
    /// flowers, critters, fireflies, falling seeds, flickering lights and every cat's idle life hold where
    /// they are, while changes of state, the light and the camera go on.
    var ambient = true {
        didSet {
            village?.ambient = ambient
            playgroundCat?.frozen = !ambient
        }
    }

    /// Lays a new scenery in the meadow; blankets keep off its trees and logs.
    func show(_ scenery: MeadowScenery) {
        guard let meadow, let village else { return }
        meadow.show(scenery)
        village.obstacles = meadow.obstacles
        village.lay(meadow.scenery, shade: meadow.shade, fences: meadow.fences)
    }

    func show(_ world: MeadowWorld) {
        if let cat = playgroundCat {
            // The playground's cat acts out the first agent it is given.
            let agent = world.blankets.first?.agents.first
            cat.setActivity(agent.map { $0.failed ? .error : $0.activity } ?? .awake)
            cat.needsYou = agent?.needsYou ?? false
            cat.doneUnseen = agent?.doneUnseen ?? false
        }
        guard let village else { return }
        let before = village.count
        fitVillageToView()
        village.show(world)
        if let item = focus, village.plot(item.blanketID) == nil { focus = nil }
        if let item = selection, village.plot(item.blanketID) == nil { selection = nil }
        if let item = keyboardFocus, village.plot(item.blanketID) == nil { keyboardFocus = nil }
        if let item = followed, village.plot(item.blanketID) == nil { followed = nil }
        // A blanket arriving or leaving changes the picture: unless you are in close on one, show them all.
        if village.count != before && focus == nil { camera.fly() }
    }

    /// The blankets are laid out for the part of the view panels leave open.
    private func fitVillageToView() {
        guard let village else { return }
        if village.arrangement == .column {
            // A sidebar holds one column; a wider meadow spreads the same order into rows. While the meadow is
            // edited it keeps the rows it had, however wide it grows: you arrange round the picnic you see.
            let width = camera.viewport.x - camera.coverGoal.x
            let fits = width < 420 ? 1 : Swift.min(6, Swift.max(2, Int(width / 300)))
            if !editing, let held = heldPerRow, held == fits || heldRowsLinger <= 0 { heldPerRow = nil }
            village.perRow = heldPerRow ?? fits
            return
        }
        let open = Vec2(Swift.max(camera.viewport.x - camera.coverGoal.x, 1), Swift.max(camera.viewport.y - camera.coverGoal.y, 1))
        village.fit(aspect: open.x / open.y)
    }

    /// Where a point in the world lands on screen, in points with the origin top left; z > 1 is behind.
    func screen(_ p: Vec3) -> Vec3 {
        let v = camera.viewport
        let m: Mat4 = camera.projection(aspect: v.x / Swift.max(v.y, 1)) * camera.viewMatrix
        let clip: Vec4 = m * Vec4(p.x, p.y, p.z, 1)
        if clip.w <= 0 { return Vec3(0, 0, 2) }
        let ndc = Vec3(clip.x, clip.y, clip.z) / clip.w
        return Vec3((ndc.x + 1) / 2 * v.x, (1 - ndc.y) / 2 * v.y, ndc.z)
    }

    /// `screen` through a given view instead of the camera's own.
    func screen(_ p: Vec3, from view: CameraView) -> Vec3 {
        let v = camera.viewport
        let m: Mat4 = camera.projection(aspect: v.x / Swift.max(v.y, 1)) * MapCamera.viewMatrix(of: view)
        let clip: Vec4 = m * Vec4(p.x, p.y, p.z, 1)
        if clip.w <= 0 { return Vec3(0, 0, 2) }
        let ndc = Vec3(clip.x, clip.y, clip.z) / clip.w
        return Vec3((ndc.x + 1) / 2 * v.x, (1 - ndc.y) / 2 * v.y, ndc.z)
    }

    // MARK: where things are on screen

    /// Where something is on screen, in points with the origin top left: a blanket with its flag, a cat
    /// with its bubble, a lantern (only while it shows, after dark). Nil if it is not laid out or is
    /// behind the camera.
    func screenBox(of item: MeadowItem) -> ScreenBox? {
        if let cat = playgroundCat, case .cat = item { return box(of: cat) }
        guard let village, let plot = village.plot(item.blanketID) else { return nil }
        switch item {
        case .blanket:
            return village.blanketAndFlagBox(plot, self)
        case .cat(_, let agent):
            guard let actor = plot.actors[agent], !actor.leaving else { return nil }
            return box(of: actor.cat)
        case .lantern(_, let id):
            guard let lantern = plot.lanterns.first(where: { $0.view.id == id && !$0.leaving && !$0.hidden }), village.shown(lantern) > 0.01 else { return nil }
            return ball(plot.group + lantern.at + Vec3(0, 0.5, 0) * LANTERN_SIZE, 0.6 * LANTERN_SIZE)
        }
    }

    /// A cat's body and, while it shows, its bubble.
    private func box(of cat: Cat) -> ScreenBox? {
        guard var box = ball(cat.bodyMatrix.point(Vec3(0, 1.1, 0)), 1.3 * cat.size) else { return nil }
        if cat.bubbleShown, let bubble = ball(Vec3(cat.bubbleDrawn.x, cat.bubbleDrawn.y, cat.bubbleDrawn.z), cat.bubbleDrawn.w / 2) { box = box.union(bubble) }
        return box
    }

    /// A ball in the world as a box on screen.
    private func ball(_ center: Vec3, _ radius: Float) -> ScreenBox? {
        let c = screen(center)
        if c.z > 1 { return nil }
        let e = screen(center + surroundings.up * radius)
        let r = hypot(e.x - c.x, e.y - c.y)
        return ScreenBox(left: c.x - r, top: c.y - r, right: c.x + r, bottom: c.y + r)
    }

    /// The blankets (by index) whose blanket and flag are not wholly within the view's height: past its
    /// top edge, and past its bottom edge, in order. One taller than the view that spans it counts as in
    /// view. Written into lists kept by the caller, so it allocates nothing.
    func outOfView(above: inout [Int], below: inout [Int]) {
        above.removeAll(keepingCapacity: true)
        below.removeAll(keepingCapacity: true)
        guard let village else { return }
        let bottom = camera.viewport.y - camera.cover.y
        for (i, plot) in village.plots.enumerated() {
            guard let box = village.blanketAndFlagBox(plot, self) else { continue }
            if box.top < 0 && box.bottom > bottom { continue }
            if box.top < 0 { above.append(i) } else if box.bottom > bottom { below.append(i) }
        }
    }

    /// How far to scroll along the ground (world units toward the top of the view; negative toward its
    /// bottom) so that a blanket and its flag are wholly in view with `margin` points to spare: just as
    /// far as that takes, 0 when they already are. One taller than the view has its top brought in.
    func revealDistance(_ id: String, margin: Float) -> Float {
        guard let village, let plot = village.plot(id) else { return 0 }
        // Its flag's size on screen (behind the camera for now: as tall as flags are drawn).
        let flag = village.flagBox(plot, self) ?? ScreenBox(left: 0, top: 0, right: 0, bottom: FLAG_PIXELS * settings.flagSize)
        let start = camera.view, ahead = camera.ahead
        // Where it lies on screen with the view scrolled by `d`: the cloth where it would be seen from
        // there, and the flag at its foot, the size it is now (flags keep one size on screen).
        func box(_ d: Float) -> ScreenBox? {
            var v = start
            v.x += ahead.x * d
            v.z += ahead.z * d
            let foot = screen(plot.flagAt, from: v)
            guard foot.z <= 1, let cloth = village.blanketBox(plot, { screen($0, from: v) }) else { return nil }
            let half = (flag.right - flag.left) / 2
            return cloth.union(ScreenBox(left: foot.x - half, top: foot.y - (flag.bottom - flag.top), right: foot.x + half, bottom: foot.y))
        }
        let top = margin, low = camera.viewport.y - camera.cover.y - margin
        // Scrolling toward the top (d > 0) moves everything down the screen; the other way, up. How far
        // until `arrived`, found by doubling and then halving: an edge moves steadily with the scroll.
        func distance(_ sign: Float, _ arrived: (ScreenBox) -> Bool) -> Float {
            func past(_ d: Float) -> Bool { box(d * sign).map(arrived) ?? false }
            var near: Float = 0, far: Float = 0.5
            while !past(far) && far < 1000 { near = far; far *= 2 }
            for _ in 0..<30 {
                let middle = (near + far) / 2
                if past(middle) { far = middle } else { near = middle }
            }
            return far * sign
        }
        // Not drawable from here (behind the camera, which along a column means below): as if below.
        let now = box(0)
        if let now, now.top < top { return distance(1) { $0.top >= top } }
        guard now == nil || now!.bottom > low else { return 0 }
        // Its bottom brought up to the bottom margin; one taller than the view has its top brought in instead.
        let up = distance(-1) { $0.bottom <= low }
        if let there = box(up), there.top < top { return distance(-1) { $0.top <= top } }
        return up
    }

    func pick(_ point: Vec2) -> MeadowItem? {
        if let cat = playgroundCat {
            let head = screen(cat.head), edge = screen(cat.head + surroundings.up * 1.1)
            return hypot(head.x - point.x, head.y - point.y) < hypot(edge.x - head.x, edge.y - head.y) ? .cat(blanket: "playground", agent: "playground") : nil
        }
        guard let village else { return nil }
        if let (plot, actor) = village.pickCat(point, self) { return .cat(blanket: plot.view.id, agent: actor.view.id) }
        if let (plot, lantern) = village.pickLantern(point, self) { return .lantern(blanket: plot.view.id, lantern: lantern.view.id) }
        if let plot = village.pickFlag(point, self) { return .blanket(plot.view.id) }
        if let plot = village.pickBlanket(point, self) { return .blanket(plot.view.id) }
        return nil
    }

    func cat(for item: MeadowItem?) -> Cat? {
        guard case .cat(let b, let a) = item else { return nil }
        return playgroundCat ?? village?.actor(b, a)?.cat
    }

    func hover(_ item: MeadowItem?) {
        hoveredCat?.watched = false
        hoveredCat = cat(for: item)
        hoveredCat?.watched = true
    }

    /// Starts or stops petting the cat under the pointer; returns whether one was being petted.
    @discardableResult func setPetting(_ on: Bool) -> Bool {
        let was = pettedCat != nil
        pettedCat?.petting = false
        pettedCat = on ? hoveredCat : nil
        pettedCat?.petting = true
        return was
    }

    func hop(_ item: MeadowItem?) { cat(for: item)?.hop() }

    /// Works the light out afresh for the time of day, the sun, the moon and the weather; whether it changed.
    @discardableResult func relight() -> Bool {
        guard mode == .meadow else { return false }
        sinceLit = 0
        let fresh = Daylight.light(settings)
        let changed = fresh != light
        light = fresh
        return changed
    }

    // MARK: wind and lightning

    /// Which way the wind blows in the grass now: eased round to the weather's over a couple of seconds
    /// when it turns (at once with ambient motion off), never snapping.
    private(set) var windToward = Light.breeze
    /// How far the gusts' waves have travelled across the meadow, in the noise's own units: moved on each
    /// frame along the wind, faster the harder it blows, so a change of wind changes only where they go next.
    private(set) var gustDrift = Vec2.zero
    /// How bright a flash of sheet lightning is this frame, 0…1. Only in a thunderstorm, only while the
    /// meadow's ambient motion plays and Reduce Motion is off.
    private(set) var flash: Float = 0

    private func blow(_ drift: Float, _ dt: Float) {
        let goal = light.windToward
        if !ambient || simd_distance(windToward, goal) < 1e-4 {
            windToward = goal
        } else {
            let eased = windToward + (goal - windToward) * min(1, dt * 1.5)
            // Exactly opposite, easing would pass through nothing: turn a quarter first.
            windToward = simd_length(eased) > 0.05 ? simd_normalize(eased) : Vec2(-windToward.y, windToward.x)
        }
        gustDrift += windToward * (0.11 + 0.11 * light.wind) * drift
        let calm = village?.reduceMotion ?? true
        flash = light.thunder && ambient && !calm ? Lightning.flash(at: Double(time)) : 0
    }

    // MARK: each frame

    func update(_ seconds: Float) {
        camera.update(seconds)
        if !editing, heldPerRow != nil, !camera.gliding { heldRowsLinger -= seconds }
        let dt = seconds * pace
        // What only sways, drifts and flickers moves with the meadow's time; the rest with `dt`.
        let drift = ambient ? dt : 0
        time += drift
        frame += 1
        fitVillageToView()
        // How fast you are swinging the view round, which the cats notice. A flight is not you swinging it.
        let turned = abs(turnFrom(lastBearing, camera.view.bearing))
        lastBearing = camera.view.bearing
        surroundings.swirl = camera.flying ? 0 : lerp(surroundings.swirl, turned / max(dt, 1e-3), 0.3)
        let inv = camera.viewMatrix.inverse
        surroundings.eye = camera.eye
        surroundings.right = simd_normalize(inv.direction(Vec3(1, 0, 0)))
        surroundings.up = simd_normalize(inv.direction(Vec3(0, 1, 0)))
        // With ambient motion off the cats' eyes no longer follow the pointer about.
        surroundings.pointer = ambient ? pointer : .zero
        surroundings.frame = frame

        sinceLit += dt
        if mode == .meadow, sinceLit > 30 { relight() }
        blow(drift, dt)

        cats.removeAll(keepingCapacity: true)
        if let cat = playgroundCat {
            cat.update(dt, surroundings)
            cats.append(cat)
        }
        if let village, let meadow {
            // Let go of last frame's critter positions before they move, so moving them copies nothing.
            surroundings.critters = []
            village.sleepers(into: &sleepers)
            sightCount = village.sights(into: &sights)
            let clearCount = village.keepClear(into: &clearOf)
            clearingCount = village.clearings(into: &world, eased: true, dt: dt)
            streamCount = village.streams.count
            for i in 0..<MAX_STREAMS { world.streams[i] = i < streamCount ? village.streams[i] : .zero }
            meadow.update(drift, fading: dt, time: time, eye: camera.eye, lookAt: camera.target, sleepers: sleepers, sights: sights, sightCount: sightCount,
                          clearOf: clearOf, clearCount: clearCount, clearings: world.clearings, clearingCount: clearingCount, light: light, windToward: windToward)
            surroundings.critters = meadow.critters.spots
            // Garden lamps come on at dusk one by one, warming up; at once with Reduce Motion or the animation off.
            meadow.light(dt, lit: light.lampsLit, steady: !ambient || village.reduceMotion, ghost: editing ? editMarks.ghost : nil,
                         clearings: world.clearings, clearingCount: clearingCount)
            village.clock += seconds
            village.update(dt, surroundings, stage: self)
            village.collectCats(into: &cats)
            pathCount = village.troddenCount
            for i in 0..<pathCount { world.paths[i] = village.trodden[i] }
        }
    }
}

/// A rectangle on screen, in points with the origin top left.
struct ScreenBox: Equatable {
    var left: Float, top: Float, right: Float, bottom: Float
    static let empty = ScreenBox(left: .infinity, top: .infinity, right: -.infinity, bottom: -.infinity)
    var isEmpty: Bool { left > right || top > bottom }
    func contains(_ p: Vec2) -> Bool { p.x > left && p.x < right && p.y > top && p.y < bottom }
    mutating func add(_ p: Vec2) {
        left = min(left, p.x); right = max(right, p.x); top = min(top, p.y); bottom = max(bottom, p.y)
    }
    func union(_ o: ScreenBox) -> ScreenBox {
        ScreenBox(left: min(left, o.left), top: min(top, o.top), right: max(right, o.right), bottom: max(bottom, o.bottom))
    }
}
