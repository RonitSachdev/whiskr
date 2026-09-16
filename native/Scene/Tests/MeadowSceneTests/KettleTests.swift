import AppKit
import Foundation
import Testing
import UniformTypeIdentifiers
import simd
@_spi(Diagnostics) @testable import MeadowScene

// The camp kettle on a plain terminal's blanket (docs/DESIGN.md, "Plain terminals"): it stands cold while the
// shell waits, lights and steams while a command runs (rattling at first, then a steady simmer that lets the
// meadow rest), whistles once as a command ends well, is snuffed with a dark puff and a red flag when one
// fails, keeps every look with Reduce Motion or the animation off (still, but lit or not, flagged or not), and
// makes way for a cat when a Claude starts there, coming back once it has gone.

@MainActor
@Suite(.serialized) struct Kettles {
    static let size = NSSize(width: 480, height: 320)

    static func world(_ commands: [MeadowCommand], agents: [MeadowAgent] = []) -> MeadowWorld {
        MeadowWorld(machines: [MeadowMachine(id: "m", name: "m", spaces: [MeadowSpace(id: "s", name: "s", blankets: [
            MeadowBlanket(id: "shell", title: "shell", color: MeadowColor(hex: 0xa9a9ae), agents: agents,
                          lanterns: commands.enumerated().map { MeadowLantern(id: "t\($0.offset)", title: "zsh", state: $0.element == .running ? .running : .finished,
                                                                              command: $0.element) }),
        ])])])
    }

    static func view(_ commands: [MeadowCommand], time: MeadowSettings.TimeOfDay = .day, agents: [MeadowAgent] = []) -> MeadowView {
        let view = MeadowView(frame: NSRect(origin: .zero, size: size), mode: .meadow)
        view.settings = MeadowSettings(timeOfDay: time, picnic: .hamper)
        view.world = world(commands, agents: agents)
        view.advance(seconds: 0.5)
        view.frame(.blanket("shell"), besidePanelWidth: 0, animated: false)
        view.advance(seconds: 2)
        return view
    }

    static func kettle(_ view: MeadowView) -> KettlePlace { view.stage.village!.plots[0].kettle }

    @Test("a plain terminal's blanket has its kettle, cold while the shell waits; with no marks it stays so")
    func coldAtThePrompt() {
        let view = Self.view([.idle])
        let k = Self.kettle(view)
        #expect(k.shown.x > 0.98)
        #expect(k.flame == 0 && k.flag.x < 0.01)
        #expect(k.puffAlpha.allSatisfy { $0 == 0 }, "no steam from a cold kettle")
        // It stands on the cloth clear of the hamper.
        let plot = view.stage.village!.plots[0]
        for treat in plot.treats where treat.wanted {
            #expect(hypot(treat.spot.x - k.spot.x, treat.spot.z - k.spot.z) >= treat.reach + KETTLE_REACH - 0.01)
        }
    }

    @Test("a command running lights the flame, the kettle steams and its lid rattles; after a long while it simmers")
    func runningSteams() {
        let view = Self.view([.idle])
        view.world = Self.world([.running])
        var steamed = false, rattled = false
        for _ in 0..<120 {
            view.advance(seconds: 1.0 / 30)
            steamed = steamed || Self.kettle(view).puffAlpha.contains { $0 > 0.05 }
            rattled = rattled || Self.kettle(view).lidLift > 0.005
        }
        #expect(Self.kettle(view).flame > 0.95)
        #expect(steamed && rattled, "steam \(steamed), lid \(rattled)")
        #expect(!view.stage.village!.still, "boiling is under way")
        view.advance(seconds: Double(KETTLE_BOIL))
        let k = Self.kettle(view)
        #expect(k.simmering(view.stage.village!.time))
        #expect(abs(k.flame - 0.62) < 0.05, "a lower flame: \(k.flame)")
        var lifted: Float = 0
        for _ in 0..<60 { view.advance(seconds: 1.0 / 30); lifted = max(lifted, Self.kettle(view).lidLift) }
        #expect(lifted == 0, "a simmer does not rattle the lid")
        #expect(view.stage.village!.still, "a simmer lets the meadow rest")
    }

    @Test("a command that ran a while and ended well whistles once, then the flame goes out; one over in a moment does not whistle")
    func finishWhistles() {
        let view = Self.view([.running])
        view.advance(seconds: 3)
        view.world = Self.world([.finished])
        #expect(Self.kettle(view).whistleAt > -.infinity)
        view.advance(seconds: 0.3)
        #expect(Self.kettle(view).puffAlpha.filter { $0 > 0.05 }.count >= 3, "a jet of steam")
        #expect(Self.kettle(view).lidLift > 0, "the lid pops")
        view.advance(seconds: 2.5)
        #expect(Self.kettle(view).flame == 0)
        #expect(view.stage.village!.still)

        let quick = Self.view([.idle])
        quick.world = Self.world([.running])
        quick.advance(seconds: 0.2)
        quick.world = Self.world([.finished])
        #expect(Self.kettle(quick).whistleAt == -.infinity, "an ls does not whistle")
    }

    @Test("a command that fails snuffs the flame with a dark puff and puts up the red flag, until it is seen")
    func failurePutsUpTheFlag() {
        let view = Self.view([.running])
        view.advance(seconds: 2)
        view.world = Self.world([.failed])
        #expect(Self.kettle(view).snuffedAt > -.infinity)
        view.advance(seconds: 0.4)
        #expect(Self.kettle(view).smokeAlpha > 0.05, "a dark puff")
        view.advance(seconds: 2)
        #expect(Self.kettle(view).flame == 0)
        #expect(Self.kettle(view).flag.x > 0.95)
        #expect(view.stage.village!.still)
        // Seen: the failure is no longer news, and the flag goes.
        view.world = Self.world([.idle])
        view.advance(seconds: 1.5)
        #expect(Self.kettle(view).flag.x < 0.02)
    }

    @Test("one terminal running and another failed: the flame burns and the flag stands, both true at once")
    func runningAndFailedTogether() {
        let view = Self.view([.running, .failed])
        view.advance(seconds: 1)
        #expect(Self.kettle(view).flame > 0.9 && Self.kettle(view).flag.x > 0.9)
    }

    @Test("with Reduce Motion or the animation off nothing drifts, but lit, out and flagged still read",
          arguments: [true, false])
    func stillButStateDistinct(_ reduceMotion: Bool) {
        let view = Self.view([.idle])
        if reduceMotion { view.reduceMotion = true } else { view.animatesAmbient = false }
        view.world = Self.world([.running])
        view.advance(seconds: 1)
        let a = Self.kettle(view)
        view.advance(seconds: 0.5)
        let b = Self.kettle(view)
        #expect(b.flame > 0.9)
        #expect(b.puffAlpha.contains { $0 > 0.2 }, "a still wisp of steam says it is on")
        #expect(a.puffs == b.puffs && b.lidLift == 0, "nothing moves")
        view.world = Self.world([.finished])
        #expect(Self.kettle(view).whistleAt == -.infinity, "no whistle")
        view.advance(seconds: 1.5)
        #expect(Self.kettle(view).flame == 0 && Self.kettle(view).puffAlpha.allSatisfy { $0 == 0 })
        view.world = Self.world([.failed])
        view.advance(seconds: 1.0 / 60)
        #expect(Self.kettle(view).flag.x == 1, "the flag is there at once")
    }

    @Test("a Claude starting there: the kettle makes way for the cat; the Claude gone, the kettle comes back")
    func makesWayForTheCat() {
        let view = Self.view([.running])
        view.world = Self.world([], agents: [MeadowAgent(id: "main", activity: .reading)])
        view.advance(seconds: 0.6)
        #expect(Self.kettle(view).shown.x < 0.02, "gone: \(Self.kettle(view).shown.x)")
        view.advance(seconds: 2)
        view.world = Self.world([.idle])
        // Never among the leaving cat's last hop: it grows only once the cat has gone.
        var among = 0
        for _ in 0..<180 {
            view.advance(seconds: 1.0 / 60)
            if !view.stage.village!.plots[0].actors.isEmpty && Self.kettle(view).shown.x > 0.01 { among += 1 }
        }
        #expect(among == 0, "\(among) frames with both")
        #expect(view.stage.village!.plots[0].actors.isEmpty)
        #expect(Self.kettle(view).shown.x > 0.98, "back once the cat has gone")
        #expect(Self.kettle(view).flame == 0, "and cold: a Claude ending is not a command finishing")
    }

    @Test("a blanket with a cat on it has no kettle, whatever its other terminals do")
    func noKettleBesideACat() {
        let view = Self.view([.running, .failed], agents: [MeadowAgent(id: "main", activity: .idle)])
        #expect(Self.kettle(view).shown.x < 0.01)
    }

    @Test("a simmering kettle lets the meadow rest at its slow tick")
    func simmerRests() {
        final class Clock { var now: CFTimeInterval = 1000 }
        let clock = Clock()
        let view = MeadowView(frame: NSRect(x: 0, y: 0, width: 360, height: 800), mode: .meadow)
        view.clock = { clock.now }
        view.keepsFullRateWhenInactive = true
        view.settings = MeadowSettings(arrangement: .column, timeOfDay: .night, picnic: .hamper)
        view.world = Self.world([.running])
        let total = Double(KETTLE_BOIL) + Double(MeadowView.restAfter) + 6
        var elapsed = 0.0
        var rates: [Int] = []
        while elapsed < total {
            let dt = 1 / Double(view.targetRate)
            clock.now += dt
            elapsed += dt
            view.step(Float(dt))
            view.updateRate()
            // Once the first moments' input-like start is over (a new view draws at full rate for a few seconds).
            if elapsed > 5 { rates.append(view.targetRate) }
        }
        #expect(view.isResting, "simmering, the meadow rests")
        #expect(rates.suffix(24).allSatisfy { $0 == MeadowView.restRate })
        // While it boiled it never asked for more than the calm rate.
        #expect(rates.allSatisfy { $0 <= 30 }, "\(Set(rates))")
    }

    // MARK: Pictures

    static func save(_ view: MeadowView, _ name: String) {
        guard let dir = ProcessInfo.processInfo.environment["MEADOW_SNAPSHOTS"] else { return }
        let w = Int(view.bounds.width * 2), h = Int(view.bounds.height * 2)
        guard let image = view.renderImage(width: w, height: h) else { return }
        let url = URL(fileURLWithPath: dir).appendingPathComponent(name + ".png")
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
    }

    /// Pictures to look at, written only when asked for: each state, close up, by day and by night.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MEADOW_SNAPSHOTS"] != nil))
    func snapshots() {
        for time in [MeadowSettings.TimeOfDay.day, .night] {
            let label = time == .day ? "day" : "night"
            let idle = Self.view([.idle], time: time)
            idle.simulateZoom(by: 0.45, at: CGPoint(x: Self.size.width / 2, y: Self.size.height / 2))
            idle.advance(seconds: 1)
            Self.save(idle, "kettle-idle-\(label)")
            idle.world = Self.world([.running])
            idle.advance(seconds: 1.3)
            Self.save(idle, "kettle-running-\(label)")
            idle.advance(seconds: Double(KETTLE_BOIL))
            Self.save(idle, "kettle-simmer-\(label)")
            idle.world = Self.world([.finished])
            idle.advance(seconds: 0.25)
            Self.save(idle, "kettle-whistle-\(label)")
            idle.advance(seconds: 2)
            Self.save(idle, "kettle-finished-\(label)")
            idle.world = Self.world([.running])
            idle.advance(seconds: 2)
            idle.world = Self.world([.failed])
            idle.advance(seconds: 0.3)
            Self.save(idle, "kettle-snuffed-\(label)")
            idle.advance(seconds: 2)
            Self.save(idle, "kettle-failed-\(label)")
        }
        // As the app's sidebar shows them: four plain workspaces in each state, under one with a Claude.
        for time in [MeadowSettings.TimeOfDay.day, .night] {
            let view = MeadowView(frame: NSRect(x: 0, y: 0, width: 360, height: 820), mode: .meadow)
            view.settings = MeadowSettings(arrangement: .column, timeOfDay: time, picnic: .hamper)
            func blanket(_ id: String, _ command: MeadowCommand) -> MeadowSpace {
                MeadowSpace(id: id, name: id, blankets: [MeadowBlanket(id: id, title: id, color: MeadowColor(hex: 0xa9a9ae),
                                                                     lanterns: [MeadowLantern(id: "t", state: command == .running ? .running : .finished, command: command)])])
            }
            view.world = MeadowWorld(machines: [MeadowMachine(id: "m", name: "m", spaces: [
                MeadowSpace(id: "cat", name: "cat", blankets: [MeadowBlanket(id: "cat", title: "with Claude", color: .account(0), agents: [MeadowAgent(id: "main", activity: .reading)])]),
                blanket("waiting", .idle), blanket("running", .running), blanket("finished", .finished), blanket("failed", .idle),
            ])])
            view.advance(seconds: 3)
            view.world.machines[0].spaces[4].blankets[0].lanterns[0].command = .running
            view.advance(seconds: 2)
            view.world.machines[0].spaces[4].blankets[0].lanterns[0].command = .failed
            view.advance(seconds: 1.5)
            Self.save(view, "kettle-sidebar-\(time == .day ? "day" : "night")")
        }
    }
}
