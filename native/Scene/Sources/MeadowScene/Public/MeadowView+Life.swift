import Foundation
import simd

// What the app's checks and pictures read and set of the cats' lives off their blankets and the kettles
// (`Roam.swift`, `Kettle.swift`); a shipped app never calls these.
extension MeadowView {
    /// Asks one cat for an outing now, rather than after its rest and of its own choosing: a stop out in the grass
    /// off its blanket, reached in bounds (so it hops), then home. It sets off once it is at leisure on its blanket.
    /// False for no such cat, or one already out.
    @_spi(Diagnostics) public func sendOut(_ item: MeadowItem) -> Bool {
        guard case .cat(let b, let a) = item, let village = stage.village, let actor = village.actor(b, a), actor.roam.phase == .home else { return false }
        actor.roam.asked = true
        actor.roam.rested = village.clock
        wake()
        return true
    }

    /// Every cat at leisure dozes off now rather than after its minutes up and about.
    @_spi(Diagnostics) public func letCatsDozeOff() {
        stage.village?.letCatsDozeOff()
        wake()
    }

    /// The kind of thing a cat is at or going to (`cat.bed`, `wood.stump`), nil for none.
    @_spi(Diagnostics) public func catSpot(_ item: MeadowItem) -> String? {
        guard case .cat(let b, let a) = item, let village = stage.village, let i = village.actor(b, a)?.roam.spot, i < village.places.count else { return nil }
        return village.places[i].id
    }

    /// A cat's life off its blanket: out in the grass, running home for work, asleep out there; nil for no
    /// such cat.
    @_spi(Diagnostics) public func roaming(_ item: MeadowItem) -> (out: Bool, running: Bool, asleep: Bool, hopping: Bool)? {
        guard case .cat(let b, let a) = item, let actor = stage.village?.actor(b, a) else { return nil }
        return (actor.roam.out, actor.roam.phase == .recalled || actor.roam.phase == .settling, actor.roam.phase == .asleep,
                actor.cat.gait == .bound && actor.cat.height > 0)
    }

    /// What a cat has done out in the grass so far: stops reached off its blanket's cloth, hops made. Counts
    /// that only grow, so a check waits on them changing.
    @_spi(Diagnostics) public func outings(_ item: MeadowItem) -> (grassStops: Int, hops: Int)? {
        guard case .cat(let b, let a) = item, let actor = stage.village?.actor(b, a) else { return nil }
        return (actor.roam.grassStops, actor.roam.hops)
    }

    /// A blanket's kettle as drawn: how much of it shows, its flame, its flag and whether steam is rising.
    @_spi(Diagnostics) public func kettle(_ blanket: String) -> (shown: Float, flame: Float, flag: Float, steaming: Bool)? {
        guard let k = stage.village?.plot(blanket)?.kettle else { return nil }
        return (k.shown.x, k.flame, k.flag.x, k.puffAlpha.contains { $0 > 0.05 })
    }

    /// Starts one of a cat's fidgets now (`wash`, `stretch`, `nibble`, `sip`), for pictures of it.
    @_spi(Diagnostics) public func fidget(_ item: MeadowItem, _ name: String) {
        stage.cat(for: item)?.fidget(name)
        wake()
    }
}
