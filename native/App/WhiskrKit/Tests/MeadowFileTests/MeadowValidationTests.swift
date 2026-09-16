import Foundation
import Testing
@testable import MeadowFile

// A meadow file is data from anyone: every field this Whiskr knows is checked, numbers are kept in the
// meadow's ranges, and a count over a limit refuses the file rather than cutting it.

@Suite("Meadow files: validation")
struct MeadowValidationTests {
    func read(_ items: String, extra: String = "") throws -> MeadowReading {
        try MeadowDocument.read(meadow(items, extra: extra))
    }

    func first(_ item: String) throws -> MeadowItem {
        try #require(try read(item).document.items.first)
    }

    func invalid(_ items: String, extra: String = "") -> MeadowFileError? {
        readError(meadow(items, extra: extra))
    }

    @Test("over 4 MiB is refused before it is parsed")
    func tooLarge() {
        let data = Data(repeating: 0x20, count: MeadowFormat.maxBytes + 1)
        #expect(readError(data) == .tooLarge(bytes: MeadowFormat.maxBytes + 1))
        #expect(readError(Data(repeating: 0x20, count: MeadowFormat.maxBytes)) == .notJSON(.truncated))
    }

    @Test("not a meadow: not JSON, not an object, no format number")
    func notAMeadow() {
        #expect(readError(Data("{".utf8)) == .notJSON(.truncated))
        #expect(readError(Data("[1]".utf8)) == .notAMeadow)
        #expect(readError(Data(#"{"name": "x"}"#.utf8)) == .notAMeadow)
        #expect(readError(Data(#"{"whiskrMeadow": "1"}"#.utf8)) == .notAMeadow)
        #expect(readError(Data(#"{"whiskrMeadow": 0}"#.utf8)) == .notAMeadow)
        #expect(readError(Data(#"{"whiskrMeadow": 1.5}"#.utf8)) == .notAMeadow)
        #expect(readError(Data(#"{"whiskrMeadow": 1}"#.utf8)) == nil)
    }

    @Test("a newer major is refused before anything else is looked at; so is a world this Whiskr does not have")
    func newer() {
        #expect(readError(Data(#"{"whiskrMeadow": 2, "items": "anything", "writtenBy": "2.0.0"}"#.utf8)) == .needsNewerWhiskr(writtenBy: "2.0.0"))
        #expect(readError(Data(#"{"whiskrMeadow": 9, "writtenBy": "<b>9</b>"}"#.utf8)) == .needsNewerWhiskr(writtenBy: nil))
        #expect(readError(Data(#"{"whiskrMeadow": 1, "base": "beach", "writtenBy": "1.9.0"}"#.utf8)) == .needsNewerWhiskr(writtenBy: "1.9.0"))
    }

    @Test("a missing or empty file's fields take their defaults")
    func defaults() throws {
        let reading = try MeadowDocument.read(Data(#"{"whiskrMeadow": 1}"#.utf8))
        var document = reading.document
        #expect(document.readFrom == .init(formatMajor: 1, formatMinor: 0, writtenBy: nil, catalog: 1, needsCatalog: 1))
        document.readFrom = nil
        #expect(document == .empty)
        #expect(!reading.keepsNewerContent && reading.leftOutside == 0)
    }

    @Test("the version fields must be counts; writtenBy is only kept when it is a version")
    func versionFields() {
        #expect(readError(Data(#"{"whiskrMeadow": 1, "catalog": "1"}"#.utf8)) == .invalid(at: "catalog", .wrongType))
        #expect(readError(Data(#"{"whiskrMeadow": 1, "catalog": 0}"#.utf8)) == .invalid(at: "catalog", .outOfRange))
        #expect(readError(Data(#"{"whiskrMeadow": 1, "needsCatalog": -1}"#.utf8)) == .invalid(at: "needsCatalog", .outOfRange))
        #expect(readError(Data(#"{"whiskrMeadow": 1, "formatMinor": 0.5}"#.utf8)) == .invalid(at: "formatMinor", .outOfRange))
        #expect(readError(Data(#"{"whiskrMeadow": 1, "writtenBy": 3}"#.utf8)) == nil)
        for version in ["1.4.0", "2.0.0-beta.1", "10.1+build.7"] { #expect(MeadowFormat.isWellFormedVersion(version), "\(version)") }
        for version in ["", "v1", "1.0 beta", "1.0/..", String(repeating: "1", count: 33), "1.0\u{202E}"] {
            #expect(!MeadowFormat.isWellFormedVersion(version), "\(version)")
        }
    }

    @Test("name, author and description are sanitised, and refused over their limits")
    func texts() throws {
        let reading = try MeadowDocument.read(Data(#"{"whiskrMeadow": 1, "name": "  Orchard\u202e Study ", "author": "Hana\u0000", "description": "Apples,\na shed."}"#.utf8))
        #expect(reading.document.name == "Orchard Study" && reading.document.author == "Hana" && reading.document.description == "Apples, a shed.")
        let long = String(repeating: "あ", count: 61)
        #expect(readError(Data(#"{"whiskrMeadow": 1, "name": "\#(long)"}"#.utf8)) == .textTooLong(.name))
        #expect(readError(Data(#"{"whiskrMeadow": 1, "name": "\#(long.dropLast())   "}"#.utf8)) == nil)
        #expect(readError(Data(#"{"whiskrMeadow": 1, "author": 7}"#.utf8)) == .invalid(at: "author", .wrongType))
    }

    @Test("a thing's spot, turn, size, lean, seed and shape are read and kept in their ranges")
    func transforms() throws {
        let tree = try first(#"{ "id": "tree.oak", "at": [12.345678, -30.25], "turn": -1.5708, "size": [5, 0.1, 1.04], "tilt": [0.5, -0.01], "seed": 4294967295 }"#)
        #expect(tree.placement == .at(MeadowPoint(12.3457, -30.25)))
        #expect(tree.turn == MeadowJSON.quantized(2 * .pi - 1.5708))
        #expect(tree.size == [1.2, 0.8, 1.04] && tree.tilt == [0.05, -0.01] && tree.seed == UInt32.max)
        #expect(try first(#"{ "id": "flower.daisy", "at": [0, 0], "turn": 6.28316 }"#).turn == 0)
        #expect(try first(#"{ "id": "flower.daisy", "at": [0, 0], "turn": 1e300 }"#).turn < 2 * .pi)
        #expect(try first(#"{ "id": "flower.daisy", "at": [0, 0], "size": [1, 1, 1], "tilt": [0, -0] }"#).size == nil)
        #expect(try first(#"{ "id": "flower.daisy", "at": [0, 0], "tilt": [0, -0] }"#).tilt == nil)
        #expect(try first(#"{ "id": "flower.daisy", "at": [0, 0], "variant": 1 }"#).variant == 1)
    }

    @Test("fields a thing does not take are kept as they were, not read")
    func notTaken() throws {
        let box = try first(#"{ "id": "cat.box", "at": [1, 1], "size": [2, 2, 2], "seed": 5, "points": [[0, 0], [1, 1]] }"#)
        #expect(box.size == nil && box.seed == nil)
        #expect(box.unknownFields == ["size": .array([.number("2"), .number("2"), .number("2")]), "seed": .number("5"),
                                      "points": .array([.array([.number("0"), .number("0")]), .array([.number("1"), .number("1")])])])
        let fence = try first(#"{ "id": "garden.fence", "points": [[0, 0], [1, 1]], "at": [5, 5], "turn": 1 }"#)
        #expect(fence.placement == .run([MeadowPoint(0, 0), MeadowPoint(1, 1)]) && Set(fence.unknownFields.keys) == ["at", "turn"])
    }

    @Test("things outside the meadow are left out and counted, never refused")
    func outside() throws {
        let reading = try read("""
            { "id": "flower.daisy", "at": [150, 0] }, { "id": "flower.daisy", "at": [106.1, 106.1] },
            { "id": "flower.daisy", "at": [1e300, 0] }, { "id": "garden.fence", "points": [[0, 0], [151, 0]] },
            { "id": "flower.daisy", "at": [150.00004, 0] }
            """)
        #expect(reading.leftOutside == 3)
        #expect(reading.document.items.map(\.at) == [MeadowPoint(150, 0), MeadowPoint(150, 0)])
    }

    @Test("a field this Whiskr knows with the wrong type is refused, saying where")
    func wrongTypes() {
        #expect(invalid(#"7"#) == .invalid(at: "items[0]", .wrongType))
        #expect(readError(Data(#"{"whiskrMeadow": 1, "items": {}}"#.utf8)) == .invalid(at: "items", .wrongType))
        #expect(invalid(#"{ "at": [0, 0] }"#) == .invalid(at: "items[0].id", .missing))
        #expect(invalid(#"{ "id": 3, "at": [0, 0] }"#) == .invalid(at: "items[0].id", .wrongType))
        #expect(invalid(#"{ "id": "Tree", "at": [0, 0] }"#) == .invalid(at: "items[0].id", .malformedId))
        #expect(invalid(#"{ "id": "ground.path", "at": [0, 0] }"#) == .invalid(at: "items[0].id", .notAThing))
        #expect(invalid(#"{ "id": "ground.wild", "at": [0, 0] }"#) == .invalid(at: "items[0].id", .notAThing))
        #expect(invalid(#"{ "id": "flower.daisy" }"#) == .invalid(at: "items[0].at", .missing))
        #expect(invalid(#"{ "id": "flower.daisy", "at": [0] }"#) == .invalid(at: "items[0].at", .wrongType))
        #expect(invalid(#"{ "id": "flower.daisy", "at": [0, "0"] }"#) == .invalid(at: "items[0].at", .wrongType))
        #expect(invalid(#"{ "id": "flower.daisy", "at": [0, 1e999] }"#) == .invalid(at: "items[0].at", .notFinite))
        #expect(invalid(#"{ "id": "flower.daisy", "at": [0, 0], "turn": "east" }"#) == .invalid(at: "items[0].turn", .wrongType))
        #expect(invalid(#"{ "id": "flower.daisy", "at": [0, 0], "size": [1, 1] }"#) == .invalid(at: "items[0].size", .wrongType))
        #expect(invalid(#"{ "id": "flower.daisy", "at": [0, 0], "tilt": [0, -1e999] }"#) == .invalid(at: "items[0].tilt", .notFinite))
        #expect(invalid(#"{ "id": "flower.daisy", "at": [0, 0], "variant": -1 }"#) == .invalid(at: "items[0].variant", .outOfRange))
        #expect(invalid(#"{ "id": "flower.daisy", "at": [0, 0], "variant": 256 }"#) == .invalid(at: "items[0].variant", .outOfRange))
        #expect(invalid(#"{ "id": "flower.daisy", "at": [0, 0], "variant": "1" }"#) == .invalid(at: "items[0].variant", .wrongType))
        #expect(invalid(#"{ "id": "tree.oak", "at": [0, 0] }"#) == .invalid(at: "items[0].seed", .missing))
        #expect(invalid(#"{ "id": "tree.oak", "at": [0, 0], "seed": 4294967296 }"#) == .invalid(at: "items[0].seed", .outOfRange))
        #expect(invalid(#"{ "id": "tree.oak", "at": [0, 0], "seed": 1.5 }"#) == .invalid(at: "items[0].seed", .outOfRange))
        #expect(invalid(#"{ "id": "garden.fence", "points": [[0, 0]] }"#) == .invalid(at: "items[0].points", .pointCount))
        let many = Array(repeating: "[0, 0]", count: 65).joined(separator: ", ")
        #expect(invalid(#"{ "id": "garden.fence", "points": [\#(many)] }"#) == .invalid(at: "items[0].points", .pointCount))
        #expect(invalid(#"{ "id": "garden.fence", "points": [[0, 0], [1]] }"#) == .invalid(at: "items[0].points[1]", .wrongType))
        #expect(invalid(#"{ "id": "work.bench", "at": [0, 0], "params": [] }"#) == .invalid(at: "items[0].params", .wrongType))
        #expect(invalid(#"{ "id": "work.bench", "at": [0, 0], "params": { "colour": 2 } }"#) == .invalid(at: "items[0].params.colour", .wrongType))
        #expect(invalid(#"{ "id": "garden.fence", "points": [[0, 0], [1, 1]], "params": { "gate": "yes" } }"#)
            == .invalid(at: "items[0].params.gate", .wrongType))
    }

    @Test("parameters: numbers clamped, unknown choices and unknown parameters kept, the default drawn")
    func parameters() throws {
        let fence = try first(#"{ "id": "garden.fence", "points": [[0, 0], [1, 1]], "params": { "gate": 99.6, "height": "tall" } }"#)
        #expect(fence.params == ["gate": .number("63"), "height": .string("tall")])
        #expect(fence.value(of: "gate", .current) == .integer(63) && fence.value(of: "height", .current) == nil)
        let bench = try first(#"{ "id": "work.bench", "at": [0, 0], "params": { "colour": "lavender" } }"#)
        #expect(bench.params == ["colour": .string("lavender")] && bench.value(of: "colour", .current) == .choice("wood"))
        #expect(bench.hasNewerContent(.current))
        let plain = try first(#"{ "id": "work.bench", "at": [0, 0] }"#)
        #expect(plain.value(of: "colour", .current) == .choice("wood") && !plain.hasNewerContent(.current))
        let daisy = try first(#"{ "id": "flower.daisy", "at": [0, 0], "variant": 7 }"#)
        #expect(daisy.variant == 7 && daisy.drawnVariant(.current) == 0 && daisy.hasNewerContent(.current))
    }

    @Test("a thing from a newer Whiskr is kept whole; it shows at its spot when it has one, and moves only what is a point")
    func parcels() throws {
        let things = try read("""
            { "id": "water.pond", "at": [3, 4], "depth": 2 }, { "id": "garden.hedgeRun", "points": [[0, 60], "bend", [10, 60]] },
            { "id": "sky.kite", "at": "north" }, { "id": "sky.moon", "at": [400, 0] }
            """).document.parcels
        #expect(things.map(\.asset) == ["water.pond", "garden.hedgeRun", "sky.kite", "sky.moon"])
        #expect(things.map(\.at) == [MeadowPoint(3, 4), MeadowPoint(0, 60), nil, nil])
        var hedge = things[1], kite = things[2], pond = things[0]
        hedge.move(by: 1, -1)
        #expect(hedge.fields["points"] == .array([.array([.number("1"), .number("59")]), .string("bend"), .array([.number("11"), .number("59")])]))
        kite.move(by: 1, 1)
        #expect(kite == things[2])
        pond.move(by: .nan, 1)
        pond.move(by: 1e300, 1)
        #expect(pond == things[0])
        pond.move(by: 0.5, 0)
        #expect(pond.fields == ["id": .string("water.pond"), "at": .array([.number("3.5"), .number("4")]), "depth": .number("2")])
    }

    @Test("the ground's grid and runs are checked exactly")
    func ground() {
        func ground(_ fields: String) -> MeadowFileError? {
            readError(Data(#"{"whiskrMeadow": 1, "ground": { \#(fields) }}"#.utf8))
        }
        let all = #""runs": [0, 262144]"#
        #expect(ground(#""cells": 512, "reach": 150, "paints": [], \#(all)"#) == nil)
        #expect(ground(#""cells": 256, "reach": 150, "paints": [], \#(all)"#) == .invalid(at: "ground.cells", .outOfRange))
        #expect(ground(#""reach": 150, "paints": [], \#(all)"#) == .invalid(at: "ground.cells", .missing))
        #expect(ground(#""cells": 512, "reach": 100, "paints": [], \#(all)"#) == .invalid(at: "ground.reach", .outOfRange))
        #expect(ground(#""cells": 512, "reach": 150, "paints": "ground.path", \#(all)"#) == .invalid(at: "ground.paints", .wrongType))
        #expect(ground(#""cells": 512, "reach": 150, "paints": ["tree.oak"], \#(all)"#) == .invalid(at: "ground.paints[0]", .notAPaint))
        #expect(ground(#""cells": 512, "reach": 150, "paints": ["ground.wild"], \#(all)"#) == .invalid(at: "ground.paints[0]", .notAPaint))
        #expect(ground(#""cells": 512, "reach": 150, "paints": ["ground.path", "ground.path"], \#(all)"#)
            == .invalid(at: "ground.paints[1]", .duplicatePaint))
        #expect(ground(#""cells": 512, "reach": 150, "paints": ["Ground"], \#(all)"#) == .invalid(at: "ground.paints[0]", .malformedId))
        let seventeen = (1...17).map { "\"ground.p\($0)\"" }.joined(separator: ", ")
        #expect(ground(#""cells": 512, "reach": 150, "paints": [\#(seventeen)], \#(all)"#) == .invalid(at: "ground.paints", .outOfRange))
        #expect(ground(#""cells": 512, "reach": 150, "paints": [], "runs": [0, 262143]"#) == .invalid(at: "ground.runs", .runs(.total(262_143))))
        #expect(ground(#""cells": 512, "reach": 150, "paints": [], "runs": [1, 262144]"#) == .invalid(at: "ground.runs", .runs(.value(pair: 0))))
        #expect(ground(#""cells": 512, "reach": 150, "paints": [], "runs": [0, 1.5]"#) == .invalid(at: "ground.runs", .outOfRange))
        #expect(ground(#""cells": 512, "reach": 150, "paints": [], "runs": [0, "262144"]"#) == .invalid(at: "ground.runs", .wrongType))
        #expect(ground(#""cells": 512, "reach": 150, "paints": [], "runs": [0, 1e300]"#) == .invalid(at: "ground.runs", .outOfRange))
        #expect(readError(Data(#"{"whiskrMeadow": 1, "ground": []}"#.utf8)) == .invalid(at: "ground", .wrongType))
    }

    // MARK: Counts

    static func items(_ count: Int, _ make: (Int) -> String) -> String {
        (0..<count).map(make).joined(separator: ",")
    }

    static func spot(_ i: Int) -> String {
        "[\(Double(i % 200) * 0.5 - 50), \(Double(i / 200) * 0.5 - 50)]"
    }

    @Test("every kind is allowed up to its cap and refused one past it, never cut")
    func caps() {
        func check(_ id: String, _ cap: MeadowCatalog.Cap, extra: String = "") {
            let make = { (i: Int) in #"{ "id": "\#(id)", "at": \#(Self.spot(i))\#(extra) }"# }
            #expect(invalid(Self.items(cap.limit, make)) == nil, "\(id) at its cap")
            #expect(invalid(Self.items(cap.limit + 1, make)) == .tooManyOfKind(cap, count: cap.limit + 1), "\(id) past its cap")
        }
        check("tree.young", .trees, extra: #", "seed": 1"#)
        check("work.lampPost", .lamps)
        check("cat.box", .madeThings)
        // Tall: 48 trees and 72 other tall things fill it; one more is refused.
        let trees = Self.items(48) { #"{ "id": "tree.oak", "at": \#(Self.spot($0)), "seed": 1 }"# }
        let sheds = { (n: Int) in Self.items(n) { #"{ "id": "place.shed", "at": \#(Self.spot($0 + 48)) }"# } }
        #expect(invalid(trees + "," + sheds(72)) == nil)
        #expect(invalid(trees + "," + sheds(73)) == .tooManyOfKind(.tall, count: 121))
        // Fence posts: 300 runs of 2 posts, then one post more.
        let fences = { (n: Int) in Self.items(n) { #"{ "id": "garden.fence", "points": [\#(Self.spot($0)), \#(Self.spot($0))] }"# } }
        #expect(invalid(fences(300)) == nil)
        #expect(invalid(fences(299) + #", { "id": "garden.fence", "points": [[0, 0], [2.6, 0]] }"#) == .tooManyOfKind(.fencePosts, count: 601))
    }

    @Test("5,000 things in all, those from a newer Whiskr included; 1,000 of those; 4 KB each")
    func totals() {
        let daisies = { (n: Int) in Self.items(n) { #"{ "id": "flower.daisy", "at": \#(Self.spot($0)) }"# } }
        let parcels = { (n: Int) in Self.items(n) { #"{ "id": "water.pond", "at": \#(Self.spot($0)) }"# } }
        #expect(invalid(daisies(5_000)) == nil)
        #expect(invalid(daisies(5_001)) == .tooManyThings(count: 5_001))
        #expect(invalid(daisies(4_000) + "," + parcels(1_000)) == nil)
        #expect(invalid(daisies(4_000) + "," + parcels(1_001)) == .tooManyThings(count: 5_001))
        #expect(invalid(parcels(1_001)) == .tooManyNewerThings(count: 1_001))
        let note = String(repeating: "x", count: 4_096 - #"{ "id": "water.pond", "note": "" }"#.utf8.count)
        #expect(invalid(#"{ "id": "water.pond", "note": "\#(note)" }"#) == nil)
        #expect(invalid(#"{ "id": "water.pond", "note": "x\#(note)" }"#) == .thingTooLarge(at: "items[0]"))
        #expect(invalid(#"{ "id": "flower.daisy", "at": [0, 0], "note": "x\#(note)" }"#) == .thingTooLarge(at: "items[0]"))
    }

    @Test("writing refuses what reading would: over a cap, outside the meadow, words too long, no version")
    func writing() {
        func error(_ document: MeadowDocument, _ version: String = "0.1.0") -> MeadowFileError? {
            do {
                _ = try document.fileData(writtenBy: version)
                return nil
            } catch {
                return error as? MeadowFileError
            }
        }
        let lamp = MeadowItem(asset: "work.lampPost", placement: .at(MeadowPoint(0, 0)))
        #expect(error(MeadowDocument(entries: Array(repeating: .item(lamp), count: 32))) == nil)
        #expect(error(MeadowDocument(entries: Array(repeating: .item(lamp), count: 33))) == .tooManyOfKind(.lamps, count: 33))
        #expect(error(MeadowDocument(entries: [.item(MeadowItem(asset: "cat.box", placement: .at(MeadowPoint(150.1, 0))))]))
            == .invalid(at: "items[0].at", .outOfRange))
        #expect(error(MeadowDocument(entries: [.item(MeadowItem(asset: "cat.box", placement: .at(MeadowPoint(1e300, .nan))))]))
            == .invalid(at: "items[0].at", .notFinite))
        #expect(error(MeadowDocument(entries: [.item(MeadowItem(asset: "cat.box", placement: .at(MeadowPoint(0, 0)), turn: .infinity))]))
            == .invalid(at: "items[0].turn", .notFinite))
        #expect(error(MeadowDocument(entries: [.item(MeadowItem(asset: "flower.daisy", placement: .at(MeadowPoint(0, 0)), size: [1, .nan, 1]))]))
            == .invalid(at: "items[0].size", .notFinite))
        #expect(error(MeadowDocument(entries: [.item(MeadowItem(asset: "flower.daisy", placement: .at(MeadowPoint(0, 0)), tilt: [0]))]))
            == .invalid(at: "items[0].tilt", .wrongType))
        #expect(error(MeadowDocument(entries: [.item(MeadowItem(asset: "flower.daisy", placement: .at(MeadowPoint(0, 0)), variant: Int.max))]))
            == .invalid(at: "items[0].variant", .outOfRange))
        #expect(error(MeadowDocument(entries: [.item(MeadowItem(asset: "garden.fence", placement: .run([MeadowPoint(0, 0), MeadowPoint(0, 200)])))]))
            == .invalid(at: "items[0].points", .outOfRange))
        #expect(error(MeadowDocument(entries: [.item(MeadowItem(asset: "water.pond", placement: .at(MeadowPoint(0, 0))))]))
            == .invalid(at: "items[0].id", .malformedId))
        #expect(error(MeadowDocument(entries: [.item(MeadowItem(asset: "tree.oak", placement: .at(MeadowPoint(0, 0))))]))
            == .invalid(at: "items[0].seed", .missing))
        #expect(error(MeadowDocument(name: String(repeating: "n", count: 61))) == .textTooLong(.name))
        #expect(error(MeadowDocument(name: "  n\u{202E}  ")) == nil)
        #expect(error(.empty, "") == .invalid(at: "writtenBy", .outOfRange))
    }
}
