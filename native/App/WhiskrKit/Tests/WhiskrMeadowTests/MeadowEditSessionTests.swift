import Foundation
import MeadowFile
import MeadowScene
import Testing
import simd
@testable import WhiskrMeadow

// Editing a meadow: ids that last, the scenery drawn from the document, every edit undone and done again
// exactly, and the editor's rules for where a thing may stand.

private func item(_ id: String, _ x: Double, _ z: Double, seed: UInt32? = nil, size: [Double]? = nil, variant: Int = 0) -> MeadowEntry {
    .item(MeadowFile.MeadowItem(asset: id, placement: .at(MeadowPoint(x, z)), size: size, seed: seed, variant: variant))
}

@Suite struct EditingAMeadow {
    var garden: MeadowDocument {
        MeadowDocument(name: "Garden", entries: [
            item("tree.oak", 50, 10, seed: 7),
            item("flower.daisy", 30, 0, size: [1.1, 1.1, 1.1]),
            item("stone.mossy", 34, 5),
            item("work.desk", 36, -4),
            .parcel(MeadowParcel(fields: ["id": .string("garden.pond"), "at": .array([.number(40), .number(40)])])),
            item("flower.poppy", 31, 1),
        ])
    }

    @Test("ids last; what the scene draws, and which thing is which")
    func lookup() {
        let session = MeadowEditSession(garden)
        #expect(session.ids == [1, 2, 3, 4, 5, 6])
        // The desk has no builder yet and the parcel is from a newer Whiskr: kept, not drawn.
        #expect(session.shown == [1, 2, 3, 6] && session.scenery.things.map(\.id) == ["tree.oak", "flower.daisy", "stone.mossy", "flower.poppy"])
        #expect(session.id(ofThing: 3) == 6 && session.thingIndex(of: 6) == 3 && session.thingIndex(of: 4) == nil)
        // Of its kind only: the poppy beside the daisy is not like it.
        #expect(session.ids(like: 2, within: 5) == [2] && session.ids(like: 6, within: 50) == [6])
        let meadow = MeadowEditSession(MeadowDocument(entries: [item("flower.daisy", 0, 0), item("flower.daisy", 3, 0), item("flower.daisy", 40, 0)]))
        #expect(meadow.ids(like: 1, within: 30) == [1, 2])
        #expect(session.idsByDistance(from: SIMD2(31, 1)).first == 6)
    }

    @Test("a move keeps the group's shape; undone it is as before, done again as after, byte for byte")
    func moveUndoRedo() throws {
        var session = MeadowEditSession(garden)
        let before = session.document
        let change = try session.move([2, 6], by: SIMD2(-5, 2)).get()
        #expect(session.item(2)!.at == MeadowPoint(25, 2) && session.item(6)!.at == MeadowPoint(26, 3))
        #expect(change.touched.sorted() == [2, 6] && change.edited.count == 2)
        let after = session.document
        session.apply(change.inverse)
        #expect(session.document == before && session.ids == [1, 2, 3, 4, 5, 6])
        session.apply(change)
        #expect(session.document == after)
        #expect(try after.fileData(writtenBy: "1.0.0") == session.document.fileData(writtenBy: "1.0.0"))
    }

    @Test("a refused move changes nothing and names the thing in the way, its kind, and which moved thing it stopped")
    func refusedMove() {
        var session = MeadowEditSession(garden)
        let before = session.document
        #expect(session.move([3], by: SIMD2(14, 5)) == .failure(MeadowEditRefused(.tooClose(to: "tree.oak"), id: 3)))
        #expect(session.move([1], by: SIMD2(-50, 30)) == .failure(MeadowEditRefused(.keptForWorkspaces, id: 1)))
        #expect(session.move([2], by: SIMD2(200, 0)) == .failure(MeadowEditRefused(.outsideMeadow, id: 2)))
        #expect(session.document == before)
    }

    @Test("what stood too close already may still move a little: only what an edit makes worse is refused")
    func excused() throws {
        var session = MeadowEditSession(MeadowDocument(entries: [item("flower.daisy", 0, 0), item("flower.daisy", 0.3, 0)]))
        #expect(throws: Never.self) { try session.move([2], by: SIMD2(0.05, 0)).get() }
        var other = MeadowEditSession(MeadowDocument(entries: [item("flower.daisy", 0, 0), item("flower.daisy", 3, 0)]))
        #expect(other.move([2], by: SIMD2(-2.8, 0)) == .failure(MeadowEditRefused(.tooClose(to: "flower.daisy"), id: 2)))
    }

    @Test("a drag is judged as it goes, without changing the meadow")
    func dragging() {
        let session = MeadowEditSession(garden)
        let check = session.moveCheck([3])
        #expect(session.refusals(check, by: SIMD2(1, 0)).isEmpty)
        #expect(session.refusals(check, by: SIMD2(14, 5)) == [3: .tooClose(to: "tree.oak")])
        let moved = session.scenery(moving: [3], by: SIMD2(1, 2))
        #expect(moved.things[2].x == 35 && moved.things[2].z == 7 && session.scenery.things[2].x == 34)
    }

    @Test("turning: one thing about its own middle, a group about the group's, its shape kept; turns kept in [0, 2π)")
    func turning() throws {
        var session = MeadowEditSession(garden)
        _ = try session.turn([2], by: -.pi / 12).get()
        #expect(session.item(2)!.at == MeadowPoint(30, 0) && abs(session.item(2)!.turn - (2 * .pi - .pi / 12)) < 1e-4)
        _ = try session.turn([2, 6], by: .pi).get()
        // Each goes to the other side of their middle, (30.5, 0.5).
        #expect(session.item(2)!.at == MeadowPoint(31, 1) && session.item(6)!.at == MeadowPoint(30, 0))
    }

    @Test("living things grow and shrink within their kind's sizes; made and found things keep theirs")
    func sizing() throws {
        var session = MeadowEditSession(garden)
        _ = try session.resize([2], by: 1.2).get()
        #expect(session.item(2)!.size == [1.32, 1.32, 1.32])
        #expect(session.resize([2], by: 1.2) == .failure(MeadowEditRefused(.largest("flower.daisy"), id: 2)))
        #expect(session.resize([1], by: 0.5) == .failure(MeadowEditRefused(.smallest("tree.oak"), id: 1)))
        #expect(session.resize([3], by: 1.1) == .failure(MeadowEditRefused(.keepsItsSize("stone.mossy"), id: 3)))
        #expect(session.grows(1) && session.grows(2) && !session.grows(3) && !session.grows(4))
        _ = try session.resize([2], by: 1 / 1.32).get()
        #expect(session.item(2)!.size == nil, "back to its own size, which a file leaves out")
    }

    @Test("duplicates stand beside, at the nearest spot where each may, the same things; undone they go")
    func duplicating() throws {
        var session = MeadowEditSession(garden)
        let change = try session.duplicate([1], toward: SIMD2(1, 0)).get()
        #expect(change.added.count == 1 && change.added[0].id == 7 && session.ids.last == 7)
        let copy = session.item(7)!
        #expect(copy.asset == "tree.oak" && copy.seed == 7, "the same tree")
        // Not on top of the first: two units over would overlap its roots, so further.
        #expect(hypot(copy.at.x - 50, copy.at.z - 10) > 2)
        let field = SceneryRules.Field(session.scenery, leavingOut: [session.thingIndex(of: 7)!])
        #expect(field.refusal(for: session.scenery.things[session.thingIndex(of: 7)!]) == nil)
        session.apply(change.inverse)
        #expect(session.document == garden && session.ids == [1, 2, 3, 4, 5, 6])
    }

    @Test("an ⌥-drag's copies land exactly where let go, or nowhere, saying why; drawn after the rest while dragged")
    func copyByDrag() throws {
        var session = MeadowEditSession(garden)
        let field = SceneryRules.Field(session.scenery)
        #expect(session.copyRefusals([2], by: SIMD2(0.1, 0), field: field) == [2: .tooClose(to: "flower.daisy")], "on top of itself")
        #expect(session.copyRefusals([2], by: SIMD2(-6, 0), field: field).isEmpty)
        let (scenery, copies) = session.scenery(copying: [2, 6], by: SIMD2(-6, 0))
        #expect(copies == [4, 5] && scenery.things[4].x == 24 && scenery.things.count == 6)
        #expect(session.duplicate([2], movedBy: SIMD2(0.1, 0)) == .failure(MeadowEditRefused(.tooClose(to: "flower.daisy"))))
        let change = try session.duplicate([2], movedBy: SIMD2(-6, 0)).get()
        #expect(change.added.count == 1 && session.item(change.added[0].id)!.at == MeadowPoint(24, 0))
    }

    @Test("Shuffle draws a living thing again within its kind's usual sizes, a tree from a new seed; found and made things stay")
    func shuffling() throws {
        var session = MeadowEditSession(garden)
        var random = SystemRandomNumberGenerator()
        let oak = session.item(1)!, stone = session.item(3)!
        _ = try session.shuffle([1, 3], using: &random).get()
        #expect(session.item(1)!.seed != oak.seed && session.item(3)! == stone)
        let size = session.item(1)!.size ?? [1, 1, 1]
        #expect(size.allSatisfy { (0.8 * 0.88...1.2 * 1.12).contains($0) })
        #expect(abs(session.item(1)!.tilt?.first ?? 0) <= 0.05)
    }

    @Test("deleting takes things away from among the rest; undone, each comes back in its place")
    func deleting() {
        var session = MeadowEditSession(garden)
        let change = session.delete([2, 4])
        #expect(session.ids == [1, 3, 5, 6] && session.document.entries.count == 4)
        session.apply(change.inverse)
        #expect(session.document == garden && session.ids == [1, 2, 3, 4, 5, 6])
    }

    @Test("copied things are a meadow file of them round their middle; pasted, they land round the spot asked")
    func copyPaste() throws {
        var session = MeadowEditSession(garden)
        let data = try #require(session.copied([2, 6], writtenBy: "1.0.0"))
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"whiskrMeadow\"") && !text.contains("Garden"), "a file of just the things, no name")
        let items = try #require(MeadowEditSession.pasted(data))
        #expect(items.map(\.at) == [MeadowPoint(-0.5, -0.5), MeadowPoint(0.5, 0.5)])
        let change = try session.add(items, around: SIMD2(-40, -40)).get()
        #expect(change.added.map(\.id) == [7, 8] && session.item(7)!.at == MeadowPoint(-40.5, -40.5))
        #expect(MeadowEditSession.pasted(Data("not a meadow".utf8)) == nil)
    }

    @Test("the meadow's caps hold: copies past one are refused, saying which")
    func caps() {
        let trees: [MeadowEntry] = (0..<48).map { (i: Int) -> MeadowEntry in
            let x = Double(i % 8) * 9 + 24, z = Double(i / 8) * 9 - 30
            return item("tree.young", x, z, seed: UInt32(i))
        }
        var session = MeadowEditSession(MeadowDocument(entries: trees))
        #expect(session.duplicate([1], toward: SIMD2(1, 0)) == .failure(MeadowEditRefused(.full(.trees, limit: 48))))
    }

    @Test("the Default as its file holds it: its things, rounded as a file rounds them")
    func standard() throws {
        let document = MeadowDocument.standard
        #expect(document.items.count == MeadowScenery.standard.things.count)
        let read = try MeadowDocument.read(try document.fileData(writtenBy: "0.1.0")).document
        #expect(read.entries == document.entries, "already in its file's form")
    }
}

@Suite struct TheLibraryFolder {
    func folder() throws -> (MeadowLibraryFolder, URL) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("meadows-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return (MeadowLibraryFolder(url), url)
    }

    @Test("names are made fit for the file system and unique")
    func names() throws {
        let (library, url) = try folder()
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(library.fileName(forNew: "My Meadow") == "My Meadow.whiskrmeadow")
        try library.write(Data("{}".utf8), as: "My Meadow.whiskrmeadow")
        #expect(library.fileName(forNew: "My Meadow") == "My Meadow 2.whiskrmeadow")
        #expect(library.fileName(forNew: "my meadow") == "my meadow 2.whiskrmeadow", "as the file system compares")
        #expect(library.fileName(forNew: "a/b:c") == "a-b-c.whiskrmeadow")
        #expect(library.fileName(forNew: "...hidden") == "hidden.whiskrmeadow")
        #expect(library.fileName(forNew: "  ") == "Untitled Meadow.whiskrmeadow")
        #expect(library.fileName(forNew: String(repeating: "x", count: 80)) == String(repeating: "x", count: 60) + ".whiskrmeadow")
    }

    @Test("written whole, listed, read back with every check, taken away; nothing outside the folder")
    func files() throws {
        let (library, url) = try folder()
        defer { try? FileManager.default.removeItem(at: url) }
        let document = MeadowDocument(name: "Orchard", entries: [item("tree.cherry", 20, 30, seed: 3)])
        try library.write(try document.fileData(writtenBy: "1.0.0"), as: "Orchard.whiskrmeadow")
        try library.write(Data("x".utf8), as: "Broken.whiskrmeadow")
        #expect(library.fileNames() == ["Broken.whiskrmeadow", "Orchard.whiskrmeadow"])
        #expect(try library.read("Orchard.whiskrmeadow").document.entries == document.entries)
        #expect(throws: (any Error).self) { try library.read("Broken.whiskrmeadow") }
        #expect(throws: (any Error).self) { try library.read("../Orchard.whiskrmeadow") }
        #expect(throws: (any Error).self) { try library.write(Data(), as: "../escape.whiskrmeadow") }
        try library.remove("Broken.whiskrmeadow")
        #expect(library.fileNames() == ["Orchard.whiskrmeadow"])
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: url.path)
        #expect(leftovers == ["Orchard.whiskrmeadow"], "no temporary file left behind")
    }
}
