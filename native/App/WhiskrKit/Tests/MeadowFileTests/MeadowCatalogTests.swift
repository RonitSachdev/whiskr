import Foundation
import Testing
@testable import MeadowFile

// The catalog's rules: an id once released means that thing forever, renames go through aliases, and
// everything carries the catalog it came in.

@Suite("Meadow files: catalog")
struct MeadowCatalogTests {
    /// Every id ever released, with the catalog it came in. Only ever added to: an id here must stay in
    /// the catalog for good (retiring takes it out of the tray, never out of the catalog).
    static let released: [String: Int] = [
        "tree.oak": 1, "tree.birch": 1, "tree.cherry": 1, "tree.young": 1, "tree.apple": 1, "tree.pine": 1,
        "flower.daisy": 1, "flower.buttercup": 1, "flower.lupin": 1, "flower.poppy": 1, "flower.cornflower": 1, "flower.foxglove": 1,
        "plant.fern": 1, "plant.clover": 1, "fungus.flyAgaric": 1,
        "stone.stone": 1, "stone.mossy": 1, "stone.boulder": 1, "stone.stepping": 1,
        "wood.fallenLog": 1, "wood.stump": 1, "wood.logPile": 1,
        "ground.path": 1, "ground.lawn": 1, "ground.soil": 1, "ground.wild": 1,
        "garden.fence": 1, "garden.flowerPot": 1, "garden.planter": 1, "garden.wateringCan": 1, "garden.birdhouse": 1, "garden.skep": 1,
        "work.desk": 1, "work.cushion": 1, "work.bookshelf": 1, "work.bench": 1, "work.signpost": 1, "work.mailbox": 1,
        "work.noticeboard": 1, "work.lampPost": 1, "place.shed": 1, "place.tent": 1,
        "cat.box": 1, "cat.scratchingPost": 1, "cat.yarn": 1, "cat.bed": 1, "cat.bowl": 1,
    ]

    /// Every alias ever released. Only ever added to.
    static let releasedAliases: [String: String] = [:]

    let catalog = MeadowCatalog.current

    @Test("no released id is ever removed or moved to another catalog, and every id is new or released")
    func released() {
        for (id, since) in Self.released {
            #expect(catalog.asset(id)?.since == since, "\(id)")
            #expect(catalog.asset(id)?.id == id, "\(id) is not an alias")
        }
        for asset in catalog.assets where Self.released[asset.id] == nil {
            #expect(asset.since == catalog.number, "\(asset.id) is new, so it is from this catalog")
        }
        for (old, new) in Self.releasedAliases { #expect(catalog.aliases[old] == new, "\(old)") }
    }

    @Test("ids are unique and well-formed")
    func ids() {
        let ids = catalog.assets.map(\.id)
        #expect(Set(ids).count == ids.count)
        for id in ids { #expect(MeadowCatalog.isWellFormed(id), "\(id)") }
        for bad in ["", "tree", "Tree.oak", "tree.", ".oak", "tree..oak", "tree.o-ak", "tree.oak!", "ねこ.oak", "a." + String(repeating: "b", count: 63)] {
            #expect(!MeadowCatalog.isWellFormed(bad), "\(bad)")
        }
        #expect(MeadowCatalog.isWellFormed("cat.scratchingPost") && MeadowCatalog.isWellFormed("a.b.c9"))
    }

    @Test("every alias points to a live id, and no alias is itself an id")
    func aliases() {
        for catalog in [catalog, CatalogTwo.catalog] {
            for (old, new) in catalog.aliases {
                #expect(catalog.assets.contains { $0.id == new }, "\(old) → \(new)")
                #expect(!catalog.assets.contains { $0.id == old }, "\(old)")
                #expect(MeadowCatalog.isWellFormed(old))
            }
        }
        #expect(CatalogTwo.catalog.asset("tree.appleTree")?.id == "tree.apple")
        #expect(CatalogTwo.catalog.currentId("tree.appleTree") == "tree.apple" && CatalogTwo.catalog.currentId("tree.oak") == "tree.oak")
    }

    @Test("everything carries a since no newer than its catalog, and no older than what holds it")
    func since() {
        for asset in catalog.assets {
            #expect((1...catalog.number).contains(asset.since), "\(asset.id)")
            #expect(asset.variants.first == asset.since, "\(asset.id)'s first shape")
            #expect(zip(asset.variants, asset.variants.dropFirst()).allSatisfy { $0 <= $1 }, "\(asset.id)'s shapes")
            #expect(asset.variants.allSatisfy { $0 <= catalog.number })
            for parameter in asset.parameters {
                #expect(parameter.since >= asset.since && parameter.since <= catalog.number, "\(asset.id).\(parameter.name)")
                if case .choice(let choices) = parameter.kind {
                    #expect(choices.first?.since == parameter.since, "\(asset.id).\(parameter.name)'s default")
                    #expect(choices.allSatisfy { $0.since >= parameter.since && $0.since <= catalog.number })
                }
            }
        }
    }

    @Test("parameters: unique names, defaults in range, palettes of 4–8 swatches")
    func parameters() {
        for asset in catalog.assets {
            #expect(Set(asset.parameters.map(\.name)).count == asset.parameters.count, "\(asset.id)")
            for parameter in asset.parameters {
                switch parameter.kind {
                case .integer(let range, let fallback):
                    #expect(range.contains(fallback), "\(asset.id).\(parameter.name)")
                case .choice(let choices):
                    #expect(Set(choices.map(\.name)).count == choices.count, "\(asset.id).\(parameter.name)")
                    if parameter.name == "colour" { #expect((4...8).contains(choices.count), "\(asset.id)'s palette") }
                }
            }
        }
    }

    @Test("living things grow within a range holding 1; made things never scale; runs and paints take no transform")
    func natures() {
        for asset in catalog.assets {
            if let size = asset.size { #expect(size.contains(1) && size.lowerBound > 0, "\(asset.id)") }
            if let tilt = asset.tilt { #expect(tilt > 0 && tilt < 0.5, "\(asset.id)") }
            switch asset.nature {
            case .living: #expect(asset.size != nil && asset.tilt != nil, "\(asset.id)")
            case .made: #expect(asset.size == nil && asset.tilt == nil && !asset.seeded, "\(asset.id)")
            case .paint, .eraser:
                #expect(asset.size == nil && asset.tilt == nil && !asset.seeded && asset.parameters.isEmpty && asset.caps.isEmpty, "\(asset.id)")
                #expect(asset.category == .ground)
            case .natural: break
            }
            if asset.shape == .run { #expect(asset.size == nil && asset.tilt == nil && !asset.seeded && asset.variants.count == 1, "\(asset.id)") }
        }
        #expect(catalog.assets.filter { $0.nature == .eraser }.map(\.id) == ["ground.wild"])
    }

    @Test("caps: every tree counts as a tree and as tall; lamps, fences and made things each count toward their own")
    func caps() {
        for asset in catalog.assets {
            if asset.category == .trees { #expect(asset.caps.contains(.trees) && asset.caps.contains(.tall), "\(asset.id)") }
            if asset.nature == .made {
                let own = asset.caps.filter { [.lamps, .fencePosts, .madeThings].contains($0) }
                #expect(own.count == 1, "\(asset.id) counts toward exactly one made-thing cap")
            }
        }
        #expect(catalog.asset("work.lampPost")?.caps.contains(.lamps) == true)
        #expect(catalog.asset("garden.fence")?.caps == [.fencePosts])
        let tall = Set(catalog.assets.filter { $0.caps.contains(.tall) }.map(\.id))
        #expect(tall == ["tree.oak", "tree.birch", "tree.cherry", "tree.young", "tree.apple", "tree.pine", "wood.fallenLog", "garden.birdhouse",
                         "work.bookshelf", "work.lampPost", "place.shed", "place.tent"])
    }

    @Test("fence posts: one at the start, one at least every 2.5 units, one at each bend")
    func posts() {
        #expect(MeadowCatalog.posts(along: [MeadowPoint(0, 0), MeadowPoint(2.5, 0)]) == 2)
        #expect(MeadowCatalog.posts(along: [MeadowPoint(0, 0), MeadowPoint(2.6, 0)]) == 3)
        #expect(MeadowCatalog.posts(along: [MeadowPoint(0, 0), MeadowPoint(0, 0)]) == 2)
        #expect(MeadowCatalog.posts(along: [MeadowPoint(0, 0), MeadowPoint(10, 0), MeadowPoint(10, 1)]) == 6)
    }

    @Test("the migration chain reaches this format from every older one")
    func chain() {
        for major in 1..<MeadowFormat.major { #expect(MeadowMigration.current.formatSteps[major] != nil, "v\(major)to\(major + 1)") }
        #expect(MeadowMigration.current.formatSteps.keys.allSatisfy { $0 < MeadowFormat.major })
        #expect(MeadowMigration.current.catalogSteps.keys.allSatisfy { $0 <= catalog.number })
    }
}
