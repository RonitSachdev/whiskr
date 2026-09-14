import AppKit
import Testing
import simd
@_spi(Diagnostics) @testable import MeadowScene

// The resting rule (`MeadowView`): left alone with nothing new, the meadow slows its own time and draws at
// `restRate`, by night as by day, with lanterns lit and cats at work; a change in the world ends the rest
// without asking for the full rate; only input does. Driven frame by frame at the rate the view asks for,
// on a clock of the test's own.

@MainActor
@Suite(.serialized) struct Resting {
    final class Clock { var now: CFTimeInterval = 1000 }

    /// `count` workspaces, each with a plain terminal (a lantern) and a cat, napping or at work.
    func world(_ count: Int, working: Bool, napping: Bool = false) -> MeadowWorld {
        MeadowWorld(machines: [MeadowMachine(id: "m", name: "m", spaces: (0..<count).map { i in
            MeadowSpace(id: "s\(i)", name: "w\(i)", blankets: [
                MeadowBlanket(id: "b\(i)", title: "w\(i)", color: .account(i % 6), agents: [
                    MeadowAgent(id: "main", activity: working ? .reading : napping ? .napping : .awake),
                ], lanterns: [MeadowLantern(id: "t\(i)", state: i % 2 == 0 ? .running : .finished)]),
            ])
        })])
    }

    func view(_ time: MeadowSettings.TimeOfDay, workspaces: Int, working: Bool) -> (MeadowView, Clock) {
        let clock = Clock()
        let view = MeadowView(frame: NSRect(x: 0, y: 0, width: 360, height: 800), mode: .meadow)
        view.clock = { clock.now }
        // Paced as a key window's view is (a test's view has no window).
        view.keepsFullRateWhenInactive = true
        view.settings = MeadowSettings(arrangement: .column, timeOfDay: time, picnic: .hamper)
        view.world = world(workspaces, working: working)
        return (view, clock)
    }

    /// Frames as the display link would give them: each at the rate the view asks for. Returns the rates asked.
    @discardableResult
    func run(_ view: MeadowView, _ clock: Clock, seconds: Double) -> [Int] {
        var rates: [Int] = []
        var left = seconds
        while left > 0 {
            let dt = 1 / Double(view.targetRate)
            clock.now += dt
            left -= dt
            view.step(Float(dt))
            view.updateRate()
            rates.append(view.targetRate)
        }
        return rates
    }

    @Test("left alone, it rests at the slow tick by night as by day, with lanterns lit and cats at work",
          arguments: [MeadowSettings.TimeOfDay.day, .night, .hour(0.5)], [1, 5])
    func restsDayAndNight(_ time: MeadowSettings.TimeOfDay, workspaces: Int) {
        for working in [false, true] {
            let (view, clock) = view(time, workspaces: workspaces, working: working)
            run(view, clock, seconds: Double(MeadowView.restAfter) + 4)
            #expect(view.isResting, "\(time), \(workspaces) workspaces, working \(working)")
            #expect(view.targetRate == MeadowView.restRate)
            // And it stays there: nothing in the scene wakes it, night's fireflies and lamps included.
            let rates = run(view, clock, seconds: 10)
            #expect(rates.allSatisfy { $0 == MeadowView.restRate }, "\(time), \(workspaces) workspaces, working \(working): \(Set(rates))")
            #expect(abs(view.pace - MeadowView.restPace) < 0.05)
        }
    }

    @Test("a change in the world ends the rest at the calm rate, not the full one, and it rests again")
    func changeEndsRestCalmly() {
        let (view, clock) = view(.night, workspaces: 5, working: false)
        run(view, clock, seconds: Double(MeadowView.restAfter) + 4)
        #expect(view.isResting)
        // A cat dozes off: drawn at once, at the calm rate (30 Hz), at the scene's own pace.
        view.world = world(5, working: false, napping: true)
        #expect(!view.isResting)
        let after = run(view, clock, seconds: 2)
        #expect(after.allSatisfy { $0 <= 30 }, "\(Set(after))")
        #expect(view.pace > 0.95)
        run(view, clock, seconds: Double(MeadowView.restAfter) + 2)
        #expect(view.isResting)
    }

    @Test("input brings the full rate back at once")
    func inputWakesFully() {
        let (view, clock) = view(.night, workspaces: 1, working: false)
        run(view, clock, seconds: Double(MeadowView.restAfter) + 4)
        #expect(view.isResting)
        view.simulateDrag(dx: 40, dy: 0)
        #expect(!view.isResting)
        #expect(view.targetRate == 60, "a test's view has no screen: 60 Hz is its fastest")
    }

    @Test("at the slow tick each frame moves the fireflies no further than a frame at 30 Hz does")
    func firefliesReadSmoothlyAtRest() {
        func steps(resting: Bool) -> (move: Float, glow: Float) {
            let (view, clock) = view(.night, workspaces: 3, working: false)
            run(view, clock, seconds: resting ? Double(MeadowView.restAfter) + 4 : 1)
            var move: Float = 0, glow: Float = 0
            var last = view.stage.meadow!.fireflies
            for _ in 0..<60 {
                if resting { run(view, clock, seconds: 1 / Double(MeadowView.restRate)) } else { view.step(1 / 30) }
                let now = view.stage.meadow!.fireflies
                for (a, b) in zip(last, now) where a.w > 0 && b.w > 0 {
                    move = max(move, simd_distance(Vec3(a.x, a.y, a.z), Vec3(b.x, b.y, b.z)))
                    glow = max(glow, abs(a.w - b.w))
                }
                last = now
            }
            #expect(!view.stage.meadow!.fireflies.allSatisfy { $0.w == 0 }, "fireflies are out at night")
            return (move, glow)
        }
        let rest = steps(resting: true), thirty = steps(resting: false)
        #expect(rest.move <= thirty.move * 1.15 + 0.005, "rest \(rest.move), 30 Hz \(thirty.move)")
        #expect(rest.glow <= thirty.glow * 1.15 + 0.01, "rest \(rest.glow), 30 Hz \(thirty.glow)")
    }
}
