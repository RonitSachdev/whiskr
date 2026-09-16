import Foundation
import Testing
@testable import MeadowFile

// Importing a meadow someone shared: what the import sheet is told of each kind of file, read with the same
// checks as any file (the fixtures `import-*` are locked like the rest).

@Suite("Meadow files: importing")
struct MeadowImportTests {
    @Test("a meadow of today's catalog: its things, its paths and lawn, who wrote it, and nothing to warn of")
    func plain() throws {
        let reading = try MeadowDocument.read(try Fixtures.data("v1-catalog1-ground.whiskrmeadow"))
        let summary = reading.summary()
        #expect(summary.things == reading.document.entries.count && summary.things > 0)
        #expect(summary.paints == ["ground.path", "ground.lawn", "ground.soil"], "in the catalog's order, not the file's")
        #expect(summary.writtenBy == reading.document.readFrom?.writtenBy && summary.writtenBy != nil)
        #expect(!summary.needsNewerCatalog && !summary.newerFormat && !summary.keepsNewerContent && summary.newerThings == 0 && summary.leftOutside == 0)
    }

    @Test("a newer minor format opens: what it adds is kept untouched and written back")
    func newerMinor() throws {
        let data = try Fixtures.data("import-newer-minor.whiskrmeadow")
        let reading = try MeadowDocument.read(data)
        let summary = reading.summary()
        #expect(summary.newerFormat && !summary.needsNewerCatalog && summary.newerThings == 0 && summary.keepsNewerContent)
        #expect(summary.things == 13 && summary.writtenBy == "1.6.0" && summary.paints.isEmpty)
        #expect(reading.document.name == "Morning Meadow" && reading.document.description == "A quiet corner with stones.")
        // Written back by this Whiskr: the newer section and the stone's newer field as they were, the file still
        // saying it is of that minor format.
        let back = try MeadowDocument.read(try reading.document.fileData(writtenBy: "0.1.0"))
        #expect(back.document.unknownSections == reading.document.unknownSections && back.document.unknownSections["season"] != nil)
        #expect(back.document.items.first { $0.asset == "stone.mossy" }?.unknownFields["moss"] == .string("thick"))
        #expect(back.document.readFrom?.formatMinor == 2)
    }

    @Test("a newer catalog opens: its six new things kept whole and counted, its author and description shown as plain text")
    func newerCatalog() throws {
        let reading = try MeadowDocument.read(try Fixtures.data("import-newer-catalog.whiskrmeadow"))
        let summary = reading.summary()
        #expect(summary.needsNewerCatalog && !summary.newerFormat && summary.newerThings == 6 && summary.keepsNewerContent)
        #expect(summary.things == 21 && summary.paints == ["ground.path", "ground.lawn"] && summary.writtenBy == "1.8.2")
        #expect(reading.document.author == "Hana" && reading.document.description == "Apples, a shed and a reading nook.")
        #expect(reading.document.parcels.map(\.asset) == ["water.pond", "garden.arch", "garden.arch", "work.hammock", "light.lantern", "light.lantern"])
        // It still needs that catalog once written back by this Whiskr: what it holds of it is there.
        let back = try MeadowDocument.read(try reading.document.fileData(writtenBy: "0.1.0"))
        #expect(back.document.readFrom?.needsCatalog == 3 && back.document.parcels == reading.document.parcels)
    }

    @Test("a newer major format is refused, saying which Whiskr wrote it")
    func newerMajor() throws {
        #expect(throws: MeadowFileError.needsNewerWhiskr(writtenBy: "3.2.0")) { try MeadowDocument.read(try Fixtures.data("import-newer-major.whiskrmeadow")) }
    }

    @Test("a file cut off part way is damaged, and said to be (not JSON: it ends in the middle)")
    func damaged() throws {
        #expect(throws: MeadowFileError.notJSON(.truncated)) { try MeadowDocument.read(try Fixtures.data("import-damaged.whiskrmeadow")) }
    }

    @Test("more things than a meadow holds is refused with how many, never cut short")
    func tooMany() throws {
        #expect(throws: MeadowFileError.tooManyThings(count: 5_001)) { try MeadowDocument.read(try Fixtures.data("import-too-many.whiskrmeadow")) }
    }

    @Test("a file over 4 MiB is refused before it is parsed")
    func tooLarge() {
        let data = Data(repeating: UInt8(ascii: " "), count: MeadowFormat.maxBytes + 1)
        #expect(throws: MeadowFileError.tooLarge(bytes: MeadowFormat.maxBytes + 1)) { try MeadowDocument.read(data) }
    }

    @Test("the paints shown are those with cells painted, not merely listed; one this Whiskr does not know is not among them")
    func paintsShown() {
        var grid = GroundGrid()
        let lawn = grid.index(of: "ground.lawn") ?? 0
        _ = grid.index(of: "ground.path")
        _ = grid.index(of: "ground.moss")
        grid[10, 10] = lawn
        let document = MeadowDocument(ground: grid)
        #expect(document.paintsShown() == ["ground.lawn"])
        #expect(MeadowDocument().paintsShown().isEmpty)
    }
}
