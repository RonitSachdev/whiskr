import AppKit
import Foundation
import Testing
import simd
@_spi(Diagnostics) @testable import MeadowScene

// View › Animate Meadow (WCAG 2.2.2): with `animatesAmbient` off the meadow holds still (plants, critters,
// fireflies, every cat's idle life) while what it says still shows (a cat needing you stands up with its
// bubble, without a hop), the view stops drawing once a change has settled, and turning it back on carries
// on from where everything stood.

@MainActor
@Suite(.serialized) struct AmbientMotion {
    func world(needsYou: Bool = false) -> MeadowWorld {
        MeadowWorld(machines: [MeadowMachine(id: "m", name: "m", spaces: [MeadowSpace(id: "s", name: "s", blankets: [
            MeadowBlanket(id: "shop", title: "shop", color: .account(0), agents: [
                MeadowAgent(id: "main", activity: .awake, needsYou: needsYou),
                MeadowAgent(id: "h", parentID: "main", activity: .reading),
            ], lanterns: [MeadowLantern(id: "dev", state: .running)]),
            MeadowBlanket(id: "api", title: "api", color: .account(1), agents: [MeadowAgent(id: "main", activity: .napping)]),
        ])])])
    }

    func view(time: MeadowSettings.TimeOfDay = .night) -> MeadowView {
        let view = MeadowView(frame: NSRect(x: 0, y: 0, width: 480, height: 320), mode: .meadow)
        view.settings = MeadowSettings(timeOfDay: time, picnic: .hamper)
        view.world = world()
        view.advance(seconds: 0.5)
        view.frame(nil, besidePanelWidth: 0, animated: false)
        view.advance(seconds: 3)
        return view
    }

    /// Everything that moves on its own, as numbers.
    func motion(_ view: MeadowView) -> [Float] {
        var out = [view.stage.meadowTime]
        for spot in view.stage.meadow!.critters.spots { out += [spot.x, spot.y, spot.z] }
        for cat in view.stage.cats {
            out += [cat.bodyMatrix.columns.1.y, cat.bodyMatrix.columns.3.y, cat.faceMatrix.columns.2.x, cat.faceMatrix.columns.2.y, cat.eyesOpen]
            out += cat.tailVertices.prefix(60)
        }
        for plot in view.stage.village!.plots { out += [plot.ladybird.x, plot.ladybird.z] }
        return out
    }

    /// The largest difference between two readings: what is left of an ease settling is far below a
    /// visible movement.
    func moved(_ a: [Float], _ b: [Float]) -> Float { a.count == b.count ? zip(a, b).map { abs($0 - $1) }.max() ?? 0 : .infinity }

    func pixels(_ view: MeadowView) -> [UInt8] {
        let image = view.renderImage(width: 480, height: 320)!
        var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let ctx = CGContext(data: &data, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return data
    }

    @Test("frozen, two seconds with nothing new change nothing, in numbers or in the picture", arguments: [MeadowSettings.TimeOfDay.day, .night])
    func holdsStill(_ time: MeadowSettings.TimeOfDay) {
        let view = view(time: time)
        // Played, the meadow moves.
        let playing = motion(view), playingImage = pixels(view)
        view.advance(seconds: 2)
        #expect(moved(motion(view), playing) > 0.05)
        #expect(pixels(view) != playingImage)

        view.animatesAmbient = false
        view.advance(seconds: 1)
        let before = motion(view), image = pixels(view)
        view.advance(seconds: 2)
        #expect(moved(motion(view), before) < 1e-3)
        #expect(pixels(view) == image, "a frozen meadow draws the same picture")
    }

    @Test("frozen, a cat that needs you still stands up with its bubble, without a hop")
    func stateStillShows() {
        let view = view()
        view.animatesAmbient = false
        view.advance(seconds: 1)
        view.world = world(needsYou: true)
        let cat = view.stage.village!.actor("shop", "main")!.cat
        var highest: Float = 0
        for _ in 0..<90 {
            view.advance(seconds: 1.0 / 60)
            highest = max(highest, cat.height)
        }
        #expect(cat.bubbleShown && cat.bubbleMark == .needsYou)
        #expect(highest == 0, "no hop with ambient motion off")
        // And once it has settled it holds still in its new pose.
        view.advance(seconds: 2)
        let settled = motion(view)
        view.advance(seconds: 2)
        #expect(moved(motion(view), settled) < 1e-3)
    }

    @Test("frozen, the view stops drawing once a change has settled, and wakes for the next")
    func restsBetweenChanges() {
        let view = view()
        view.advance(seconds: 5)
        #expect(!view.frozenAtRest, "a playing meadow keeps drawing")
        view.animatesAmbient = false
        #expect(!view.frozenAtRest)
        view.advance(seconds: Double(MeadowView.settleSeconds) + 0.5)
        #expect(view.frozenAtRest)
        view.world = world(needsYou: true)
        #expect(!view.frozenAtRest, "a change draws again")
        view.advance(seconds: 1)
        #expect(!view.frozenAtRest)
        view.advance(seconds: Double(MeadowView.settleSeconds) + 1)
        #expect(view.frozenAtRest)
        view.animatesAmbient = true
        #expect(!view.frozenAtRest)
    }

    @Test("turned back on, everything carries on from where it stood")
    func resumesWithoutAJump() {
        let view = view()
        view.animatesAmbient = false
        view.advance(seconds: 3)
        let cat = view.stage.village!.actor("shop", "main")!.cat
        let time = view.stage.meadowTime, body = cat.bodyMatrix
        view.animatesAmbient = true
        view.advance(seconds: 1.0 / 60)
        #expect(abs(view.stage.meadowTime - time - 1.0 / 60) < 1e-4)
        #expect(simd_distance(body.columns.1, cat.bodyMatrix.columns.1) < 0.02, "the cat's breathing picks up where it stopped")
    }

    @Test("frozen, the view can still be turned")
    func cameraStillMoves() {
        let view = view()
        view.animatesAmbient = false
        view.advance(seconds: 1)
        let bearing = view.cameraAngle.bearing
        view.simulateDrag(dx: 80, dy: 0)
        view.advance(seconds: 0.5)
        #expect(abs(view.cameraAngle.bearing - bearing) > 0.05)
    }
}
