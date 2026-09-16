import Foundation
@testable import MeadowFile

/// The fixture files, one per format version and catalog. Never edited once released: a new version
/// adds new files (`MeadowFixtureTests` holds each released file's digest).
enum Fixtures {
    static let folder = Bundle.module.resourceURL!.appendingPathComponent("Fixtures/MeadowFiles", isDirectory: true)

    static func data(_ name: String) throws -> Data {
        try Data(contentsOf: folder.appendingPathComponent(name))
    }
}

/// A stand-in for the next catalog, to see a newer Whiskr's meadow in this one and back: a still pond,
/// a bench that comes long, a lavender bench, a third daisy, gravel paint, and the apple tree's old name.
enum CatalogTwo {
    static let catalog: MeadowCatalog = {
        var assets = MeadowCatalog.one.assets.map { asset -> MeadowAsset in
            switch asset.id {
            case "work.bench":
                let colours = MeadowParameter("colour", .choice(["wood", "sage", "cream", "slate"].map { .init($0) } + [.init("lavender", since: 2)]))
                let length = MeadowParameter("length", since: 2, .choice([.init("short", since: 2), .init("long", since: 2)]))
                return MeadowAsset(asset.id, asset.category, asset.nature, parameters: [colours, length], caps: asset.caps)
            case "flower.daisy":
                return MeadowAsset(asset.id, asset.category, asset.nature, size: asset.size, tilt: asset.tilt, variants: [1, 1, 2])
            default:
                return asset
            }
        }
        assets.append(MeadowAsset("water.pond", since: 2, .garden, .natural))
        assets.append(MeadowAsset("ground.gravel", since: 2, .ground, .paint))
        return MeadowCatalog(number: 2, assets: assets, aliases: ["tree.appleTree": "tree.apple"])
    }()
}

/// The same numbers every run.
struct SplitMix: RandomNumberGenerator {
    var state: UInt64
    init(_ seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

extension MeadowDocument {
    /// What reading `fileData` gives, without the file's own provenance.
    func throughFile(_ catalog: MeadowCatalog = .current) throws -> MeadowDocument {
        var back = try MeadowDocument.read(fileData(writtenBy: "0.1.0", catalog: catalog), catalog: catalog).document
        back.readFrom = nil
        return back
    }
}

/// A meadow built from a document's text (for small hand-written cases).
func meadow(_ items: String, extra: String = "") -> Data {
    Data(#"{ "whiskrMeadow": 1, "items": [\#(items)]\#(extra.isEmpty ? "" : ", " + extra) }"#.utf8)
}

/// The error reading `data` throws, or nil.
func readError(_ data: Data, catalog: MeadowCatalog = .current) -> MeadowFileError? {
    do {
        _ = try MeadowDocument.read(data, catalog: catalog)
        return nil
    } catch let error as MeadowFileError {
        return error
    } catch {
        return nil
    }
}

/// The meadow with every catalog-1 thing and option in it, as the `v1-catalog1-everything` fixture
/// holds it: the golden model that fixture must read as.
enum Everything {
    static let document: MeadowDocument = {
        func at(_ x: Double, _ z: Double) -> MeadowItem.Placement { .at(MeadowPoint(x, z)) }
        var items: [MeadowItem] = []
        var x = -60.0
        // One of each single thing, in catalog order, along a line; every field each one takes.
        for asset in MeadowCatalog.one.assets where asset.shape == .single && asset.nature != .paint && asset.nature != .eraser {
            var item = MeadowItem(asset: asset.id, placement: at(x, 40), turn: 0.7854)
            if asset.size != nil { item.size = [1.04, 0.97, 1] }
            if asset.tilt != nil { item.tilt = [0.02, -0.03] }
            if asset.seeded { item.seed = 3_141_592_653 }
            if asset.variants.count > 1 { item.variant = asset.variants.count - 1 }
            for parameter in asset.parameters {
                if case .choice(let choices) = parameter.kind { item.params[parameter.name] = .string(choices.last!.name) }
            }
            items.append(item)
            x += 3
        }
        items.append(MeadowItem(asset: "garden.fence", placement: .run([MeadowPoint(30, 5), MeadowPoint(32.5, 5), MeadowPoint(35, 6.2)]),
                                params: ["gate": .number("1")]))
        // A plain daisy: nothing but its spot.
        items.append(MeadowItem(asset: "flower.daisy", placement: at(-3.1, -7.4)))
        var ground = GroundGrid()
        let path = ground.index(of: "ground.path")!, lawn = ground.index(of: "ground.lawn")!, soil = ground.index(of: "ground.soil")!
        for column in 200..<300 { ground[column, 256] = path; ground[column, 257] = path }
        for row in 100..<120 { for column in 100..<140 { ground[column, row] = lawn } }
        for row in 300..<310 { for column in 310..<330 { ground[column, row] = soil } }
        return MeadowDocument(name: "Everything", author: "Whiskr", description: "Every thing and option in catalog 1.",
                              entries: items.map { .item($0) }, ground: ground)
    }()
}

/// The processor time the calling thread spends running `body`: what a piece of work costs, the same
/// while other tests load the Mac (as `WhiskrKitTests`' speed tests measure it).
func threadTime(_ body: () throws -> Void) rethrows -> Duration {
    func now() -> Duration {
        var time = timespec()
        clock_gettime(CLOCK_THREAD_CPUTIME_ID, &time)
        return .seconds(time.tv_sec) + .nanoseconds(time.tv_nsec)
    }
    let start = now()
    try body()
    return now() - start
}
