import Foundation
import Testing
@testable import MeadowFile

// Meadows travel between Whiskr versions both ways: a newer Whiskr's meadow opens in an older one and
// comes back whole; an older one's opens in a newer one through aliases and migrations. `CatalogTwo`
// stands in for the next catalog.

@Suite("Meadow files: versions")
struct MeadowVersioningTests {
    let two = CatalogTwo.catalog

    /// A catalog-2 meadow using everything catalog 2 adds.
    var newer: MeadowDocument {
        var ground = GroundGrid()
        let gravel = ground.index(of: "ground.gravel")!, path = ground.index(of: "ground.path")!
        ground[10, 10] = gravel
        ground[11, 10] = path
        return MeadowDocument(name: "Pond Garden", entries: [
            .item(MeadowItem(asset: "water.pond", placement: .at(MeadowPoint(-20, 15)))),
            .item(MeadowItem(asset: "work.bench", placement: .at(MeadowPoint(5, 5)), turn: 1,
                             params: ["colour": .string("lavender"), "length": .string("long")])),
            .item(MeadowItem(asset: "flower.daisy", placement: .at(MeadowPoint(1, 2)), variant: 2)),
            .item(MeadowItem(asset: "tree.apple", placement: .at(MeadowPoint(40, -10)), seed: 9)),
        ], ground: ground)
    }

    @Test("a newer catalog's meadow opens in this one, survives an edit and a save, and is whole again in the newer one")
    func newerCatalogRoundTrip() throws {
        let file = try newer.fileData(writtenBy: "2.0.0", catalog: two)

        // This Whiskr: the pond is a parcel; the bench, the daisy and the ground keep what is newer.
        let reading = try MeadowDocument.read(file)
        #expect(reading.newerThings == 1 && reading.keepsNewerContent)
        var here = reading.document
        #expect(here.readFrom?.needsCatalog == 2 && here.readFrom?.catalog == 2)
        let bench = try #require(here.items.first { $0.asset == "work.bench" })
        #expect(bench.value(of: "colour", .current) == .choice("wood") && bench.params["length"] == .string("long"))
        #expect(here.items.first { $0.asset == "flower.daisy" }?.drawnVariant(.current) == 0)
        #expect(here.ground?.drawnPaint(1, .current) == nil && here.ground?.drawnPaint(2, .current) == "ground.path")

        // Edit: move the pond and the tree, add a stone, then save in this Whiskr.
        for (i, entry) in here.entries.enumerated() {
            switch entry {
            case .parcel(var parcel):
                parcel.move(by: 1, 1)
                here.entries[i] = .parcel(parcel)
            case .item(var item) where item.asset == "tree.apple":
                item.move(by: -2, 0)
                here.entries[i] = .item(item)
            default: break
            }
        }
        here.entries.append(.item(MeadowItem(asset: "stone.stone", placement: .at(MeadowPoint(3, 3)))))
        let saved = try here.fileData(writtenBy: "0.1.0")
        let root = try MeadowJSON.parse(saved, limits: MeadowFormat.limits).object!
        #expect(root["needsCatalog"] == .number("2") && root["catalog"] == .number("1"))

        // The newer Whiskr: everything it made is there, with the edits.
        var back = try MeadowDocument.read(saved, catalog: two).document
        #expect(back.parcels.isEmpty)
        back.readFrom = nil
        var expected = newer
        expected.entries[0] = .item(MeadowItem(asset: "water.pond", placement: .at(MeadowPoint(-19, 16))))
        expected.entries[3] = .item(MeadowItem(asset: "tree.apple", placement: .at(MeadowPoint(38, -10)), seed: 9))
        expected.entries.append(.item(MeadowItem(asset: "stone.stone", placement: .at(MeadowPoint(3, 3)))))
        #expect(back == expected)
    }

    @Test("needsCatalog is the newest since of what is used: assets, parameters, choices, shapes and paints")
    func needsCatalog() {
        func needs(_ items: [MeadowItem], paints: [String] = []) -> Int {
            var ground = GroundGrid()
            for paint in paints { _ = ground.index(of: paint) }
            return MeadowDocument(entries: items.map { .item($0) }, ground: paints.isEmpty ? nil : ground).needsCatalog(two)
        }
        let at = MeadowItem.Placement.at(MeadowPoint(0, 0))
        #expect(needs([]) == 1)
        #expect(needs([MeadowItem(asset: "work.bench", placement: at, params: ["colour": .string("sage")])]) == 1)
        #expect(needs([MeadowItem(asset: "water.pond", placement: at)]) == 2)
        #expect(needs([MeadowItem(asset: "work.bench", placement: at, params: ["length": .string("short")])]) == 2)
        #expect(needs([MeadowItem(asset: "work.bench", placement: at, params: ["colour": .string("lavender")])]) == 2)
        #expect(needs([MeadowItem(asset: "flower.daisy", placement: at, variant: 1)]) == 1)
        #expect(needs([MeadowItem(asset: "flower.daisy", placement: at, variant: 2)]) == 2)
        #expect(needs([], paints: ["ground.path"]) == 1)
        #expect(needs([], paints: ["ground.gravel"]) == 2)
    }

    @Test("needsCatalog keeps what a newer file needed while its content is kept, and drops when that content goes")
    func needsCatalogKept() throws {
        var document = try MeadowDocument.read(try newer.fileData(writtenBy: "2.0.0", catalog: two)).document
        #expect(document.needsCatalog(.current) == 2)
        // Remove everything newer: the pond, the bench's newer details, the third daisy, the gravel.
        document.entries = document.entries.compactMap { entry in
            guard case .item(var item) = entry else { return nil }
            item.params = item.params.filter { $0.key == "colour" && $0.value == .string("wood") }
            if item.variant > 1 { item.variant = 0 }
            return .item(item)
        }
        document.ground = nil
        #expect(!document.hasNewerContent(.current))
        #expect(document.needsCatalog(.current) == 1)
        let root = try MeadowJSON.parse(try document.fileData(writtenBy: "0.1.0"), limits: MeadowFormat.limits).object!
        #expect(root["needsCatalog"] == .number("1") && root["formatMinor"] == .number("0"))
    }

    @Test("formatMinor: this Whiskr's own, or the file's while its newer content is kept")
    func formatMinor() throws {
        let file = Data(#"{"whiskrMeadow": 1, "formatMinor": 5, "items": [{ "id": "cat.box", "at": [0, 0] }]}"#.utf8)
        var document = try MeadowDocument.read(file).document
        func minor() throws -> MeadowJSON? {
            try MeadowJSON.parse(try document.fileData(writtenBy: "0.1.0"), limits: MeadowFormat.limits).object!["formatMinor"]
        }
        #expect(try minor() == .number("0"))
        document.unknownSections["sky"] = .string("pink")
        #expect(try minor() == .number("5"))
    }

    @Test("an old id reads as its new one and is written as the new one, as a thing and as a paint")
    func aliases() throws {
        let catalog = MeadowCatalog(number: 2, assets: CatalogTwo.catalog.assets,
                                    aliases: ["tree.appleTree": "tree.apple", "ground.dirt": "ground.path"])
        let file = Data(#"""
            {"whiskrMeadow": 1, "catalog": 1,
             "items": [{ "id": "tree.appleTree", "at": [1, 1], "seed": 3 }],
             "ground": { "cells": 512, "reach": 150, "paints": ["ground.dirt"], "runs": [1, 1, 0, 262143] }}
            """#.utf8)
        var document = try MeadowDocument.read(file, catalog: catalog).document
        #expect(document.items.first?.asset == "tree.apple")
        #expect(document.ground?.paints == ["ground.path"])
        #expect(!document.hasNewerContent(catalog))
        let text = String(decoding: try document.fileData(writtenBy: "0.1.0", catalog: catalog), as: UTF8.self)
        #expect(text.contains(#""id": "tree.apple""#) && !text.contains("appleTree"))
        #expect(text.contains(#""paints": ["ground.path"]"#) && !text.contains("dirt"))
        // An old id and its new one, listed as two paints, are the same paint.
        let twice = Data(#"{"whiskrMeadow": 1, "ground": { "cells": 512, "reach": 150, "paints": ["ground.path", "ground.dirt"], "runs": [0, 262144] }}"#.utf8)
        #expect(readError(twice, catalog: catalog) == .invalid(at: "ground.paints[1]", .duplicatePaint))
        document.readFrom = nil
        #expect(try document.throughFile(catalog) == document)
    }

    @Test("format steps run in order, each to the next major; a broken chain refuses the file")
    func formatChain() throws {
        // A pretend format 3 whose steps rename things, read with a reader that knows format 1's grammar
        // only through its steps: v1 → v2 renames "items" to "things", v2 → v3 moves it back.
        let steps: [Int: MeadowMigration.Step] = [
            1: { file in
                var root = file.object!
                root["things"] = root.removeValue(forKey: "items")
                root["whiskrMeadow"] = .number("2")
                return .object(root)
            },
            2: { file in
                var root = file.object!
                root["items"] = root.removeValue(forKey: "things")
                root["whiskrMeadow"] = .number("3")
                return .object(root)
            },
        ]
        let file = MeadowJSON.object(["whiskrMeadow": .number("1"), "items": .array([])])
        let migrated = try MeadowMigration(formatSteps: steps).migrate(file, major: 1, catalog: 1, toMajor: 3, toCatalog: 1)
        #expect(migrated == .object(["whiskrMeadow": .number("3"), "items": .array([])]))
        #expect(file == .object(["whiskrMeadow": .number("1"), "items": .array([])]), "the input is untouched")
        #expect(throws: MeadowMigration.BrokenChain(from: 2)) {
            try MeadowMigration(formatSteps: [1: steps[1]!]).migrate(file, major: 1, catalog: 1, toMajor: 3, toCatalog: 1)
        }
        let wrong: MeadowMigration.Step = { _ in .object(["whiskrMeadow": .number("7")]) }
        #expect(throws: MeadowMigration.BrokenChain(from: 1)) {
            try MeadowMigration(formatSteps: [1: wrong]).migrate(file, major: 1, catalog: 1, toMajor: 2, toCatalog: 1)
        }
        // Reading through a chain this Whiskr would break on refuses the file without crashing.
        #expect(throws: MeadowFileError.notAMeadow) {
            try MeadowDocument.read(Data(#"{"whiskrMeadow": 1, "catalog": 1}"#.utf8), catalog: two,
                                    migration: MeadowMigration(catalogSteps: [2: { _ in throw MeadowMigration.BrokenChain(from: 0) }]))
        }
    }

    @Test("a catalog step changes only files written before its catalog")
    func catalogSteps() throws {
        // Catalog 2 replaced the look of `stone.mossy`; files from catalog 1 keep their look as `stone.oldMossy`.
        let catalog = MeadowCatalog(number: 2, assets: MeadowCatalog.one.assets + [MeadowAsset("stone.oldMossy", since: 2, .stonesAndWood, .natural)])
        let step: MeadowMigration.Step = { file in
            var root = file.object!
            root["items"] = .array((root["items"]?.array ?? []).map { item in
                guard var fields = item.object, fields["id"] == .string("stone.mossy") else { return item }
                fields["id"] = .string("stone.oldMossy")
                return .object(fields)
            })
            return .object(root)
        }
        let migration = MeadowMigration(catalogSteps: [2: step])
        func ids(_ fileCatalog: Int) throws -> [String] {
            let file = Data(#"{"whiskrMeadow": 1, "catalog": \#(fileCatalog), "items": [{ "id": "stone.mossy", "at": [0, 0] }]}"#.utf8)
            return try MeadowDocument.read(file, catalog: catalog, migration: migration).document.items.map(\.asset)
        }
        #expect(try ids(1) == ["stone.oldMossy"])
        #expect(try ids(2) == ["stone.mossy"])
        #expect(try ids(3) == ["stone.mossy"])
    }

    @Test("the same meadow is always the same bytes, and a meadow read once reads the same forever")
    func determinism() throws {
        var random = SplitMix(2026)
        let singles = MeadowCatalog.one.assets.filter { $0.shape == .single && $0.nature != .paint && $0.nature != .eraser }
        for round in 0..<40 {
            var document = MeadowDocument(name: "Round \(round)")
            for _ in 0..<Int.random(in: 0...60, using: &random) {
                let asset = singles.randomElement(using: &random)!
                var item = MeadowItem(asset: asset.id, placement: .at(MeadowPoint(Double.random(in: -100...100, using: &random),
                                                                                  Double.random(in: -100...100, using: &random))),
                                      turn: Double.random(in: -20...20, using: &random))
                if let size = asset.size { item.size = (0..<3).map { _ in Double.random(in: (size.lowerBound - 0.3)...(size.upperBound + 0.3), using: &random) } }
                if let tilt = asset.tilt { item.tilt = (0..<2).map { _ in Double.random(in: -tilt * 2...tilt * 2, using: &random) } }
                if asset.seeded { item.seed = UInt32.random(in: 0...UInt32.max, using: &random) }
                item.variant = Int.random(in: 0..<asset.variants.count, using: &random)
                if let parameter = asset.parameters.first, case .choice(let choices) = parameter.kind {
                    item.params[parameter.name] = .string(choices.randomElement(using: &random)!.name)
                }
                document.entries.append(.item(item))
            }
            if Bool.random(using: &random) {
                var ground = GroundGrid()
                let paint = ground.index(of: ["ground.path", "ground.lawn", "ground.soil"].randomElement(using: &random)!)!
                for _ in 0..<200 { ground[Int.random(in: 0..<512, using: &random), Int.random(in: 0..<512, using: &random)] = paint }
                document.ground = ground
            }
            let first = try document.fileData(writtenBy: "0.1.0")
            #expect(try document.fileData(writtenBy: "0.1.0") == first)
            let once = try document.throughFile()
            #expect(try once.fileData(writtenBy: "0.1.0") == first, "round \(round)")
            #expect(try once.throughFile() == once, "round \(round)")
        }
    }
}
