import Testing
@testable import MeadowScene

/// How often the meadow draws: never more than the window needs, and gently less while someone types
/// beside it.
@MainActor
@Suite("Frame rate")
struct FrameRateTests {
    func rate(fastest: Int = 120, key: Bool = true, calm: Bool = false, resting: Bool = false, yielding: Bool = false, cap: Int? = nil) -> Int {
        MeadowView.frameRate(fastest: fastest, key: key, calm: calm, resting: resting, yielding: yielding, displayCap: cap)
    }

    @Test func fullRateWhileLively() {
        #expect(rate() == 120)
        #expect(rate(fastest: 60) == 60)
    }

    @Test func thirtyWhenCalmOrBehind() {
        #expect(rate(calm: true) == 30)
        #expect(rate(key: false) == 30)
    }

    @Test func restingIsSlowest() {
        #expect(rate(calm: true, resting: true) == MeadowView.restRate)
        #expect(rate(resting: true, yielding: true) == MeadowView.restRate)
    }

    @Test func typingBesideItCapsTheRate() {
        #expect(rate(yielding: true) == MeadowView.yieldRate)
        #expect(rate(key: false, yielding: true) == 30)
    }

    @Test func neverAboveWhatTheDisplayGives() {
        #expect(rate(cap: 60) == 60)
        #expect(rate(yielding: true, cap: 24) == 24)
    }
}
