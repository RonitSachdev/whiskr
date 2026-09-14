import AppKit
import Foundation
import Testing
import simd
@testable import MeadowScene

// What the app's sidebar asks of the meadow beyond laying it out (`ColumnTests`): flags that carry the
// branch and a pin and never meet, bubbles that never cover a face or a flag's name, bringing a blanket
// into view, saying what is out of view and where things are, and the keyboard's focus.

@MainActor
enum Sidebar {
    /// Workspaces in every state, with long names and branches when asked; `seed` turns every cat a
    /// different way (cats sit and turn by their ids).
    static func world(_ count: Int = 5, long: Bool = false, seed: String = "") -> MeadowWorld {
        let states: [[MeadowAgent]] = [
            [MeadowAgent(id: "c" + seed, activity: .running, needsYou: true)],
            [MeadowAgent(id: "c" + seed, activity: .error, failed: true)],
            [MeadowAgent(id: "c" + seed, activity: .awake, doneUnseen: true)],
            [MeadowAgent(id: "c" + seed, activity: .reading)],
            [MeadowAgent(id: "c" + seed, activity: .napping)],
        ]
        return MeadowWorld(machines: [MeadowMachine(id: "m", name: "m", spaces: (0..<count).map { i in
            MeadowSpace(id: "w\(i)", name: "w\(i)", blankets: [
                MeadowBlanket(id: "w\(i)", title: long ? "the-meadow-cats-native-\(i)-sidebar" : "w\(i)", color: .account(i),
                              agents: states[i % states.count], detail: long ? "feature/longer-branch-name-\(i)" : "main", pinned: i == 0),
            ])
        })])
    }

    static func view(_ size: NSSize, _ world: MeadowWorld, time: MeadowSettings.TimeOfDay = .day, after: Double = 2) -> MeadowView {
        let view = MeadowView(frame: NSRect(origin: .zero, size: size), mode: .meadow)
        view.settings = MeadowSettings(arrangement: .column, timeOfDay: time, picnic: .hamper)
        view.world = world
        view.advance(seconds: 0.5)
        view.frame(nil, besidePanelWidth: 0, animated: false)
        view.advance(seconds: after)
        return view
    }

    nonisolated static let narrow = NSSize(width: 300, height: 820)
    nonisolated static let wide = NSSize(width: 900, height: 820)
}

@MainActor
@Suite(.serialized) struct FlagLabels {
    func label(_ name: String, detail: String? = nil, pinned: Bool = false, room: Float = FlagLabel.roomMost) -> FlagLabel {
        var label = FlagLabel()
        label.update(FlagLabel.Inputs(name: name, detail: detail, pinned: pinned, color: .account(0), room: room))
        return label
    }

    @Test("long names and branches lose their middle, at 22 and 18 characters")
    func middleTruncation() {
        #expect(FlagLabel.middle("the-meadow-cats-native-app", 22) == "the-meadow-…native-app")
        #expect(FlagLabel.middle("shop-web", 22) == "shop-web")
        let l = label("the-meadow-cats-native-app", detail: "feature/fix-cart-rounding-errors")
        #expect(l.shown == "the-meadow-…native-app")
        #expect(l.shownDetail?.count == 18)
        #expect(l.shownDetail?.hasPrefix("feature/") == true && l.shownDetail?.hasSuffix("errors") == true)
    }

    @Test("the branch follows the title; a pin goes first; no branch, no glyph")
    func layout() {
        let plain = label("shop-web"), branched = label("shop-web", detail: "fix-cart"), pinned = label("shop-web", detail: "fix-cart", pinned: true)
        #expect(plain.shownDetail == nil)
        #expect(branched.shownDetail == "fix-cart")
        #expect(branched.glyphX > branched.titleX && branched.detailX > branched.glyphX)
        #expect(branched.aspect > plain.aspect)
        #expect(pinned.dotX > branched.dotX && pinned.aspect > branched.aspect)
        #expect(label("shop-web", detail: "").shownDetail == nil)
    }

    @Test("a branch short of room gives up its folders before its middle")
    func branchKeepsItsName() {
        let full = label("shop-web", detail: "feature/checkout")
        #expect(full.shownDetail == "feature/checkout")
        // Just too narrow for the whole branch.
        let wide = (Float(full.canvas.width) - Float(FlagLabel.shadow * 2)) / Float(FlagLabel.scale) * Float(FlagLabel.onScreen)
        let short = label("shop-web", detail: "feature/checkout", room: (wide - 4).rounded(.down))
        #expect(short.shown == "shop-web")
        #expect(short.shownDetail == "…/checkout")
        // A branch with no folders is cut in its middle, as before.
        #expect(label("shop-web", detail: "fix-the-cart-rounding", room: 150).shownDetail?.contains("…") == true)
    }

    @Test("a narrow pill cuts the branch, then the title, then leaves the branch out, and always fits", arguments: [300, 200, 140, 90] as [Float])
    func fitsItsRoom(_ room: Float) {
        let l = label("the-meadow-cats-native-app", detail: "feature/fix-cart-rounding-errors", pinned: true, room: room)
        let wide = Float(l.canvas.width) - Float(FlagLabel.shadow * 2)
        // The pill's width on screen, in points.
        #expect(wide / Float(FlagLabel.scale) * Float(FlagLabel.onScreen) <= room + 1, "room \(room): \(l.shown) \(l.shownDetail ?? "")")
        if l.shown.count < 22, let detail = l.shownDetail { #expect(detail.count == FlagLabel.fewest, "the branch is cut before the title") }
    }
}

@MainActor
@Suite(.serialized) struct SidebarFlags {
    @Test("flags never meet a neighbour's and stay inside the view, long names and branches included",
          arguments: [NSSize(width: 300, height: 820), NSSize(width: 605, height: 860), NSSize(width: 900, height: 820), NSSize(width: 1440, height: 860)])
    func neverOverlap(_ size: NSSize) {
        let view = Sidebar.view(size, Sidebar.world(8, long: true))
        let village = view.stage.village!
        let boxes = village.plots.compactMap { village.flagBox($0, view.stage) }
        #expect(boxes.count == 8)
        for (i, a) in boxes.enumerated() {
            #expect(a.left >= 0 && a.right <= Float(size.width), "flag \(i) runs off the view: \(a)")
            for b in boxes[(i + 1)...] {
                let apart = a.right <= b.left || b.right <= a.left || a.bottom <= b.top || b.bottom <= a.top
                #expect(apart, "flags overlap: \(a) and \(b)")
            }
        }
    }
}

@MainActor
@Suite(.serialized) struct SidebarBubbles {
    /// Every bubble on screen: its disc (centre, radius), its cat's face (both eyes, and the middle of the
    /// face with half the head's reach round it) and its blanket.
    func bubbles(_ view: MeadowView) -> [(disc: Vec2, r: Float, face: [(Vec2, Float)], plot: Plot)] {
        let stage = view.stage, village = stage.village!
        var found: [(Vec2, Float, [(Vec2, Float)], Plot)] = []
        for plot in village.plots {
            for actor in plot.liveActors where actor.cat.bubbleShown {
                let b = actor.cat.bubbleDrawn, at = Vec3(b.x, b.y, b.z)
                let c = stage.screen(at), e = stage.screen(at + stage.surroundings.up * (b.w * CatDrawer.bubbleDisc / 2))
                var face = [actor.cat.eyeWhites.0, actor.cat.eyeWhites.1].map { m -> (Vec2, Float) in
                    let s = stage.screen(Vec3(m.columns.3.x, m.columns.3.y, m.columns.3.z)); return (Vec2(s.x, s.y), 2)
                }
                let middle = stage.screen(actor.cat.face), edge = stage.screen(actor.cat.face + stage.surroundings.up * actor.cat.faceReach)
                face.append((Vec2(middle.x, middle.y), hypot(edge.x - middle.x, edge.y - middle.y) * 0.5))
                found.append((Vec2(c.x, c.y), hypot(e.x - c.x, e.y - c.y), face, plot))
            }
        }
        return found
    }

    @Test("a bubble never covers its cat's face nor any flag, whichever way the cat sits, in a sidebar and in rows",
          arguments: [Sidebar.narrow, Sidebar.wide])
    func clearOfFaceAndFlags(_ size: NSSize) {
        var checked = 0
        // Ids as the app gives them (UUIDs), each sitting and turning its own way.
        let seeds = [""] + (0..<11).map { k in String(format: "-%08x-4d84-4ef4-b341-4863c889a37c", k &* 0x9e3779b1) }
        for seed in seeds {
            let view = Sidebar.view(size, Sidebar.world(seed: seed), after: 3)
            let village = view.stage.village!
            let flags = village.plots.compactMap { village.flagBox($0, view.stage) }
            for (disc, r, face, plot) in bubbles(view) {
                checked += 1
                for (spot, reach) in face { #expect(simd_distance(disc, spot) > r + reach, "\(plot.view.id) seed \(seed): the bubble covers the face") }
                for f in flags {
                    let dx = disc.x - clamp(disc.x, f.left, f.right), dy = disc.y - clamp(disc.y, f.top, f.bottom)
                    #expect(dx * dx + dy * dy >= r * r * 0.95, "\(plot.view.id) seed \(seed): the bubble covers a flag")
                }
            }
        }
        // Request, error, finished and napping cats all show one.
        #expect(checked >= seeds.count * 4)
    }
}

@MainActor
@Suite(.serialized) struct SidebarView {
    /// A sidebar holds five rows in a glance; nine workspaces leave four below.
    func tall() -> MeadowView { Sidebar.view(Sidebar.narrow, Sidebar.world(9)) }

    func box(_ view: MeadowView, _ id: String) -> CGRect { view.screenRect(of: .blanket(id))! }

    @Test("what is out of view, above and below, in order")
    func outOfView() {
        let view = tall()
        #expect(view.blanketsOutOfView.above.isEmpty)
        #expect(view.blanketsOutOfView.below == ["w5", "w6", "w7", "w8"])
        for id in view.blanketsOutOfView.below { #expect(box(view, id).minY < 0) }
        for i in 0..<5 {
            let r = box(view, "w\(i)")
            #expect(r.minY >= 0 && r.maxY <= Sidebar.narrow.height, "w\(i) should be in view: \(r)")
        }
    }

    @Test("reveal scrolls just far enough to bring a blanket and its flag in, and nothing when it is in")
    func reveal() {
        let view = tall()
        #expect(view.stage.revealDistance("w2", margin: MeadowView.revealMargin) == 0, "an in-view blanket moves nothing")

        view.reveal(.blanket("w7"), animated: false)
        view.advance(seconds: 0.1)
        let r = box(view, "w7")
        // In with its margin, at the bottom: only as far as needed.
        #expect(r.minY >= 11 && r.minY <= 14, "w7 at \(r)")
        #expect(!view.blanketsOutOfView.below.contains("w7"))
        #expect(view.blanketsOutOfView.below == ["w8"])
        #expect(view.blanketsOutOfView.above.contains("w0"))

        // Back up to the first: its flag's top just inside the top edge.
        view.reveal(.cat(blanket: "w0", agent: "c"), animated: false)
        view.advance(seconds: 0.1)
        let first = box(view, "w0")
        #expect(abs(Sidebar.narrow.height - first.maxY - 12) < 1.5, "w0 at \(first)")
        #expect(view.blanketsOutOfView.above.isEmpty)
    }

    @Test("an animated reveal eases over about 0.3 s, and the user's scroll takes over from it")
    func revealEases() {
        let view = tall()
        let start = view.stage.camera.view.z
        view.reveal(.blanket("w8"))
        view.advance(seconds: 0.1)
        let partway = view.stage.camera.view.z
        view.advance(seconds: 0.4)
        let end = view.stage.camera.view.z
        #expect(partway > start && partway < end)
        view.advance(seconds: 0.5)
        #expect(view.stage.camera.view.z == end, "it stays where it was brought")

        view.reveal(.blanket("w0"))
        view.advance(seconds: 0.05)
        view.stage.camera.scroll(dy: -10)   // as a scroll gesture does
        let held = view.stage.camera.view.z
        view.advance(seconds: 0.5)
        #expect(abs(view.stage.camera.view.z - held) < 1e-3, "the reveal stopped when the user scrolled")
    }

    @Test("in rows everything is framed: reveal does nothing")
    func revealInRows() {
        let view = Sidebar.view(Sidebar.wide, Sidebar.world(9))
        #expect(view.blanketsOutOfView.above.isEmpty && view.blanketsOutOfView.below.isEmpty)
        let before = view.stage.camera.view
        view.reveal(.blanket("w8"))
        view.advance(seconds: 0.5)
        // Nothing scrolls; the framing only finishes settling, by hundredths of a unit at most.
        let after = view.stage.camera.view
        #expect(abs(after.x - before.x) < 0.01 && abs(after.z - before.z) < 0.01 && abs(after.distance - before.distance) < 0.01)
    }

    @Test("onViewChanged is told once when the set changes, not every frame")
    func toldOnChange() {
        let view = tall()
        var told = 0
        view.onViewChanged = { told += 1 }
        view.advance(seconds: 0.5)
        #expect(told == 0)
        view.reveal(.blanket("w8"), animated: false)
        view.advance(seconds: 0.5)
        #expect(told == 1)
        view.advance(seconds: 0.5)
        #expect(told == 1)
    }

    @Test("screenRect: a blanket with its flag, a cat with its bubble, in the view's own coordinates; nil when unknown")
    func screenRects() {
        let view = Sidebar.view(Sidebar.narrow, Sidebar.world())
        let stage = view.stage, village = stage.village!
        let plot = village.plot("w0")!
        let blanket = box(view, "w0")
        let flag = village.flagBox(plot, stage)!
        // Flipped: AppKit's origin is at the bottom left.
        #expect(abs(blanket.maxY - (Sidebar.narrow.height - CGFloat(flag.top))) < 0.5)
        #expect(blanket.minX <= CGFloat(flag.left) && blanket.maxX >= CGFloat(flag.right))
        let cat = view.screenRect(of: .cat(blanket: "w0", agent: "c"))!
        #expect(blanket.intersects(cat))
        let head = stage.screen(plot.actors["c"]!.cat.face)
        #expect(cat.contains(CGPoint(x: CGFloat(head.x), y: Sidebar.narrow.height - CGFloat(head.y))))
        let bubble = plot.actors["c"]!.cat.bubbleDrawn, b = stage.screen(Vec3(bubble.x, bubble.y, bubble.z))
        #expect(cat.contains(CGPoint(x: CGFloat(b.x), y: Sidebar.narrow.height - CGFloat(b.y))), "the cat's rect holds its bubble")
        #expect(view.screenRect(of: .blanket("nowhere")) == nil)
        #expect(view.screenRect(of: .cat(blanket: "w0", agent: "nobody")) == nil)
    }
}

@MainActor
@Suite(.serialized) struct KeyboardFocus {
    /// Pixels of a strong, pure blue: the default accent, and nothing else in the meadow (the blue
    /// gingham and the finished bubble are greener or darker).
    func focusPixels(_ view: MeadowView) -> Int {
        let image = view.renderImage(width: 600, height: 1640)!
        var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let ctx = CGContext(data: &data, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        var n = 0
        for i in stride(from: 0, to: data.count, by: 4) {
            let r = Int(data[i]), g = Int(data[i + 1]), b = Int(data[i + 2])
            if b > 190 && b - g > 95 && b - r > 150 { n += 1 }
        }
        return n
    }

    @Test("a ring in the focus colour round the focused blanket or cat, day and night", arguments: [MeadowSettings.TimeOfDay.day, .night])
    func ringShows(_ time: MeadowSettings.TimeOfDay) {
        let view = Sidebar.view(Sidebar.narrow, Sidebar.world(), time: time)
        view.selection = .blanket("w1")
        view.advance(seconds: 0.1)
        let none = focusPixels(view)
        view.keyboardFocus = .blanket("w1")
        let blanket = focusPixels(view)
        view.keyboardFocus = .cat(blanket: "w3", agent: "c")
        let cat = focusPixels(view)
        #expect(blanket > none + 1500, "blanket ring: \(blanket) against \(none)")
        #expect(cat > none + 150, "cat ring: \(cat) against \(none)")
    }

    @Test("focus leaves with its blanket; keys go to onKeyDown")
    func focusAndKeys() throws {
        let view = Sidebar.view(Sidebar.narrow, Sidebar.world())
        view.keyboardFocus = .blanket("w4")
        view.world = Sidebar.world(4)
        #expect(view.keyboardFocus == nil)
        var keys: [UInt16] = []
        view.onKeyDown = { keys.append($0.keyCode); return true }
        let down = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                                 characters: "\u{F701}", charactersIgnoringModifiers: "\u{F701}", isARepeat: false, keyCode: 125))
        view.keyDown(with: down)
        #expect(keys == [125])
    }
}

@MainActor
@Suite(.serialized) struct LevelGround {
    /// The world's clearings as the shaders get them.
    func clearings(_ view: MeadowView) -> ([Vec4], Int) { (view.stage.world.clearings, view.stage.clearingCount) }

    @Test("every blanket, flag and cat stands on level ground in grass, however many workspaces, in a column and in rows",
          arguments: [(Sidebar.narrow, 1), (Sidebar.narrow, 12), (Sidebar.narrow, 20), (Sidebar.wide, 5), (Sidebar.wide, 20)])
    func nothingBuried(_ size: NSSize, _ count: Int) {
        let view = Sidebar.view(size, Sidebar.world(count))
        let village = view.stage.village!, meadow = view.stage.meadow!
        let (c, n) = clearings(view)
        #expect(n == count)
        var spots: [Vec3] = []
        for plot in village.plots {
            let model = Mat4.translation(plot.group + Vec3(plot.blanketAt.x, 0, plot.blanketAt.z)) * .rotationY(plot.turn)
            for p in Picnic.outlines[plot.cloth] { spots.append(model.point(Vec3(p.x, 0, -p.y) * plot.blanketSize)) }
            spots.append(plot.flagAt)
            for actor in plot.liveActors { spots.append(actor.cat.position) }
        }
        for s in spots {
            // Fully levelled: the land there is at the ground's own height, a hair under the cloth.
            #expect(Land.level(s.x, s.z, c, n) == 1, "not level at \(s)")
            #expect(Land.levelled(Vec3(s.x, Float(Land.height(s.x, s.z)), s.z), c, n).y <= 0, "buried at \(s)")
            // And grass grows there: in the field, or in its strip along the column.
            let grass = meadow.grass.chunks.contains { abs($0.center.x - s.x) <= 12 && abs($0.center.y - s.z) <= 12 }
            #expect(grass, "no grass at \(s)")
        }
        // No far hill stands over a blanket: any hill reaching a blanket has sunk under the ground.
        for i in meadow.hills.indices {
            let m = meadow.hill(i, c, n)
            let middle = Vec3(m.columns.3.x, m.columns.3.y, m.columns.3.z)
            for plot in village.plots where hypot(middle.x - plot.middle.x, middle.z - plot.middle.z) < m.columns.0.x + plot.radius {
                #expect(middle.y + m.columns.1.y <= 0, "hill \(i) over \(plot.view.id)")
            }
        }
        // Trees stand on the land as it is levelled.
        for i in meadow.treeShapes.indices {
            let at = meadow.treeAt(i, c, n), was = meadow.treeShapes[i].at
            #expect(abs(at.y - Land.levelled(was, c, n).y) < 1e-4)
        }
    }

    @Test("away from blankets the land keeps its own lie, and the shaders level by the same rule")
    func elsewhereUnchanged() {
        let view = Sidebar.view(Sidebar.narrow, Sidebar.world(3))
        let (c, n) = clearings(view)
        #expect(Land.level(150, -150, c, n) == 0)
        #expect(Land.levelled(Vec3(150, 5, -150), c, n) == Vec3(150, 5, -150))
        #expect(ShaderSource.common.contains("#define LEVEL_FLAT \(Land.flat)") && ShaderSource.common.contains("#define LEVEL_BLEND \(Land.blend)"))
        #expect(ShaderSource.common.contains("#define LAND_GROUND \(Land.ground)"))
    }

    @Test("revealing the last of twenty brings it to the bottom of the view")
    func revealTheLast() {
        let view = Sidebar.view(Sidebar.narrow, Sidebar.world(20))
        view.reveal(.blanket("w19"), animated: false)
        view.advance(seconds: 2)
        let r = view.screenRect(of: .blanket("w19"))!
        #expect(r.minY >= 11 && r.minY <= 14, "w19 at \(r)")
        #expect(view.blanketsOutOfView.below.isEmpty)
    }
}
