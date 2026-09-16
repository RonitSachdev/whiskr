import Foundation
import MeadowFile
import MeadowScene

// A meadow document (`MeadowFile`) as the scene's scenery, and back. The document keeps everything a
// file held; the scenery is only what the scene draws. Things the scene cannot draw (from a newer Whiskr,
// or catalog ids whose builders come in a later stage) stay in the document and are left out of the
// picture, as the scene leaves out any id it does not draw.

extension MeadowScenery {
    /// The things of `document` the scene could draw, in its order: every known thing standing at a spot
    /// (runs, such as fences, have no scenery form yet), drawn with the shape this Whiskr has.
    public init(_ document: MeadowDocument, catalog: MeadowCatalog = .current) {
        var things: [Thing] = []
        for item in document.items {
            guard case .at(let at) = item.placement, MeadowScenery.draws(item.asset) else { continue }
            let size = item.size.map { Vec3(Float($0[0]), Float($0[1]), Float($0[2])) } ?? Vec3(1, 1, 1)
            let tilt = item.tilt.map { Vec2(Float($0[0]), Float($0[1])) } ?? .zero
            things.append(Thing(id: item.asset, x: Float(at.x), z: Float(at.z), turn: Float(item.turn), size: size, tilt: tilt,
                                seed: item.seed ?? 0, variant: item.drawnVariant(catalog)))
        }
        self.init(things: things)
    }
}

extension MeadowDocument {
    /// `scenery` as a meadow document named `name`: each thing with what its asset takes (a turn, its size
    /// and lean when it grows, its seed when it grows from one, its shape when it has several).
    public init(_ scenery: MeadowScenery, name: String, catalog: MeadowCatalog = .current) {
        let entries = scenery.things.compactMap { thing -> MeadowEntry? in
            guard let asset = catalog.asset(thing.id) else { return nil }
            var item = MeadowFile.MeadowItem(asset: asset.id, placement: .at(MeadowPoint(Double(thing.x), Double(thing.z))), turn: Double(thing.turn))
            if asset.size != nil, thing.size != Vec3(1, 1, 1) { item.size = [thing.size.x, thing.size.y, thing.size.z].map(Double.init) }
            if asset.tilt != nil, thing.tilt != .zero { item.tilt = [thing.tilt.x, thing.tilt.y].map(Double.init) }
            if asset.seeded { item.seed = thing.seed }
            if asset.variants.count > 1 { item.variant = thing.variant }
            return .item(item)
        }
        self.init(name: name, entries: entries)
    }
}

extension MeadowDocument {
    /// The Default as its file holds it, numbers rounded as a file rounds them: what editing the Default
    /// starts from, so what is edited is what is saved and read back. Read-only: it is never written.
    public static let standard: MeadowDocument = {
        let made = MeadowDocument(.standard, name: "Default")
        guard let data = try? made.fileData(writtenBy: "0.1.0"), let read = try? MeadowDocument.read(data) else { return made }
        return read.document
    }()
}
