import AppKit
import Testing
import simd
@_spi(Diagnostics) @testable import MeadowScene

// The meadow follows what you choose (`MeadowView.select(_:origin:)`, `Follow.swift`): what is chosen on the
// right glides comfortably into view, nothing moves when it is there already, a quick run of choices moves the
// view once, your hand comes first, and nothing an agent does moves the camera. Driven frame by frame on a
// clock of the test's own, as a shown view would be.

@MainActor
@Suite(.serialized) struct Following {
    final class Clock { var now: CFTimeInterval = 1000 }

    /// A sidebar's column of `count` workspaces (taller than the view from six), or rows when `size` is wide,
    /// shown, on a clock of the test's own.
    func view(_ size: NSSize = Sidebar.narrow, _ count: Int = 9, time: MeadowSettings.TimeOfDay = .day) -> (MeadowView, Clock) {
        let view = Sidebar.view(size, Sidebar.world(count), time: time)
        let clock = Clock()
        view.clock = { clock.now }
        view.shownForTests = true
        view.keepsFullRateWhenInactive = true
        // Let the framing finish settling, so what moves after is the follow's doing.
        view.advance(seconds: 3)
        return (view, clock)
    }

    /// Frames at 60 Hz for `seconds`, the clock keeping time; the camera's spot after each.
    @discardableResult
    func run(_ view: MeadowView, _ clock: Clock, _ seconds: Double) -> [Vec3] {
        var spots: [Vec3] = []
        for _ in 0..<Int((seconds * 60).rounded()) {
            clock.now += 1.0 / 60
            view.step(1 / 60)
            let s = view.followState
            spots.append(Vec3(s.x, s.z, s.distance))
        }
        return spots
    }

    func spot(_ view: MeadowView) -> Vec3 { let s = view.followState; return Vec3(s.x, s.z, s.distance) }

    /// Still, as far as anyone could see: well under a tenth of a point on screen.
    static let still: Float = 2e-3

    /// How far `item` (its blanket, and its cat for a cat) sits inside the view's edges, in points: the least
    /// of its four margins.
    func margin(_ view: MeadowView, _ item: MeadowItem) -> CGFloat {
        var rects = [view.screenRect(of: .blanket(item.blanketID))]
        if case .cat = item { rects.append(view.screenRect(of: item)) }
        return rects.map { r in
            guard let r else { return -.infinity }
            return min(r.minX, r.minY, view.bounds.width - r.maxX, view.bounds.height - r.maxY)
        }.min()!
    }

    func comfortable(_ view: MeadowView, _ item: MeadowItem) -> Bool { margin(view, item) >= MeadowView.comfortableInset - 0.5 }

    /// The least of its margins to the top and bottom edges: what a column's follow minds (across is its framing's).
    func vertically(_ view: MeadowView, _ item: MeadowItem) -> CGFloat {
        let r = view.screenRect(of: .blanket(item.blanketID))!
        return min(r.minY, view.bounds.height - r.maxY)
    }

    @Test("something already comfortably in view moves nothing: a blanket, a cat, in a column and in rows",
          arguments: [(Sidebar.narrow, MeadowItem.blanket("w1")), (Sidebar.narrow, .cat(blanket: "w2", agent: "c")),
                      (Sidebar.wide, .blanket("w8")), (Sidebar.wide, .cat(blanket: "w5", agent: "c"))])
    func comfortableStays(_ size: NSSize, _ item: MeadowItem) {
        let (view, clock) = view(size)
        run(view, clock, 1)
        #expect(comfortable(view, item), "\(item) starts in view: \(margin(view, item))")
        let before = spot(view)
        view.select(item, origin: .user)
        let spots = run(view, clock, 1.5)
        #expect(spots.allSatisfy { simd_distance($0, before) < Self.still }, "\(item): the camera moved")
        #expect(view.selection == item)
    }

    @Test("a blanket out of a column's view glides in, just far enough, after a short wait, and stays",
          arguments: [Sidebar.narrow, NSSize(width: 240, height: 640)])
    func offScreenInColumn(_ size: NSSize) {
        let (view, clock) = view(size)
        run(view, clock, 1)
        let item = MeadowItem.blanket("w7")
        #expect(!comfortable(view, item))
        let start = spot(view)
        view.select(item, origin: .user)
        // It waits a moment for a next choice, then sets off gently.
        run(view, clock, MeadowView.followSettle - 0.03)
        #expect(simd_distance(spot(view), start) < Self.still, "it waited for the next choice")
        let glide = run(view, clock, 0.25)
        #expect(view.followState.gliding)
        #expect(simd_distance(glide.last!, start) > 0.05, "it is on its way")
        run(view, clock, 1.5)
        #expect(!view.followState.gliding)
        #expect(vertically(view, item) >= MeadowView.comfortableInset - 0.5, "w7 sits \(vertically(view, item)) pt in")
        // Just far enough: near the bottom edge, where it came from, not in the middle.
        let r = view.screenRect(of: item)!
        #expect(r.minY < CGFloat(Stage.Comfort.room) + 6, "w7 at \(r)")
        // The angle and the zoom are as they were.
        #expect(abs(view.followState.distance - start.z) < 1e-3)
        let end = spot(view)
        run(view, clock, 2)
        #expect(simd_distance(spot(view), end) < Self.still, "it stays where it was brought")
    }

    @Test("the glide is smooth: it sets off and lands gently, with no jump between frames")
    func smoothGlide() {
        let (view, clock) = view()
        run(view, clock, 1)
        view.select(.blanket("w8"), origin: .user)
        let spots = [spot(view)] + run(view, clock, 2)
        let steps = zip(spots, spots.dropFirst()).map { simd_distance(Vec2($0.x, $0.y), Vec2($1.x, $1.y)) }
        let fastest = steps.max()!
        #expect(fastest > 0.01)
        // Neither end jerks: the first and last moving frames are slow beside the fastest.
        let moving = steps.filter { $0 > 1e-5 }
        #expect(moving.first! < fastest * 0.2 && moving.last! < fastest * 0.2, "first \(moving.first!), last \(moving.last!), fastest \(fastest)")
        // And from frame to frame the speed changes by little.
        let changes = zip(steps, steps.dropFirst()).map { abs($1 - $0) }
        #expect(changes.max()! < fastest * 0.2, "largest change of speed \(changes.max()!) against \(fastest)")
    }

    @Test("a cat on a blanket out of view comes in with its blanket")
    func catComesIn() {
        let (view, clock) = view()
        run(view, clock, 1)
        let cat = MeadowItem.cat(blanket: "w6", agent: "c")
        view.select(cat, origin: .user)
        run(view, clock, 2)
        #expect(comfortable(view, cat), "\(margin(view, cat))")
        #expect(view.selection == cat)
    }

    @Test("rows: a zoomed-in view slides sideways and along to what is chosen, keeping its zoom")
    func rowsAfterZoom() {
        let (view, clock) = view(Sidebar.wide)
        run(view, clock, 1)
        view.simulateZoom(by: 0.7, at: CGPoint(x: 150, y: 200))
        run(view, clock, 1)
        let zoomed = view.followState.distance
        let item = MeadowItem.cat(blanket: "w8", agent: "c")
        #expect(!comfortable(view, item))
        view.select(item, origin: .user)
        run(view, clock, 2)
        #expect(comfortable(view, item), "\(margin(view, item))")
        #expect(abs(view.followState.distance - zoomed) < 1e-3, "no zoom when it fits: \(zoomed) → \(view.followState.distance)")
    }

    @Test("something too big for the view backs the camera off, gently and no further than it must")
    func backsOff() {
        let (view, clock) = view(Sidebar.wide, 5)
        run(view, clock, 1)
        for _ in 0..<6 { view.simulateZoom(by: 0.6, at: CGPoint(x: 450, y: 410)) }
        run(view, clock, 1)
        let close = view.followState.distance
        let item = MeadowItem.blanket("w4")
        view.select(item, origin: .user)
        run(view, clock, 2.5)
        let far = view.followState.distance
        #expect(far > close && far <= close * Stage.Comfort.farthest + 1e-3, "\(close) → \(far)")
        #expect(margin(view, item) > -1 || view.screenRect(of: .blanket("w4")) != nil)
    }

    @Test("a quick run of choices moves the view once, to the last")
    func debounce() {
        let (view, clock) = view()
        run(view, clock, 1)
        let start = spot(view)
        // ⌃Tab cycling, or ⌘⇧] held down: a choice every 80 ms.
        for id in ["w5", "w6", "w7", "w8", "w6"] {
            view.select(.blanket(id), origin: .user)
            run(view, clock, 0.08)
            #expect(simd_distance(spot(view), start) < Self.still, "moved while choices kept coming (\(id))")
        }
        run(view, clock, 2)
        #expect(comfortable(view, .blanket("w6")))
        // Only as far as w6 needed: w7 and w8 were never brought in.
        #expect(!comfortable(view, .blanket("w8")))
    }

    @Test("a new choice during a glide bends it toward the new one without a jolt")
    func retargets() {
        let (view, clock) = view(Sidebar.narrow, 14)
        run(view, clock, 1)
        view.select(.blanket("w8"), origin: .user)
        var spots = run(view, clock, MeadowView.followSettle + 0.3)
        view.select(.blanket("w13"), origin: .user)
        spots += run(view, clock, 3)
        let steps = zip(spots, spots.dropFirst()).map { simd_distance(Vec2($0.x, $0.y), Vec2($1.x, $1.y)) }
        let fastest = steps.max()!
        let changes = zip(steps, steps.dropFirst()).map { abs($1 - $0) }
        #expect(changes.max()! < fastest * 0.2, "largest change of speed \(changes.max()!) against \(fastest)")
        // It never stopped dead on the way: the waiting moment comes while it is already moving.
        let middle = steps[Int((MeadowView.followSettle + 0.15) * 60)..<Int((MeadowView.followSettle + 0.6) * 60)]
        #expect(middle.allSatisfy { $0 > fastest * 0.05 }, "it paused on the way")
        #expect(comfortable(view, .blanket("w13")))
    }

    @Test("an agent's selection never moves the camera, and neither does what agents do after a follow")
    func agentsNeverMove() {
        let (view, clock) = view()
        run(view, clock, 1)
        let start = spot(view)
        view.select(.blanket("w8"), origin: .event)
        #expect(view.selection == .blanket("w8"))
        run(view, clock, 2)
        #expect(simd_distance(spot(view), start) < Self.still)
        // Followed by you, then the world changes under it: cats arrive and ask for you.
        view.select(.cat(blanket: "w7", agent: "c"), origin: .user)
        run(view, clock, 2)
        let followed = spot(view)
        var world = Sidebar.world(9)
        for i in world.machines[0].spaces.indices {
            world.machines[0].spaces[i].blankets[0].agents += [MeadowAgent(id: "x", activity: .running, needsYou: true), MeadowAgent(id: "y", activity: .reading)]
        }
        view.world = world
        run(view, clock, 3)
        #expect(simd_distance(spot(view), followed) < Self.still, "an agent's change moved the camera by \(simd_distance(spot(view), followed))")
    }

    @Test("once you move the view yourself, the same choice leaves it be; a different one follows")
    func handComesFirst() {
        let (view, clock) = view()
        run(view, clock, 1)
        view.select(.blanket("w7"), origin: .user)
        run(view, clock, 2)
        view.simulateDrag(dx: 0, dy: 180, slide: true)
        run(view, clock, 1.5)
        let mine = spot(view)
        view.select(.blanket("w7"), origin: .user)
        run(view, clock, 1.5)
        #expect(simd_distance(spot(view), mine) < Self.still, "the same choice took the view back")
        view.select(.blanket("w2"), origin: .user)
        run(view, clock, 2)
        #expect(comfortable(view, .blanket("w2")))
    }

    @Test("nothing follows during a drag, and a choice still waiting is dropped when you take the view")
    func neverFightsADrag() {
        let (view, clock) = view()
        run(view, clock, 1)
        view.stage.camera.grab()
        let held = spot(view)
        view.select(.blanket("w8"), origin: .user)
        run(view, clock, 1)
        #expect(simd_distance(spot(view), held) < Self.still)
        view.stage.camera.release()
        run(view, clock, 1)
        #expect(simd_distance(spot(view), held) < Self.still)
        // Chosen, then the view is dragged before it set off.
        view.select(.blanket("w8"), origin: .user)
        view.simulateDrag(dx: 0, dy: -20, slide: true)
        let dragged = spot(view)
        run(view, clock, 1.5)
        #expect(simd_distance(spot(view), dragged) < 0.2, "it followed after all")
        #expect(!comfortable(view, .blanket("w8")))
    }

    @Test("Home frames the blankets again, gently")
    func home() {
        let (view, clock) = view()
        run(view, clock, 1)
        let framing = spot(view)
        view.select(.blanket("w8"), origin: .user)
        run(view, clock, 2)
        #expect(simd_distance(spot(view), framing) > 1)
        view.select(nil, origin: .user)
        let back = run(view, clock, 2.5)
        #expect(view.selection == nil)
        #expect(simd_distance(back.last!, framing) < 0.05, "back to the framing: \(back.last!) against \(framing)")
        let partway = back[Int((MeadowView.followSettle + 0.25) * 60)]
        #expect(simd_distance(partway, framing) > 0.2, "it glided, not cut")
    }

    @Test("hidden it does nothing, and catches up at once when shown")
    func catchesUp() {
        let (view, clock) = view()
        run(view, clock, 1)
        view.shownForTests = false
        let start = spot(view)
        view.select(.blanket("w8"), origin: .user)
        #expect(simd_distance(spot(view), start) < Self.still)
        view.shownForTests = true
        // The first frame drawn once shown: there already.
        run(view, clock, 1.0 / 60)
        #expect(comfortable(view, .blanket("w8")), "\(margin(view, .blanket("w8")))")
    }

    @Test("with Reduce Motion, or the meadow's animation off, it cuts", arguments: [true, false])
    func cutsWhenCalm(_ reduceMotion: Bool) {
        let (view, clock) = view()
        run(view, clock, 1)
        if reduceMotion { view.stage.camera.calm = true } else { view.animatesAmbient = false }
        view.select(.blanket("w8"), origin: .user)
        run(view, clock, MeadowView.followSettle + 2.0 / 60)
        #expect(comfortable(view, .blanket("w8")), "\(margin(view, .blanket("w8")))")
        #expect(!view.followState.gliding)
    }

    @Test("a resize keeps what was chosen in comfortable view")
    func resizeKeepsIt() {
        let (view, clock) = view()
        run(view, clock, 1)
        view.select(.blanket("w7"), origin: .user)
        run(view, clock, 2)
        view.setFrameSize(NSSize(width: 300, height: 600))
        run(view, clock, 2.5)
        #expect(comfortable(view, .blanket("w7")), "\(margin(view, .blanket("w7")))")
    }

    @Test("a glide draws at the full rate while it moves, then the meadow rests")
    func fullRateThenRest() {
        let (view, clock) = view()
        run(view, clock, 1)
        view.select(.blanket("w8"), origin: .user)
        var rates: [Int] = []
        var gliding: [Bool] = []
        var left = 2.0
        while left > 0 {
            let dt = 1 / Double(view.targetRate)
            clock.now += dt
            left -= dt
            view.step(Float(dt))
            view.updateRate()
            rates.append(view.targetRate)
            gliding.append(view.followState.gliding)
        }
        let during = zip(rates, gliding).filter(\.1).map(\.0)
        #expect(!during.isEmpty && during.allSatisfy { $0 == 60 }, "\(Set(during))")
        var restLeft = Double(MeadowView.restAfter) + 4
        while restLeft > 0 {
            let dt = 1 / Double(view.targetRate)
            clock.now += dt
            restLeft -= dt
            view.step(Float(dt))
            view.updateRate()
        }
        #expect(view.isResting)
    }

    @Test("the open meadow (MeadowDemo's picnic) follows a choice too, zoomed in by hand")
    func picnic() {
        let view = MeadowView(frame: NSRect(x: 0, y: 0, width: 1280, height: 800), mode: .meadow)
        view.settings = MeadowSettings(arrangement: .picnic, timeOfDay: .day, picnic: .hamper)
        view.world = Sidebar.world(5)
        view.advance(seconds: 0.5)
        view.frame(nil, besidePanelWidth: 0, animated: false)
        view.advance(seconds: 2)
        let clock = Clock()
        view.clock = { clock.now }
        view.shownForTests = true
        view.simulateZoom(by: 0.4, at: CGPoint(x: 200, y: 200))
        run(view, clock, 1)
        let item = MeadowItem.cat(blanket: "w4", agent: "c")
        let target = view.screenRect(of: item)
        let item2 = (target.map { view.bounds.insetBy(dx: 12, dy: 12).contains($0) } ?? false) ? MeadowItem.cat(blanket: "w0", agent: "c") : item
        #expect(!comfortable(view, item2), "\(item2) starts out of view")
        view.select(item2, origin: .user)
        run(view, clock, 2)
        #expect(comfortable(view, item2), "\(margin(view, item2))")
    }

    /// Pixels in the chosen cat's neighbourhood that differ, by more than a little, between two renders.
    func changed(_ a: CGImage, _ b: CGImage, around rect: CGRect, scale: CGFloat) -> Int {
        func pixels(_ image: CGImage) -> [UInt8] {
            var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
            let ctx = CGContext(data: &data, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return data
        }
        let pa = pixels(a), pb = pixels(b)
        let area = rect.insetBy(dx: -rect.width * 0.6, dy: -rect.height * 0.4)
        var n = 0
        for y in max(0, Int(area.minY * scale))..<min(a.height, Int(area.maxY * scale)) {
            // Rows from the top: the image's first row is the view's top.
            let row = a.height - 1 - y
            for x in max(0, Int(area.minX * scale))..<min(a.width, Int(area.maxX * scale)) {
                let i = (row * a.width + x) * 4
                let d = abs(Int(pa[i]) - Int(pb[i])) + abs(Int(pa[i + 1]) - Int(pb[i + 1])) + abs(Int(pa[i + 2]) - Int(pb[i + 2]))
                if d > 30 { n += 1 }
            }
        }
        return n
    }

    @Test("the chosen cat is marked by a soft pool of light and a ring, by day and by night", arguments: [MeadowSettings.TimeOfDay.day, .night])
    func chosenCatShows(_ time: MeadowSettings.TimeOfDay) {
        let view = Sidebar.view(Sidebar.narrow, Sidebar.world(), time: time)
        let cat = MeadowItem.cat(blanket: "w3", agent: "c")
        view.selection = .blanket("w3")
        view.advance(seconds: 0.1)
        let plain = view.renderImage(width: 600, height: 1640)!
        view.selection = cat
        view.advance(seconds: 0.1)
        let marked = view.renderImage(width: 600, height: 1640)!
        let rect = view.screenRect(of: cat)!
        let n = changed(plain, marked, around: rect, scale: 2)
        // The pool reaches past the cat on the cloth: about four times what the ring alone changes (about
        // 600 pixels at 2×), not a hairline.
        #expect(n > 1800, "\(time): \(n) pixels changed round the cat")
    }
}
