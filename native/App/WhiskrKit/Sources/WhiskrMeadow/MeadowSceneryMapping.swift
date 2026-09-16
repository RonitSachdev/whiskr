import Foundation
import MeadowFile
import MeadowScene

// A meadow document (`MeadowFile`) as the scene's scenery, and back. The document keeps everything a
// file held; the scenery is only what the scene draws (its things and its painted ground). Things the scene cannot draw (from a newer Whiskr,
// or catalog ids whose builders come in a later stage) stay in the document and are left out of the
// picture, as the scene leaves out any id it does not draw.

extension MeadowScenery {
    /// The things of `document` the scene could draw, in its order, drawn with the shape and the colour this
    /// Whiskr has.
    public init(_ document: MeadowDocument, catalog: MeadowCatalog = .current) {
        self.init(things: document.items.compactMap { Thing($0, catalog) }, ground: Ground(document.ground, catalog: catalog))
    }
}

extension MeadowScenery.Thing {
    /// A meadow file's item as the scene draws it, when the scene draws its kind: at its spot or along its run (a
    /// fence's points and its gate), turned, sized and leant, in the shape and the swatch of its palette it names
    /// (one this Whiskr does not have drawn as the first).
    public init?(_ item: MeadowFile.MeadowItem, _ catalog: MeadowCatalog = .current) {
        guard MeadowScenery.draws(item.asset) else { return nil }
        switch item.placement {
        case .at(let at):
            let size = item.size.map { Vec3(Float($0[0]), Float($0[1]), Float($0[2])) } ?? Vec3(1, 1, 1)
            let tilt = item.tilt.map { Vec2(Float($0[0]), Float($0[1])) } ?? .zero
            self.init(id: item.asset, x: Float(at.x), z: Float(at.z), turn: Float(item.turn), size: size, tilt: tilt, seed: item.seed ?? 0,
                      variant: item.drawnVariant(catalog), swatch: Self.swatch(of: item, catalog))
        case .run(let points):
            guard points.count >= 2 else { return nil }
            var gate = 0
            if case .integer(let n) = item.value(of: "gate", catalog), n < points.count { gate = n }
            self.init(id: item.asset, points: points.map { Vec2(Float($0.x), Float($0.z)) }, gate: gate)
        }
    }

    /// Which swatch of its palette an item names in `params.colour` (0, its own, when it names none this Whiskr has).
    static func swatch(of item: MeadowFile.MeadowItem, _ catalog: MeadowCatalog) -> Int {
        guard case .choice(let name) = item.value(of: "colour", catalog) else { return 0 }
        return MeadowScenery.palette(of: item.asset).firstIndex { $0.name == name } ?? 0
    }
}

extension MeadowScenery.Ground {
    /// A meadow file's painted ground as the scene draws it: each cell its paint, a paint this Whiskr does not
    /// know drawn as the wild grass. Nil for no ground.
    public init?(_ grid: GroundGrid?, catalog: MeadowCatalog = .current) {
        guard let grid else { return nil }
        let drawn = Self.drawn(grid, catalog)
        self.init(cells: grid.cells.map { drawn[Int($0)] })
    }

    /// For each value a cell of `grid` may hold, the paint the scene draws it with (`Paint.rawValue`).
    static func drawn(_ grid: GroundGrid, _ catalog: MeadowCatalog) -> [UInt8] {
        (0...grid.paints.count).map { value in
            grid.drawnPaint(UInt8(value), catalog).flatMap(Paint.init(id:))?.rawValue ?? 0
        }
    }
}

extension MeadowDocument {
    /// `scenery` as a meadow document named `name`: each thing with what its asset takes (a turn, its size
    /// and lean when it grows, its seed when it grows from one, its shape when it has several, its colour when it
    /// wears another than its own, a run's points and its gate).
    public init(_ scenery: MeadowScenery, name: String, catalog: MeadowCatalog = .current) {
        let entries = scenery.things.compactMap { thing -> MeadowEntry? in
            guard let asset = catalog.asset(thing.id) else { return nil }
            let placement: MeadowFile.MeadowItem.Placement = thing.isRun ? .run(thing.points.map { MeadowPoint(Double($0.x), Double($0.y)) })
                : .at(MeadowPoint(Double(thing.x), Double(thing.z)))
            var item = MeadowFile.MeadowItem(asset: asset.id, placement: placement, turn: thing.isRun ? 0 : Double(thing.turn))
            if asset.size != nil, thing.size != Vec3(1, 1, 1) { item.size = [thing.size.x, thing.size.y, thing.size.z].map(Double.init) }
            if asset.tilt != nil, thing.tilt != .zero { item.tilt = [thing.tilt.x, thing.tilt.y].map(Double.init) }
            if asset.seeded { item.seed = thing.seed }
            if asset.variants.count > 1 { item.variant = thing.variant }
            if thing.swatch > 0, let swatch = MeadowScenery.palette(of: thing.id).dropFirst(thing.swatch).first { item.params["colour"] = .string(swatch.name) }
            if thing.gate > 0 { item.params["gate"] = .number(Double(thing.gate)) }
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
