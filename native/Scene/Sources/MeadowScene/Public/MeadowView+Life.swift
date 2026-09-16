import Foundation
import simd

// What the app's checks and pictures read and set of the cats' lives off their blankets and the kettles
// (`Roam.swift`, `Kettle.swift`); a shipped app never calls these.
extension MeadowView {
    /// Every cat with nothing to do sets off now, rather than after its rest.
    @_spi(Diagnostics) public func sendCatsOut() {
        guard let village = stage.village else { return }
        for plot in village.plots { for actor in plot.actors.values where actor.roam.phase == .home { actor.roam.until = village.time } }
        wake()
    }

    /// A cat's life off its blanket: out in the grass, running home for work, asleep out there; nil for no
    /// such cat.
    @_spi(Diagnostics) public func roaming(_ item: MeadowItem) -> (out: Bool, running: Bool, asleep: Bool, hopping: Bool)? {
        guard case .cat(let b, let a) = item, let actor = stage.village?.actor(b, a) else { return nil }
        return (actor.roam.out, actor.roam.phase == .recalled || actor.roam.phase == .settling, actor.roam.phase == .asleep,
                actor.cat.gait == .bound && actor.cat.height > 0)
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
