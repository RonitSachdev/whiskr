import AppKit
import Foundation
import Testing
import simd
@testable import MeadowScene

// What the lantern and hamper rules look like once drawn, not only where the layout puts things. A lone
// cat on the smallest blanket once left no free cloth: its hamper was never set down, and its lanterns
// fell back to the cat's own spot and were drawn inside the cat (only a glow under it showed), while
// `LanternTests`, on a roomier blanket and picking by position, still passed.

@MainActor
@Suite(.serialized) struct LanternLooks {
    static let size = NSSize(width: 480, height: 320)

    func world(lantern: MeadowLantern.State?) -> MeadowWorld {
        MeadowWorld(machines: [MeadowMachine(id: "m", name: "m", spaces: [MeadowSpace(id: "s", name: "s", blankets: [
            MeadowBlanket(id: "lone", title: "lone", color: .account(1), agents: [MeadowAgent(id: "main", activity: .awake)],
                          lanterns: lantern.map { [MeadowLantern(id: "dev", title: "npm run dev", state: $0)] } ?? []),
        ])])])
    }

    /// The blanket framed close, settled, drawn at 2×; and where the lantern's globe is in the picture.
    func shot(lantern: MeadowLantern.State?, time: MeadowSettings.TimeOfDay, picnic: MeadowSettings.Picnic = .hamper) -> (CGImage, Vec2?, MeadowView) {
        let view = MeadowView(frame: NSRect(origin: .zero, size: Self.size), mode: .meadow)
        view.settings = MeadowSettings(timeOfDay: time, picnic: picnic)
        view.world = world(lantern: lantern)
        view.advance(seconds: 0.5)
        // Looked at from the lantern's side, so the cat it stands beside is never between it and the camera.
        if let bearing = Self.bearing { view.turn(toBearing: bearing) }
        view.frame(.blanket("lone"), besidePanelWidth: 0, animated: false)
        view.advance(seconds: 4)
        let image = view.renderImage(width: Int(Self.size.width * 2), height: Int(Self.size.height * 2))!
        let plot = view.stage.village!.plots[0]
        let globe = plot.lanterns.first.map { l -> Vec2 in
            // Low on the globe: seen steeply from above, its cap hides the top half.
            let p = view.stage.screen(plot.group + l.at + Vec3(0, 0.32 * LANTERN_SIZE, 0))
            return Vec2(p.x * 2, p.y * 2)
        }
        return (image, globe, view)
    }

    /// The camera's bearing that looks at the lantern from the far side of the cat. Its place on the
    /// blanket does not depend on the camera, so it is worked out once.
    static let bearing: Float? = {
        let view = MeadowView(frame: NSRect(origin: .zero, size: size), mode: .meadow)
        view.settings = MeadowSettings(timeOfDay: .night)
        view.world = LanternLooks().world(lantern: .running)
        view.advance(seconds: 0.5)
        var best: (bearing: Float, room: Float)?
        for step in 0..<12 {
            let bearing = Float(step) / 12 * 2 * .pi
            view.turn(toBearing: bearing)
            view.frame(.blanket("lone"), besidePanelWidth: 0, animated: false)
            view.advance(seconds: 2)
            let plot = view.stage.village!.plots[0]
            let globe = view.stage.screen(plot.group + plot.lanterns[0].at + Vec3(0, 0.45, 0))
            let cat = view.stage.screen(plot.actors["main"]!.cat.position + Vec3(0, 0.8, 0))
            let room = hypot(globe.x - cat.x, globe.y - cat.y) * (globe.z < cat.z ? 2 : 1)
            if room > best?.room ?? -1 { best = (bearing, room) }
        }
        return best?.bearing
    }()

    /// Mean sRGB colour of a small square round a point (y down, as the picture is stored).
    func colour(_ image: CGImage, at point: Vec2, radius: Int = 3) -> SIMD3<Double> {
        var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let ctx = CGContext(data: &data, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        var sum = SIMD3<Double>(0, 0, 0), n = 0.0
        for dy in -radius...radius {
            for dx in -radius...radius {
                let x = Int(point.x) + dx, y = Int(point.y) + dy
                guard x >= 0, y >= 0, x < image.width, y < image.height else { continue }
                let i = (y * image.width + x) * 4
                sum += SIMD3(Double(data[i]), Double(data[i + 1]), Double(data[i + 2]))
                n += 1
            }
        }
        return sum / max(n, 1)
    }

    @Test func aRunningLanternIsDrawnWarmAndLitAtNight() throws {
        let (with, globe, view) = shot(lantern: .running, time: .night)
        let at = try #require(globe)
        let plot = view.stage.village!.plots[0]
        // Not inside the cat: clear of the main cat's seat.
        let cat = plot.actors["main"]!.spot, lantern = plot.lanterns[0].spot
        #expect(hypot(cat.x - lantern.x, cat.z - lantern.z) > 1.35 + Picnic.lanternReach)
        let (without, _, _) = shot(lantern: nil, time: .night)
        let lit = colour(with, at: at), bare = colour(without, at: at)
        #expect(simd_length(lit - bare) > 40, "the globe should be drawn where it stands: \(lit) vs \(bare) without it")
        #expect(lit.x > lit.z + 50 && lit.y > lit.z + 30, "a lit globe is warm yellow: \(lit)")
    }

    @Test func aFailedLanternIsRed() throws {
        let (image, globe, _) = shot(lantern: .failed, time: .night)
        let c = colour(image, at: try #require(globe))
        #expect(c.x > c.y + 40 && c.x > c.z + 40, "a failed globe is red: \(c)")
    }

    @Test func aFinishedLanternIsDarkButThere() throws {
        let (dark, globe, _) = shot(lantern: .finished, time: .night)
        let at = try #require(globe)
        let (lit, _, _) = shot(lantern: .running, time: .night)
        let (bare, _, _) = shot(lantern: nil, time: .night)
        let d = colour(dark, at: at), l = colour(lit, at: at), b = colour(bare, at: at)
        #expect(simd_length(d - b) > 20, "a finished lantern still stands there: \(d) vs bare \(b)")
        #expect(d.x + d.y < l.x + l.y - 60, "and is not lit: \(d) vs lit \(l)")
    }

    @Test func noLanternByDay() throws {
        let (day, globe, _) = shot(lantern: .running, time: .day)
        let (bare, _, _) = shot(lantern: nil, time: .day)
        let at = try #require(globe)
        #expect(simd_length(colour(day, at: at, radius: 8) - colour(bare, at: at, radius: 8)) < 3)
    }

    /// The hamper rule: every occupied blanket shows its hamper, the smallest included, with no lantern,
    /// and with lanterns that are only drawn at night.
    @Test(arguments: [MeadowSettings.TimeOfDay.day, .night])
    func aLoneCatHasItsHamper(_ time: MeadowSettings.TimeOfDay) {
        for lantern in [nil, MeadowLantern.State.running] {
            let (_, _, view) = shot(lantern: lantern, time: time)
            let plot = view.stage.village!.plots[0]
            let hamper = plot.treats.first { $0.kind == 0 }
            #expect(hamper?.wanted == true && (hamper?.shown.x ?? 0) > 0.9)
            if let hamper {
                let cat = plot.actors["main"]!.spot
                // Clear of the cat, and on the cloth.
                #expect(hypot(cat.x - hamper.spot.x, cat.z - hamper.spot.z) >= 1.35 + hamper.reach)
                #expect(hypot(hamper.spot.x - plot.center.x, hamper.spot.z - plot.center.z) + hamper.reach <= plot.size)
            }
        }
    }

    /// With no picnic the smallest blanket has no cloth wholly free: lanterns stand at its edge, still
    /// clear of the cat and mostly on the cloth.
    @Test func lanternsOnTheSmallestBlanketStandClearOfTheCat() {
        let (_, _, view) = shot(lantern: .running, time: .night, picnic: .none)
        let plot = view.stage.village!.plots[0]
        let cat = plot.actors["main"]!.spot, lantern = plot.lanterns[0].spot
        #expect(hypot(cat.x - lantern.x, cat.z - lantern.z) >= 1.35 + Picnic.lanternReach)
        let out = Vec2(lantern.x - plot.center.x, lantern.z - plot.center.z)
        #expect(simd_length(out) + Picnic.lanternReach * 0.5 <= view.stage.village!.clothReach(plot, toward: simd_normalize(out)) + 1e-3)
    }

    /// Making room for the hamper grows the cloth; it never moves the cat.
    @Test func roomForTheHamperMovesNobody() {
        let (_, _, without) = shot(lantern: nil, time: .day, picnic: .none)
        let (_, _, with) = shot(lantern: nil, time: .day, picnic: .hamper)
        let a = without.stage.village!.plots[0], b = with.stage.village!.plots[0]
        #expect(a.actors["main"]!.spot == b.actors["main"]!.spot)
        #expect(b.size >= a.size)
    }
}
