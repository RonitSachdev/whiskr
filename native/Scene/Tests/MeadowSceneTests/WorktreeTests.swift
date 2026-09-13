import AppKit
import Foundation
import Testing
import simd
@testable import MeadowScene

// A git worktree's blanket belongs to its repository's: laid beside it, joined by a path of stepping
// stones. In a sidebar's column it sits in the next row, set in, the path running down beside it and
// turning in; elsewhere it lies next to its repository. Nothing else moves for it.

@MainActor
@Suite(.serialized) struct Worktrees {
    /// shop (repository), then two of its worktrees, then api; with `joined` false, the same blankets
    /// with nothing joined.
    func world(joined: Bool = true, missing: Bool = false) -> MeadowWorld {
        func space(_ id: String, _ color: Int, joinedTo: String? = nil) -> MeadowSpace {
            MeadowSpace(id: id, name: id, blankets: [MeadowBlanket(id: id, title: id, color: .account(color),
                                                                   agents: [MeadowAgent(id: "c", activity: .reading)], joinedTo: joined ? joinedTo : nil)])
        }
        return MeadowWorld(machines: [MeadowMachine(id: "m", name: "m", spaces: [
            space("shop", 0), space("cart", 1, joinedTo: missing ? "gone" : "shop"), space("tax", 2, joinedTo: missing ? "gone" : "shop"), space("api", 3),
        ])])
    }

    func view(_ size: NSSize, arrangement: MeadowSettings.Arrangement, world: MeadowWorld) -> MeadowView {
        let view = MeadowView(frame: NSRect(origin: .zero, size: size), mode: .meadow)
        view.settings = MeadowSettings(arrangement: arrangement, timeOfDay: .day, picnic: .hamper)
        view.world = world
        view.frame(nil, besidePanelWidth: 0, animated: false)
        view.advance(seconds: 3)
        return view
    }

    /// The gap of grass between two blankets' cloths, along the line between their middles.
    func gap(_ village: Village, _ a: Plot, _ b: Plot) -> Float {
        let d = Vec2(b.middle.x - a.middle.x, b.middle.z - a.middle.z)
        let n = simd_normalize(d)
        return simd_length(d) - village.edge(a, n) - village.edge(b, -n)
    }

    @Test("a column: the worktree's row follows its repository's, closer and set in")
    func columnNests() throws {
        let joined = view(NSSize(width: 300, height: 820), arrangement: .column, world: world()).stage.village!
        let plain = view(NSSize(width: 300, height: 820), arrangement: .column, world: world(joined: false)).stage.village!
        #expect(joined.perRow == 1)
        let shop = try #require(joined.plot("shop")), cart = try #require(joined.plot("cart")), tax = try #require(joined.plot("tax"))
        let plainShop = try #require(plain.plot("shop")), plainCart = try #require(plain.plot("cart"))
        // Closer below its repository than an unrelated row would be.
        #expect(cart.at!.y - shop.at!.y < plainCart.at!.y - plainShop.at!.y - 0.5)
        // Set in from its repository, toward the middle of the column; both worktrees alike.
        #expect(abs(cart.at!.x - shop.at!.x) > 1)
        #expect(abs(cart.at!.x - tax.at!.x) < 1e-3)
        // The order is kept, top to bottom.
        let order = joined.plots.map(\.view.id)
        #expect(order == ["shop", "cart", "tax", "api"])
        let zs = joined.plots.map { $0.at!.y }
        #expect(zs == zs.sorted())
    }

    @Test("a picnic: the worktree lies beside its repository, nearer it than anything else")
    func picnicBeside() throws {
        let village = view(NSSize(width: 1280, height: 800), arrangement: .picnic, world: world()).stage.village!
        let shop = try #require(village.plot("shop"))
        for id in ["cart", "tax"] {
            let plot = try #require(village.plot(id))
            let toShop = gap(village, shop, plot)
            #expect(toShop < 5, "\(id) is \(toShop) from its repository")
            #expect(toShop > 0.5, "\(id) overlaps its repository")
            let api = try #require(village.plot("api"))
            #expect(gap(village, api, plot) > toShop, "\(id) is nearer api than its repository")
        }
    }

    @Test("paths run from cloth edge to cloth edge, and no stone lies on a cloth or under a flag",
          arguments: [MeadowSettings.Arrangement.column, .picnic])
    func pathsJoinEdges(_ arrangement: MeadowSettings.Arrangement) throws {
        let size = arrangement == .column ? NSSize(width: 300, height: 820) : NSSize(width: 1280, height: 800)
        let village = view(size, arrangement: arrangement, world: world()).stage.village!
        let shop = try #require(village.plot("shop"))
        for id in ["cart", "tax"] {
            let plot = try #require(village.plot(id))
            let (start, end) = try #require(plot.trailEnds)
            // The first worktree's path leaves its repository's cloth; the second's carries on from it.
            if id == "cart" || arrangement == .picnic {
                let out = start - Vec2(shop.middle.x, shop.middle.z)
                let past = simd_length(out) - village.edge(shop, simd_normalize(out))
                #expect(past > 0 && past < 0.8, "\(id)'s path starts \(past) off its repository's cloth")
            }
            let back = end - Vec2(plot.middle.x, plot.middle.z)
            let off = simd_length(back) - village.edge(plot, simd_normalize(back))
            #expect(off > 0 && off < 0.8, "\(id)'s path ends \(off) off its cloth")
        }
        #expect(village.stoneCount >= 4)
        for i in 0..<village.stoneCount {
            let s = village.stones[i]
            for plot in village.plots {
                let d = Vec2(s.x - plot.middle.x, s.y - plot.middle.z)
                #expect(simd_length(d) > village.edge(plot, simd_normalize(d)), "a stone on \(plot.view.id)'s cloth")
                if arrangement == .column {
                    let half = plot.flagHeight * plot.label.aspect / 2
                    #expect(!(abs(s.x - plot.flagAt.x) < half && abs(s.y - plot.flagAt.z) < 0.4), "a stone under \(plot.view.id)'s flag")
                }
            }
        }
        #expect(village.troddenCount > 0)
    }

    @Test("a second worktree's path carries on down the first one's in a column")
    func sharedPath() throws {
        let village = view(NSSize(width: 300, height: 820), arrangement: .column, world: world()).stage.village!
        let tax = try #require(village.plot("tax")?.trailEnds)
        let cart = try #require(village.plot("cart")), shop = try #require(village.plot("shop"))
        // The second starts where the first turned in: level with the first worktree, beside it on the inner side.
        #expect(abs(tax.0.y - cart.middle.z) < 0.01)
        let side: Float = cart.middle.x > shop.middle.x ? 1 : -1
        #expect((cart.middle.x - tax.0.x) * side > village.edge(cart, Vec2(-side, 0)))
    }

    @Test("joined to a blanket that is not there: laid and drawn as if not joined")
    func missingRepository() {
        let missing = view(NSSize(width: 300, height: 820), arrangement: .column, world: world(missing: true)).stage.village!
        let plain = view(NSSize(width: 300, height: 820), arrangement: .column, world: world(joined: false)).stage.village!
        #expect(missing.plots.map(\.at) == plain.plots.map(\.at))
        #expect(missing.stoneCount == 0)
        #expect(missing.plots.allSatisfy { $0.trailEnds == nil })
    }
}
