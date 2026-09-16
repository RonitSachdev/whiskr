import Foundation
import Testing
import simd
@testable import MeadowScene

// The cat's eyes are round whenever it is awake (docs/DESIGN.md, "The cat"): no half-shut look while it washes,
// stretches, nibbles, sips its tea, lies as a loaf or squints into a gust. Only a quick blink, the eyes shut
// in sleep (closing in one unbroken movement as it dozes off) and the squeeze shut of being petted close them.

@MainActor
@Suite struct RoundEyes {
    /// Runs a cat for `seconds` at 60 Hz and gives the least its eyes were meant to be open (blinks aside).
    func leastOpen(_ cat: Cat, seconds: Float, around: Surroundings = Surroundings()) -> Float {
        var least: Float = 1
        for _ in 0..<Int(seconds * 60) {
            cat.update(1 / 60, around)
            least = min(least, cat.eyesOpen)
        }
        return least
    }

    @Test("awake, through every fidget (wash, stretch, nibble, a sip of tea, wiggle, a look round), the eyes stay round")
    func fidgetsKeepEyesRound() {
        // Long enough for each cat to go through a dozen fidgets; several cats, so every kind comes up.
        for seed in ["a", "b", "c", "d"] {
            let cat = Cat(seed: seed)
            cat.setActivity(.awake)
            #expect(leastOpen(cat, seconds: 180) > 0.98, "cat \(seed)")
        }
    }

    @Test("lying as a loaf, thinking, or supervising over a cup of tea (its sips too), the eyes stay round",
          arguments: [AgentActivity.idle, .thinking, .supervising, .reading, .editing, .running, .searching, .tidying])
    func statesKeepEyesRound(_ activity: AgentActivity) {
        let cat = Cat(seed: "s")
        cat.setActivity(activity)
        #expect(leastOpen(cat, seconds: 20) > 0.98, "\(activity)")
    }

    @Test("a strong gust presses the ears back but leaves the eyes round")
    func gustLeavesEyesRound() {
        var around = Surroundings()
        around.gust = { _, _ in 1 }
        let cat = Cat(seed: "g")
        cat.setActivity(.awake)
        #expect(leastOpen(cat, seconds: 8, around: around) > 0.98)
    }

    @Test("dozing off, the eyes close in one unbroken movement, never held half shut, and stay shut")
    func dozingOffClosesSmoothly() {
        let cat = Cat(seed: "n")
        cat.setActivity(.idle)
        _ = leastOpen(cat, seconds: 2)
        cat.setActivity(.napping)
        var last = cat.eyesOpen, held = 0
        for _ in 0..<90 {
            cat.update(1 / 60, Surroundings())
            #expect(cat.eyesOpen <= last + 1e-4, "the eyes never open again on the way to sleep")
            // Half shut and not closing: held there.
            if cat.eyesOpen > 0.3 && cat.eyesOpen < 0.7 && last - cat.eyesOpen < 0.004 { held += 1 }
            last = cat.eyesOpen
        }
        #expect(held == 0, "held half shut for \(held) frames")
        #expect(cat.eyesOpen < 0.15, "asleep with its eyes shut: \(cat.eyesOpen)")
    }

    @Test("petted, the eyes squeeze shut")
    func pettingSqueezesShut() {
        let cat = Cat(seed: "p")
        cat.setActivity(.awake)
        cat.petting = true
        #expect(leastOpen(cat, seconds: 1) < 0.3)
    }
}
