import AppKit
import Testing
import UniformTypeIdentifiers
import simd
@_spi(Diagnostics) @testable import MeadowScene

// Garden lamps (Stage 9): the model, when they are lit, how they warm up, their light baked into the ground's
// map and how it looks, and that a lamplit night still rests.

private let lampID = "work.lampPost"

private func lamp(_ x: Float, _ z: Float, turn: Float = 0) -> MeadowScenery.Thing { MeadowScenery.Thing(id: lampID, x: x, z: z, turn: turn) }

/// Thirty-two lamps in rows beside the picnic ground, as many as a meadow may hold.
private var thirtyTwo: [MeadowScenery.Thing] {
    (0..<32).map { k in lamp(k % 2 == 0 ? -28 - Float(k % 4) * 6 : 28 + Float(k % 4) * 6, -40 + Float(k / 4) * 13) }
}

@Suite struct LampModel {
    @Test("the lamp is drawn as a made thing: alone, worn round its foot, kept off the picnic ground, its glass marked")
    func model() {
        #expect(MeadowScenery.draws(lampID))
        #expect(SceneryCatalog.alone.contains(lampID) && SceneryCatalog.isTread(lampID) && !SceneryRules.isSmall(lampID))
        #expect(SceneryRules.isBig(lampID), "kept off the picnic ground")
        #expect(SceneryRules.Field(MeadowScenery()).refusal(for: lamp(0, 30)) == .keptForWorkspaces)
        #expect(SceneryRules.Field(MeadowScenery()).refusal(for: lamp(30, 30)) == nil)
        let shape = Lamps.post.shape
        let glass = shape.roughness.filter { $0 > 1.5 }.count
        #expect(glass > 0 && glass < shape.count / 4, "some of it, and only the glass, glows")
        #expect(shape.roughness.allSatisfy { $0 > 1.5 ? $0 - 2 >= 0 && $0 - 2 <= 1 : $0 >= 0 && $0 <= 1 })
        let b = shape.bounds
        #expect(b.max.y > 5 && b.max.y < 6.2, "a little over twice a cat's height")
        #expect(max(b.max.x - b.min.x, b.max.z - b.min.z) < 1.4 && b.min.y >= -0.01)
        #expect(Lamps.head.y > 4 && Lamps.head.y < b.max.y)
        #expect(shape.count < 12_000)
    }
}

@Suite struct LampLight {
    @Test("lamps are lit only once the sun is below the threshold: 2° down in the evening, out 1° up in the morning")
    func threshold() {
        func position(_ elevation: Double, evening: Bool) -> Sun.Position { Sun.Position(elevation: elevation, hourAngle: evening ? 80 : -80) }
        #expect(!Daylight.lampsLit(position(5, evening: true)))
        #expect(!Daylight.lampsLit(position(-1.9, evening: true)))
        #expect(Daylight.lampsLit(position(-2.1, evening: true)))
        #expect(Daylight.lampsLit(position(-30, evening: true)))
        #expect(Daylight.lampsLit(position(0.5, evening: false)), "still lit just after sunrise")
        #expect(!Daylight.lampsLit(position(1.1, evening: false)))
        // At fixed hours, and with the switch off.
        #expect(!Daylight.light(MeadowSettings(timeOfDay: .day)).lampsLit)
        #expect(Daylight.light(MeadowSettings(timeOfDay: .night)).lampsLit)
        #expect(Daylight.light(MeadowSettings(timeOfDay: .hour(19.6))).lampsLit, "dusk")
        #expect(!Daylight.light(MeadowSettings(timeOfDay: .hour(18))).lampsLit)
        #expect(!Daylight.light(MeadowSettings(timeOfDay: .night, effects: MeadowSettings.Effects.all.subtracting(.lamps))).lampsLit)
        // Following a real place's sun through a day: lit after sunset and until sunrise, never at noon.
        let place = MeadowPlace(latitude: 51.5, longitude: 0)
        var day = DateComponents(calendar: Calendar(identifier: .gregorian), timeZone: TimeZone(identifier: "UTC"), year: 2026, month: 6, day: 21, hour: 12)
        let noon = day.date!
        day.hour = 23
        let night = day.date!
        #expect(!Daylight.light(MeadowSettings(timeOfDay: .instant(noon), place: place)).lampsLit)
        #expect(Daylight.light(MeadowSettings(timeOfDay: .instant(night), place: place)).lampsLit)
    }

    @Test("the warm-up is staggered and the same every time: each lamp from where it stands, over half a minute")
    func staggered() {
        func run() -> [[Float]] {
            var lamps = MeadowLamps()
            lamps.lay(thirtyTwo.map { ($0.x, $0.z, Vec3($0.x, 4.4, $0.z)) })
            lamps.update(0, lit: false, steady: false)
            #expect(lamps.lamps.allSatisfy { $0.level == 0 })
            var levels: [[Float]] = []
            lamps.update(0.1, lit: true, steady: false)
            for _ in 0..<(30 * 12) {
                lamps.update(1.0 / 12, lit: true, steady: false)
                levels.append(lamps.lamps.map(\.level))
            }
            return levels
        }
        let a = run(), b = run()
        #expect(a == b, "deterministic")
        // Not all in one frame: the first lamp lights well before the last.
        let firstLit = a.firstIndex { $0.contains { $0 > 0 } }!, allLit = a.firstIndex { $0.allSatisfy { $0 == 1 } }!
        #expect(allLit - firstLit > 12 * 10, "spread over more than ten seconds")
        let starts = (0..<32).map { i in a.firstIndex { $0[i] > 0 }! }
        #expect(Set(starts).count > 20, "nearly every lamp in its own moment")
        #expect(a.last!.allSatisfy { $0 == 1 }, "all burning steadily after half a minute")
        // A stutter while warming: some lamp dims for a moment on its way up.
        let dips = (0..<32).contains { i in zip(a, a.dropFirst()).contains { $1[i] < $0[i] - 0.05 } }
        #expect(dips)
    }

    @Test("with Reduce Motion or the animation off they are simply lit or out, with no stutter; when first drawn too")
    func steady() {
        var lamps = MeadowLamps()
        lamps.lay([(10, 10, Vec3(10, 4.4, 10)), (40, 10, Vec3(40, 4.4, 10))])
        lamps.update(0, lit: true, steady: false)
        #expect(lamps.lamps.allSatisfy { $0.level == 1 }, "first drawn at night: lit at once")
        lamps.update(1.0 / 60, lit: false, steady: true)
        #expect(lamps.lamps.allSatisfy { $0.level == 0 })
        lamps.update(1.0 / 60, lit: true, steady: true)
        #expect(lamps.lamps.allSatisfy { $0.level == 1 })
        // Once burning, nothing changes from frame to frame: no flicker at rest.
        _ = lamps.takeChanged()
        for _ in 0..<120 { lamps.update(1.0 / 12, lit: true, steady: false) }
        #expect(lamps.takeChanged() == nil)
    }

    @Test("a lamp placed while the others warm up is lit at once and stays lit; one already there keeps warming")
    func placedWhileWarming() {
        var lamps = MeadowLamps()
        lamps.lay([(10, 10, Vec3(10, 4.4, 10))])
        lamps.update(0, lit: false, steady: false)
        lamps.update(0.1, lit: true, steady: false)
        lamps.update(0.1, lit: true, steady: false)
        let warming = lamps.lamps[0].level
        lamps.lay([(10, 10, Vec3(10, 4.4, 10)), (60, 10, Vec3(60, 4.4, 10))])
        #expect(lamps.lamps[0].level == warming && lamps.lamps[1].level == 1)
        for _ in 0..<12 { lamps.update(1.0 / 12, lit: true, steady: false) }
        #expect(lamps.lamps[1].level == 1, "never dims to warm up")
    }

    @Test("the light baked again in a region is the same as baking it whole")
    func regionBake() {
        var lamps = thirtyTwo.map { GroundMap.Lamp(x: $0.x, z: $0.z, level: 1) }
        lamps[3].level = 0.4
        var map = GroundMap()
        map.light(lamps, in: .whole)
        // One moved: its old and new ground baked again.
        let old = lamps[5]
        lamps[5].x += 7
        lamps[5].z -= 3
        let region = GroundMap.reached(by: old)!.union(GroundMap.reached(by: lamps[5])!)
        map.light(lamps, in: region)
        var fresh = GroundMap()
        fresh.light(lamps, in: .whole)
        #expect(map.light == fresh.light)
        #expect(region.columns.count * region.rows.count < GroundMap.side * GroundMap.side / 20, "only round the lamp")
    }

    @Test("a lamp's pool: full at its foot, falling smoothly, nothing past its reach; pools add to a whole at most")
    func pool() {
        #expect(GroundMap.pool(0) == 1)
        var last: Float = 1
        for r in stride(from: Float(0.25), through: GroundMap.lampReach, by: 0.25) {
            let p = GroundMap.pool(r)
            #expect(p < last)
            last = p
        }
        #expect(GroundMap.pool(GroundMap.lampReach) == 0 && GroundMap.pool(40) == 0)
        var map = GroundMap()
        map.light([GroundMap.Lamp(x: 0, z: 0, level: 1), GroundMap.Lamp(x: 0.5, z: 0, level: 1)], in: .whole)
        #expect(abs(map.lamplight(at: Vec2(0.25, 0)) - 1) < 0.01)
        #expect(map.lamplight(at: Vec2(40, 0)) == 0)
    }

    @Test("placing, moving and taking away a lamp bakes only its ground; the ghost lights its own spot")
    @MainActor func editing() {
        let m = Meadow(scenery: MeadowScenery(things: [lamp(30, 0), lamp(-30, 20)]))
        m.light(0, lit: true, steady: false, ghost: nil)
        _ = m.takeLightChanges()
        #expect(m.groundMap.lamplight(at: Vec2(30, 0)) > 0.9 && m.groundMap.lamplight(at: Vec2(0, 0)) == 0)
        // Moved.
        m.show(MeadowScenery(things: [lamp(36, 4), lamp(-30, 20)]))
        let moved = m.takeLightChanges()!
        #expect(moved == GroundMap.reached(by: .init(x: 30, z: 0, level: 1))!.union(GroundMap.reached(by: .init(x: 36, z: 4, level: 1))!))
        #expect(m.groundMap.lamplight(at: Vec2(36, 4)) > 0.9 && m.groundMap.lamplight(at: Vec2(30 - 8, 0)) < 0.05)
        var whole = GroundMap()
        whole.light([.init(x: 36, z: 4, level: 1), .init(x: -30, z: 20, level: 1)], in: .whole)
        #expect(m.groundMap.light == whole.light)
        // The ghost.
        m.light(1.0 / 60, lit: true, steady: false, ghost: lamp(60, 60))
        #expect(m.groundMap.lamplight(at: Vec2(60, 60)) > 0.9)
        m.light(1.0 / 60, lit: true, steady: false, ghost: nil)
        #expect(m.groundMap.lamplight(at: Vec2(60, 60)) == 0)
        // By day the ghost gives no light.
        m.light(1.0 / 60, lit: false, steady: true, ghost: lamp(60, 60))
        #expect(m.groundMap.lamplight(at: Vec2(60, 60)) == 0 && !m.lamps.shining)
    }

    @Test("a lamp a blanket comes over makes way as rooted things do, and its light goes with it")
    @MainActor func makesWay() {
        let m = Meadow(scenery: MeadowScenery(things: [lamp(30, 0)]))
        m.light(0, lit: true, steady: false, ghost: nil)
        #expect(m.groundMap.lamplight(at: Vec2(30, 0)) > 0.9)
        let blanket = [Vec4(30, 0, 3, 0)]
        m.light(1.0 / 60, lit: true, steady: false, ghost: nil, clearings: blanket, clearingCount: 1)
        #expect(m.lamps.lamps[0].standing == 0 && m.groundMap.lamplight(at: Vec2(30, 0)) == 0 && !m.lamps.shining)
        m.light(1.0 / 60, lit: true, steady: false, ghost: nil, clearings: blanket, clearingCount: 0)
        #expect(m.groundMap.lamplight(at: Vec2(30, 0)) > 0.9)
    }

    @Test("no more than 32 lamps are drawn, and each counts as a tall thing")
    @MainActor func limit() {
        let m = Meadow(scenery: MeadowScenery(things: thirtyTwo + [lamp(80, 80), lamp(90, 80)]))
        #expect(m.lamps.lamps.count == MeadowScenery.Limits.lamps)
        #expect(m.screens.count == 32)
        #expect(m.laid.suffix(2).allSatisfy { $0 == .none })
    }
}

@MainActor
@Suite(.serialized) struct LampLooks {
    /// A view of the meadow looking down at (x, z).
    func view(_ things: [MeadowScenery.Thing], time: MeadowSettings.TimeOfDay, weather: MeadowWeather? = nil, at spot: SIMD2<Float> = SIMD2(30, 0)) -> MeadowView {
        let view = MeadowView(frame: NSRect(x: 0, y: 0, width: 320, height: 200), mode: .meadow)
        view.settings = MeadowSettings(arrangement: .column, timeOfDay: time, weather: weather, effects: MeadowSettings.Effects.all.subtracting(.moonPhase))
        view.scenery = MeadowScenery(things: things)
        view.advance(seconds: 0.5)
        view.stage.camera.setView(CameraView(x: spot.x, z: spot.y, distance: 40, pitch: 1.0, bearing: 0))
        return view
    }

    func mean(_ view: MeadowView, _ image: CGImage, _ spot: SIMD2<Float>) throws -> SIMD3<Float> {
        let at = try #require(view.viewPoint(ofGround: spot))
        let bytes = try #require(image.dataProvider?.data as Data?), scale = CGFloat(image.width) / view.bounds.width
        let cx = Int(at.x * scale), cy = image.height - Int(at.y * scale)
        try #require((6..<(image.width - 6)).contains(cx) && (6..<(image.height - 6)).contains(cy), "\(spot) in the picture")
        var sum = SIMD3<Float>(repeating: 0)
        for y in (cy - 6)..<(cy + 6) {
            for x in (cx - 6)..<(cx + 6) {
                let i = y * image.bytesPerRow + x * 4
                sum += SIMD3(Float(bytes[i + 2]), Float(bytes[i + 1]), Float(bytes[i]))
            }
        }
        return sum / 144
    }

    @Test("lit ground near a lamp is brighter and warmer; far from it, and by day, the picture is as without the lamp")
    func ground() throws {
        let lit = view([lamp(30, 0)], time: .night), unlit = view([], time: .night)
        let a = try #require(lit.renderImage(width: 640, height: 400)), b = try #require(unlit.renderImage(width: 640, height: 400))
        let near = try mean(lit, a, SIMD2(33, 3)), without = try mean(unlit, b, SIMD2(33, 3))
        func light(_ c: SIMD3<Float>) -> Float { 0.2126 * c.x + 0.7152 * c.y + 0.0722 * c.z }
        #expect(light(near) > light(without) * 1.6, "near \(near), without \(without)")
        #expect(near.x - near.z > without.x - without.z + 10, "warmer: \(near) against \(without)")
        let far = try mean(lit, a, SIMD2(30 + 17, 0)), farWithout = try mean(unlit, b, SIMD2(30 + 17, 0))
        #expect(simd_length(far - farWithout) < 2, "unchanged past its reach: \(far) against \(farWithout)")
        #expect(!ShaderSource.all.contains("for (int i = 0; i < 32"), "no loop over lamps")
    }

    @Test("by day an unlit lamp changes nothing but where it stands: the picture beside it is the same")
    func day() throws {
        let lit = view([lamp(30, 0)], time: .day), plain = view([], time: .day)
        #expect(!lit.stage.meadow!.lamps.shining)
        let a = try #require(lit.renderImage(width: 640, height: 400)), b = try #require(plain.renderImage(width: 640, height: 400))
        // Away from the lamp itself (and its trodden foot) every pixel is the same.
        for spot in [SIMD2<Float>(34, 3), SIMD2(26, -3), SIMD2(30, 5)] {
            #expect(try mean(lit, a, spot) == mean(plain, b, spot), "\(spot)")
        }
    }
}

@MainActor
@Suite(.serialized) struct LampsRest {
    final class Clock { var now: CFTimeInterval = 1000 }

    /// Frames as the display link would give them, each at the rate the view asks for.
    func run(_ view: MeadowView, _ clock: Clock, seconds: Double) {
        var left = seconds
        while left > 0 {
            let dt = 1 / Double(view.targetRate)
            clock.now += dt
            left -= dt
            view.step(Float(dt))
            view.updateRate()
        }
    }

    @Test("a still night meadow with 32 lit lamps rests at the slow tick, warming up or burning; then nothing is baked again")
    func rests() {
        let clock = Clock()
        let view = MeadowView(frame: NSRect(x: 0, y: 0, width: 360, height: 800), mode: .meadow)
        view.clock = { clock.now }
        view.keepsFullRateWhenInactive = true
        view.settings = MeadowSettings(arrangement: .column, timeOfDay: .day)
        view.scenery = MeadowScenery(things: thirtyTwo)
        run(view, clock, seconds: 1)
        // Dusk falls: the lamps begin to come on one by one, and the meadow still rests while they do.
        view.settings = MeadowSettings(arrangement: .column, timeOfDay: .night)
        run(view, clock, seconds: Double(MeadowView.restAfter) + 4)
        let m = view.stage.meadow!
        #expect(view.isResting && view.targetRate == MeadowView.restRate)
        #expect(m.lamps.lamps.contains { $0.level < 1 }, "still warming up: they take about a minute at rest")
        run(view, clock, seconds: 70)
        #expect(m.lamps.lamps.allSatisfy { $0.level == 1 })
        #expect(view.isResting && view.targetRate == MeadowView.restRate)
        _ = m.takeLightChanges()
        run(view, clock, seconds: 5)
        #expect(m.takeLightChanges() == nil, "burning steadily: nothing to bake")
    }
}

// MARK: Pictures (MEADOW_SNAPSHOTS)

/// Pictures of the lamps for looking at: close up by day, at dusk and by night; a composed night meadow; rain and
/// snow at night; a sidebar's view. Written only when MEADOW_SNAPSHOTS names a folder.
@MainActor
@Suite(.serialized) struct LampPictures {
    nonisolated static let folder = CatalogPictures.folder

    static func view(_ scenery: MeadowScenery, time: MeadowSettings.TimeOfDay, weather: MeadowWeather? = nil, world: MeadowWorld? = nil,
                     size: NSSize = NSSize(width: 480, height: 360), arrangement: MeadowSettings.Arrangement = .column) -> MeadowView {
        let view = MeadowView(frame: NSRect(origin: .zero, size: size), mode: .meadow)
        view.settings = MeadowSettings(arrangement: arrangement, timeOfDay: time, weather: weather, effects: MeadowSettings.Effects.all.subtracting(.moonPhase))
        view.scenery = scenery
        if let world { view.world = world }
        view.advance(seconds: 1.5)
        return view
    }

    /// A garden corner: a path between lamps, stepping stones to a bench-like stump, trees behind, flowers.
    static var garden: MeadowScenery {
        var ground = MeadowScenery.Ground()
        for k in 0..<160 {
            let z = -30 + Float(k) * 0.35, x = 34 + 3 * sin(z * 0.08)
            for dx in stride(from: Float(-1.3), through: 1.3, by: 0.4) {
                if let cell = MeadowScenery.Ground.cell(at: x + dx, z) { ground[cell.column, cell.row] = .path }
            }
        }
        var things = [lamp(31, -14), lamp(38.5, -2, turn: 0.4), lamp(29, 6, turn: 1.1),
                      MeadowScenery.Thing(id: "tree.oak", x: 50, z: -26, seed: 3), MeadowScenery.Thing(id: "tree.cherry", x: 22, z: -24, seed: 5),
                      MeadowScenery.Thing(id: "tree.birch", x: 56, z: -8, seed: 9), MeadowScenery.Thing(id: "wood.stump", x: 44, z: -6),
                      MeadowScenery.Thing(id: "stone.mossy", x: 26, z: 2, size: Vec3(repeating: 1.2)),
                      MeadowScenery.Thing(id: "work.cushion", x: 25, z: -8, turn: 0.3), MeadowScenery.Thing(id: "cat.bed", x: 41, z: -14)]
        for k in 0..<4 { things.append(MeadowScenery.Thing(id: "stone.stepping", x: 37 + Float(k) * 1.6, z: -5.5 + Float(k) * 0.4, turn: 0.3)) }
        for k in 0..<14 {
            let a = Float(k) * 2.4, out = 2 + Float(k % 5)
            things.append(MeadowScenery.Thing(id: k % 3 == 0 ? "flower.poppy" : "flower.daisy", x: 27 + cos(a) * out, z: -20 + sin(a) * out, turn: a))
        }
        return MeadowScenery(things: things, ground: ground)
    }

    static func shot(_ view: MeadowView, x: Float, z: Float, distance: Float, pitch: Float, bearing: Float = 0.45, size: (Int, Int) = (480, 360)) -> CGImage? {
        view.stage.camera.setView(CameraView(x: x, z: z, distance: distance, pitch: pitch, bearing: bearing))
        return view.renderImage(width: size.0, height: size.1)
    }

    @Test(.enabled(if: folder != nil)) func closeUp() {
        var pictures: [(String, CGImage)] = []
        for (mood, time) in CatalogPictures.moods {
            let view = Self.view(MeadowScenery(things: [lamp(30, 0, turn: 0.5)]), time: time)
            if let image = Self.shot(view, x: 30, z: 0, distance: 19, pitch: 0.28) { pictures.append(("lamp, \(mood)", image)) }
            if let image = Self.shot(view, x: 30, z: 0, distance: 45, pitch: 0.95) { pictures.append(("from above, \(mood)", image)) }
        }
        CatalogPictures.sheet(pictures, columns: 2, to: "lamps-close")
    }

    @Test(.enabled(if: folder != nil)) func nightGarden() {
        var pictures: [(String, CGImage)] = []
        for (mood, time) in CatalogPictures.moods {
            let view = Self.view(Self.garden, time: time, world: Scenes.busy(), size: NSSize(width: 720, height: 450))
            if let image = Self.shot(view, x: 26, z: -3, distance: 46, pitch: 0.55, bearing: 0.25, size: (720, 450)) { pictures.append(("garden, \(mood)", image)) }
        }
        let rain = MeadowWeather(sky: .rain, cover: 1, windKmh: 8, temperatureC: 9, intensity: 0.6)
        let snow = MeadowWeather(sky: .snow, cover: 1, windKmh: 4, temperatureC: -2, intensity: 0.6)
        let fog = MeadowWeather(sky: .fog, cover: 1, windKmh: 2, temperatureC: 6)
        for (name, weather) in [("rain", rain), ("snow", snow), ("fog", fog)] {
            let view = Self.view(Self.garden, time: .night, weather: weather, world: Scenes.busy(), size: NSSize(width: 720, height: 450))
            if let image = Self.shot(view, x: 26, z: -3, distance: 46, pitch: 0.55, bearing: 0.25, size: (720, 450)) { pictures.append(("garden, night, \(name)", image)) }
        }
        CatalogPictures.sheet(pictures, columns: 2, to: "lamps-garden")
    }

    @Test(.enabled(if: folder != nil)) func sidebar() {
        // A sidebar's column at night with lamps along the picnic ground's edges, as a person might set them.
        let things = (0..<6).flatMap { k in [lamp(-21.5, Float(k) * 14), lamp(21.5, Float(k) * 14 + 7)] }
        let view = Self.view(MeadowScenery(things: things + MeadowScenery.standard.things), time: .night, world: Scenes.busy(), size: NSSize(width: 300, height: 760))
        view.frame(nil, besidePanelWidth: 0, animated: false)
        view.advance(seconds: 2)
        if let image = view.renderImage(width: 600, height: 1520) { CatalogPictures.sheet([("sidebar, night", image)], columns: 1, to: "lamps-sidebar") }
    }
}
