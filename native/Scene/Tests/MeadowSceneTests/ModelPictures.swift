import AppKit
import Foundation
import Testing
import simd
@_spi(Diagnostics) @testable import MeadowScene

// MARK: Pictures (MODEL_PICTURES)

/// Every model but the trees as people see it, for looking at: from the editor's own framing (about 55° above, a
/// blanket and its cats beside it for scale), from a sidebar's steep column at a sidebar's size, and a three-quarter
/// close-up, by day, at dusk and by night; the picnic's things on their blankets, the critters, and a cat in each
/// way it roams and uses a thing, from the same cameras. Written only when MODEL_PICTURES names a folder; the same
/// cameras every time, so pictures from two versions compare side by side.
@MainActor
@Suite(.serialized) struct ModelPictures {
    nonisolated static let folder = ProcessInfo.processInfo.environment["MODEL_PICTURES"]

    /// The models, by the shelf they are found on.
    nonisolated static let shelves: [(String, [String])] = [
        ("flowers", ["flower.daisy", "flower.buttercup", "flower.lupin", "flower.poppy", "flower.cornflower", "flower.foxglove"]),
        ("plants", ["plant.fern", "plant.clover", "fungus.flyAgaric"]),
        ("stones-wood", ["stone.stone", "stone.mossy", "stone.boulder", "stone.stepping", "wood.fallenLog", "wood.stump", "wood.logPile"]),
        ("cat-things", ["cat.box", "cat.scratchingPost", "cat.yarn", "cat.bed", "cat.bowl"]),
        ("workplace", ["work.cushion", "work.desk", "work.bookshelf", "work.bench", "work.signpost", "work.mailbox", "work.noticeboard", "work.lampPost"]),
        ("garden", ["garden.flowerPot", "garden.planter", "garden.wateringCan", "garden.birdhouse", "garden.skep", "place.shed", "place.tent", "garden.fence"]),
        ("parcel", [MeadowScenery.parcel]),
    ]

    /// A thing where it stands for its pictures: a plant as the Brush lays them (a loose clump round the one in
    /// the middle), a fence a short run with its gate, anything else alone.
    static func things(_ id: String, at spot: SIMD2<Float>) -> [MeadowScenery.Thing] {
        if id == "garden.fence" {
            return [MeadowScenery.Thing(id: id, points: [spot + SIMD2(-7, 2), spot + SIMD2(0, 2), spot + SIMD2(4, -3)], gate: 1)]
        }
        if id == "stone.stepping" {
            return (0..<4).map { k in MeadowScenery.Thing(id: id, x: spot.x - 2.4 + Float(k) * 1.6, z: spot.y + 0.4 * sin(Float(k)), turn: Float(k) * 0.7) }
        }
        var things = [MeadowScenery.Thing(id: id, x: spot.x, z: spot.y, turn: 0.4, seed: 7)]
        guard SceneryRules.isSmall(id) else { return things }
        for k in 1..<8 {
            let a = Float(k) * 2.4, out = 0.9 + 0.35 * Float(k)
            things.append(MeadowScenery.Thing(id: id, x: spot.x + cos(a) * out, z: spot.y + sin(a) * out, turn: a, size: Vec3(repeating: 0.85 + 0.04 * Float(k % 4))))
        }
        return things
    }

    static func editor(_ things: [MeadowScenery.Thing], time: MeadowSettings.TimeOfDay = .day) -> MeadowView {
        TreePictures.editor(MeadowScenery(things: things), time: time)
    }

    /// Where a thing stands in the editor's pictures: on the grass a little way out from the first blanket, toward
    /// where the trees' pictures stand theirs, so the blanket and its cats are in the picture for scale.
    static let spot: SIMD2<Float> = {
        let view = Self.editor([])
        guard let plot = view.stage.village?.plot("b0") else { return TreePictures.spot }
        let middle = SIMD2(plot.middle.x, plot.middle.z), way = simd_normalize(TreePictures.spot - middle)
        return middle + way * (plot.radius + 4.5)
    }()

    /// The editor's picture round the thing: as large as the editor shows it, the blanket's edge in view.
    static func editorCrop(_ view: MeadowView, at spot: SIMD2<Float>) -> CGImage? {
        guard let image = Self.image(view) else { return nil }
        return TreePictures.crop(view, image, at: spot, w: 200, h: 150, below: 55)
    }

    /// A sidebar's column of three workspaces at a sidebar's size, the thing set on the grass beside the first.
    static func sidebar(_ id: String, time: MeadowSettings.TimeOfDay = .day) -> (MeadowView, SIMD2<Float>)? {
        let view = MeadowView(frame: NSRect(x: 0, y: 0, width: 300, height: 820), mode: .meadow)
        view.settings = MeadowSettings(arrangement: .column, timeOfDay: time, effects: MeadowSettings.Effects.all.subtracting(.moonPhase), picnic: .hamper)
        view.world = TreePictures.world(3)
        view.advance(seconds: 0.5)
        view.frame(nil, besidePanelWidth: 0, animated: false)
        view.advance(seconds: 0.5)
        guard let plot = view.stage.village?.plots.first else { return nil }
        // Beside the first blanket, toward the camera's left, where a column leaves grass in view.
        let spot = SIMD2(plot.middle.x - plot.radius - (SceneryRules.isBig(id) ? 3.6 : 2.4), plot.middle.z + plot.radius * 0.9)
        view.scenery = MeadowScenery(things: things(id, at: spot))
        view.advance(seconds: 3)
        return (view, spot)
    }

    static func image(_ view: MeadowView) -> CGImage? { view.renderImage(width: Int(view.bounds.width * 2), height: Int(view.bounds.height * 2)) }

    /// A three-quarter close-up: the camera low and to one side, the whole thing in view.
    static func close(_ view: MeadowView, at spot: SIMD2<Float>, tall: Float) -> CGImage? {
        view.stage.camera.setView(CameraView(x: spot.x, z: spot.y, distance: max(8, tall * 3.4), pitch: 0.62, bearing: 0.45))
        view.advance(seconds: 0.1)
        return view.renderImage(width: 600, height: 450)
    }

    static func tall(_ id: String) -> Float {
        guard let shape = id == "wood.fallenLog" ? SceneryCatalog.fallenLog : Meadow.alone(MeadowScenery.Thing(id: id, x: 0, z: 0)).map({ $0.make() }) else { return 4 }
        let b = shape.bounds
        return max(b.max.y, (b.max.x - b.min.x) * 0.6, (b.max.z - b.min.z) * 0.6)
    }

    @Test(.enabled(if: folder != nil)) func models() {
        let spot = Self.spot
        for (shelf, ids) in Self.shelves {
            var editor: [(String, CGImage)] = [], zoom: [(String, CGImage)] = [], side: [(String, CGImage)] = [], close: [(String, CGImage)] = []
            var dusk: [(String, CGImage)] = [], night: [(String, CGImage)] = []
            for id in ids {
                let view = Self.editor(Self.things(id, at: spot))
                if let c = Self.editorCrop(view, at: spot) { editor.append((id, c)) }
                // The same framing drawn at twice a Retina screen's density, to look closely at what it shows.
                if let image = view.renderImage(width: Int(TreePictures.window.width * 4), height: Int(TreePictures.window.height * 4)),
                   let c = TreePictures.crop(view, image, at: spot, w: 100, h: 75, below: 26) { zoom.append((id, c)) }
                // Close up, one alone (a plant out of its clump).
                let one = Self.editor(Array(Self.things(id, at: spot).prefix(id == "stone.stepping" ? 4 : 1)))
                if let image = Self.close(one, at: spot, tall: Self.tall(id)) { close.append((id, image)) }
                for (time, into) in [(MeadowSettings.TimeOfDay.hour(19.6), 0), (.night, 1)] {
                    let v = Self.editor(Self.things(id, at: spot), time: time)
                    guard let c = Self.editorCrop(v, at: spot) else { continue }
                    if into == 0 { dusk.append((id, c)) } else { night.append((id, c)) }
                }
                if let (v, at) = Self.sidebar(id), let image = Self.image(v), let c = TreePictures.crop(v, image, at: at, w: 220, h: 220, below: 90) {
                    side.append((id, c))
                }
            }
            CatalogPictures.sheet(editor, columns: 4, to: "\(shelf)-editor", in: Self.folder)
            CatalogPictures.sheet(zoom, columns: 4, to: "\(shelf)-editor-zoom", in: Self.folder)
            CatalogPictures.sheet(dusk, columns: 4, to: "\(shelf)-editor-dusk", in: Self.folder)
            CatalogPictures.sheet(night, columns: 4, to: "\(shelf)-editor-night", in: Self.folder)
            CatalogPictures.sheet(side, columns: 4, to: "\(shelf)-sidebar", in: Self.folder)
            CatalogPictures.sheet(close, columns: 4, to: "\(shelf)-close", in: Self.folder)
        }
    }

    /// One whole sidebar with a few of the things beside its blankets, as small as the sidebar shows them.
    @Test(.enabled(if: folder != nil)) func sidebars() {
        var pictures: [(String, CGImage)] = []
        for id in ["wood.logPile", "plant.fern", "cat.bed", "place.tent", "work.cushion", "stone.mossy"] {
            if let (v, _) = Self.sidebar(id), let image = Self.image(v) { pictures.append((id, image)) }
        }
        CatalogPictures.sheet(pictures, columns: 6, to: "sidebar-whole", in: Self.folder)
    }

    /// The picnic's own things on their blankets: the hamper and what is unpacked from it, a lantern, a flag, and a
    /// plain terminal's camp kettle on its stove, idle and boiling.
    @Test(.enabled(if: folder != nil)) func picnic() {
        let world = MeadowWorld(machines: [MeadowMachine(id: "m", name: "m", spaces: [MeadowSpace(id: "s", name: "s", blankets: [
            MeadowBlanket(id: "cat", title: "cat", color: .account(0), agents: [MeadowAgent(id: "main", activity: .reading)]),
            MeadowBlanket(id: "shell", title: "shell", color: MeadowColor(hex: 0xa9a9ae), lanterns: [MeadowLantern(id: "t0", title: "zsh", state: .running, command: .running)]),
            MeadowBlanket(id: "two", title: "two", color: .account(1), agents: [MeadowAgent(id: "main", activity: .idle)]),
        ])])])
        var pictures: [(String, CGImage)] = []
        for (mood, time) in CatalogPictures.moods {
            for spread in [MeadowSettings.Picnic.hamper, .spread] {
                let view = MeadowView(frame: NSRect(x: 0, y: 0, width: 1440, height: 900), mode: .meadow)
                view.settings = MeadowSettings(timeOfDay: time, effects: MeadowSettings.Effects.all.subtracting(.moonPhase), picnic: spread)
                view.world = world
                view.advance(seconds: 0.5)
                view.frame(nil, besidePanelWidth: 0, animated: false)
                view.advance(seconds: 4)
                for id in ["cat", "shell"] {
                    guard let plot = view.stage.village?.plot(id) else { continue }
                    let at = SIMD2(plot.middle.x, plot.middle.z)
                    if let image = Self.image(view), let c = TreePictures.crop(view, image, at: at, w: 360, h: 260, below: 130) { pictures.append(("\(id) \(spread) \(mood), overview", c)) }
                    view.stage.camera.setView(CameraView(x: at.x, z: at.y, distance: 16, pitch: 0.5, bearing: 0.45))
                    view.advance(seconds: 0.05)
                    if let image = view.renderImage(width: 720, height: 520) { pictures.append(("\(id) \(spread) \(mood), close", image)) }
                    view.frame(nil, besidePanelWidth: 0, animated: false)
                    view.advance(seconds: 0.05)
                }
            }
        }
        CatalogPictures.sheet(pictures, columns: 4, to: "picnic", in: Self.folder)
        // As a sidebar shows them.
        var side: [(String, CGImage)] = []
        for (mood, time) in CatalogPictures.moods {
            let view = MeadowView(frame: NSRect(x: 0, y: 0, width: 300, height: 820), mode: .meadow)
            view.settings = MeadowSettings(arrangement: .column, timeOfDay: time, effects: MeadowSettings.Effects.all.subtracting(.moonPhase), picnic: .spread)
            view.world = world
            view.advance(seconds: 0.5)
            view.frame(nil, besidePanelWidth: 0, animated: false)
            view.advance(seconds: 4)
            if let image = Self.image(view) { side.append((mood, image)) }
        }
        CatalogPictures.sheet(side, columns: 3, to: "picnic-sidebar", in: Self.folder)
    }

    /// Butterflies and bees on a bed of flowers, a ladybird on a blanket, fireflies at night.
    @Test(.enabled(if: folder != nil)) func critters() {
        var things: [MeadowScenery.Thing] = []
        for (k, id) in ["flower.daisy", "flower.poppy", "flower.lupin", "flower.cornflower", "flower.buttercup", "plant.clover"].enumerated() {
            things += Self.things(id, at: SIMD2(8 + Float(k % 3) * 4, -10 - Float(k / 3) * 4))
        }
        var pictures: [(String, CGImage)] = []
        for (mood, time) in [("day", MeadowSettings.TimeOfDay.day), ("night", .night)] {
            let view = Self.editor(things, time: time)
            view.endEditing()
            view.advance(seconds: 25)
            for (label, distance, pitch) in [("editor", Float(60), Float(0.96)), ("close", 14, 0.45)] {
                view.stage.camera.setView(CameraView(x: 12, z: -12, distance: distance, pitch: pitch, bearing: 0.3))
                view.advance(seconds: 0.05)
                if let image = view.renderImage(width: 900, height: 600) { pictures.append(("\(mood), \(label)", image)) }
            }
            if let plot = view.stage.village?.plots.first {
                view.stage.camera.setView(CameraView(x: plot.ladybird.x, z: plot.ladybird.z, distance: 9, pitch: 0.9, bearing: 0.3))
                view.advance(seconds: 0.02)
                if let image = view.renderImage(width: 900, height: 600) { pictures.append(("\(mood), ladybird", image)) }
            }
        }
        CatalogPictures.sheet(pictures, columns: 3, to: "critters", in: Self.folder)
    }

    // MARK: A cat out in the grass

    /// The editor's and the sidebar's cameras as each frames its own meadow (how far back, how steep, turned
    /// how far), so a cat at a thing can be seen from each as it would be there.
    static let editorCamera: CameraView = {
        let v = Self.editor([]).cameraView
        return CameraView(x: v.x, z: v.z, distance: v.distance, pitch: v.pitch, bearing: v.bearing)
    }()
    static let sidebarCamera: CameraView = {
        let view = MeadowView(frame: NSRect(x: 0, y: 0, width: 300, height: 820), mode: .meadow)
        view.settings = MeadowSettings(arrangement: .column, timeOfDay: .day, picnic: .hamper)
        view.world = TreePictures.world(3)
        view.advance(seconds: 0.5)
        view.frame(nil, besidePanelWidth: 0, animated: false)
        view.advance(seconds: 3)
        let v = view.cameraView
        return CameraView(x: v.x, z: v.z, distance: v.distance, pitch: v.pitch, bearing: v.bearing)
    }()

    /// The cat as the editor, a sidebar and a close look show it, wherever it is now.
    static func shots(_ view: MeadowView, _ actor: Actor, _ name: String, into pictures: inout [(String, CGImage)]) {
        let at = SIMD2(actor.cat.position.x, actor.cat.position.z)
        // A sidebar's view is 820 points tall and the editor's 900: the same distance shows the cat the same size
        // when the picture is as tall as each view; both are rendered here in this view's size, then cropped.
        for (label, camera, size) in [("editor", Self.editorCamera, CGFloat(900)), ("sidebar", Self.sidebarCamera, 820)] {
            view.stage.camera.setView(CameraView(x: at.x, z: at.y, distance: camera.distance * Float(view.bounds.height / size), pitch: camera.pitch, bearing: camera.bearing))
            view.advance(seconds: 1.0 / 120)
            if let image = Self.image(view), let c = TreePictures.crop(view, image, at: at, w: 160, h: 140, below: 60) { pictures.append(("\(name), \(label)", c)) }
        }
        view.stage.camera.setView(CameraView(x: at.x, z: at.y, distance: 10, pitch: 0.45, bearing: 0.45))
        view.advance(seconds: 1.0 / 120)
        if let image = view.renderImage(width: 320, height: 280) { pictures.append(("\(name), close", image)) }
    }

    /// A cat walking, mid-hop and running home, and at each thing that invites one: sitting on a stump, a boulder, a
    /// bench, in a box, napping in a bed and on a cushion, scratching at a post, at its bowl.
    @Test(.enabled(if: folder != nil)) func cats() {
        var pictures: [(String, CGImage)] = []
        do {
            let view = CatAfternoons.view([])
            let actor = Roaming.actor(view)
            Roaming.setOutNow(view)
            if CatAfternoons.until(view, 120, { actor.roam.phase == .travelling && actor.roam.gait == .walk && simd_distance(actor.rootLocal, actor.spot) > 3 }) {
                Self.shots(view, actor, "walk", into: &pictures)
            }
            if CatAfternoons.until(view, 240, { actor.roam.gait == .bound && actor.roam.phase == .travelling && actor.cat.height > 0.5 }) { Self.shots(view, actor, "hop", into: &pictures) }
            _ = CatAfternoons.until(view, 60) { actor.roam.out && simd_distance(actor.rootLocal, actor.spot) > 4 }
            view.world = CatAfternoons.alone(.reading)
            if CatAfternoons.until(view, 2, { actor.roam.phase == .recalled && actor.roam.ramp > 0.8 }) { Self.shots(view, actor, "run home", into: &pictures) }
        }
        let spots: [(String, Bool)] = [("wood.stump", false), ("stone.boulder", false), ("work.bench", false), ("cat.box", false), ("cat.scratchingPost", false),
                                       ("cat.bowl", false), ("cat.bed", true), ("work.cushion", true)]
        for (id, nap) in spots {
            let view = CatAfternoons.view([(id, CatAfternoons.front(SceneryRules.isBig(id) ? 7.6 : 6.6, 1.0))])
            let actor = Roaming.actor(view)
            Roaming.setOutNow(view)
            if nap {
                _ = CatAfternoons.until(view, 60) { actor.roam.phase == .stopped && simd_distance(actor.rootLocal, actor.spot) > 1.5 }
                view.world = CatAfternoons.alone(.napping)
                view.stage.village!.letCatsDozeOff()
                guard CatAfternoons.until(view, 60, { actor.roam.phase == .asleep && CatAfternoons.place(view, actor)?.id == id }) else { continue }
            } else {
                guard CatAfternoons.until(view, 240, { actor.roam.phase == .stopped && CatAfternoons.place(view, actor)?.id == id }) else { continue }
            }
            view.advance(seconds: 0.8)
            Self.shots(view, actor, id, into: &pictures)
        }
        CatalogPictures.sheet(pictures, columns: 6, to: "cats", in: Self.folder)
    }
}
