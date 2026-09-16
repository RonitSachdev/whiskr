import Foundation
import MeadowFile
import MeadowScene
import Testing
import simd
@testable import WhiskrMeadow

// My Meadows: meadows made, copied, renamed and imported in the folder without one ever replacing another;
// files read from anywhere only once they are known to be ordinary files of a meadow's size; changes made on
// disk by something else told from the app's own; and the things a newer Whiskr made, shown as parcels while
// editing, moved and taken away, and never lost.

private func item(_ id: String, _ x: Double, _ z: Double, seed: UInt32? = nil) -> MeadowEntry {
    .item(MeadowFile.MeadowItem(asset: id, placement: .at(MeadowPoint(x, z)), seed: seed))
}

private func temporaryFolder() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("meadows-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// The MeadowFile tests' fixtures, read from beside these tests (they are locked there).
private func fixture(_ name: String) throws -> Data {
    let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    return try Data(contentsOf: here.deletingLastPathComponent().appendingPathComponent("MeadowFileTests/Fixtures/MeadowFiles/\(name)"))
}

@Suite struct MyMeadows {
    let orchard = MeadowDocument(name: "Orchard", entries: [item("tree.cherry", 20, 30, seed: 3), item("flower.daisy", 2, 4)])

    @Test("a new meadow from the Default or from nothing takes a name of its own and says it inside")
    func new() throws {
        let url = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: url) }
        let folder = MeadowLibraryFolder(url)
        let first = try folder.add(.standard, named: "My Meadow", writtenBy: "1.0.0")
        let second = try folder.add(.empty, named: "My Meadow", writtenBy: "1.0.0")
        #expect(first == "My Meadow.whiskrmeadow" && second == "My Meadow 2.whiskrmeadow")
        #expect(try folder.read(first).document.entries == MeadowDocument.standard.entries)
        let empty = try folder.read(second).document
        #expect(empty.entries.isEmpty && empty.name == "My Meadow 2")
    }

    @Test("a copy is the same meadow under the next free name, what it keeps from a newer Whiskr kept too")
    func duplicate() throws {
        let url = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: url) }
        let folder = MeadowLibraryFolder(url)
        try folder.write(try fixture("import-newer-catalog.whiskrmeadow"), as: "Orchard Study.whiskrmeadow")
        let copy = try folder.duplicate("Orchard Study.whiskrmeadow", writtenBy: "1.0.0")
        let again = try folder.duplicate("Orchard Study.whiskrmeadow", writtenBy: "1.0.0")
        #expect(copy == "Orchard Study 2.whiskrmeadow" && again == "Orchard Study 3.whiskrmeadow")
        #expect(try folder.duplicate(copy, writtenBy: "1.0.0") == "Orchard Study 4.whiskrmeadow", "a copy of a copy is of the family, not “… 2 2”")
        #expect(folder.fileNames() == ["Orchard Study", "Orchard Study 2", "Orchard Study 3", "Orchard Study 4"].map { "\($0).whiskrmeadow" }, "in the order of their names")
        #expect(MeadowLibraryFolder.family(of: "Pond 12") == "Pond" && MeadowLibraryFolder.family(of: "2046") == "2046" && MeadowLibraryFolder.family(of: "Route 66 x") == "Route 66 x")
        let original = try folder.read("Orchard Study.whiskrmeadow").document, copied = try folder.read(copy).document
        #expect(copied.entries == original.entries && copied.parcels.count == 6 && copied.ground == original.ground)
        #expect(copied.name == "Orchard Study 2" && copied.author == "Hana")
    }

    @Test("renaming: trimmed and made plain text, the file and the name inside both changed, never onto another meadow")
    func rename() throws {
        let url = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: url) }
        let folder = MeadowLibraryFolder(url)
        try folder.write(try orchard.fileData(writtenBy: "1.0.0"), as: "Orchard.whiskrmeadow")
        try folder.write(try MeadowDocument(name: "Pond").fileData(writtenBy: "1.0.0"), as: "Pond.whiskrmeadow")
        let renamed = try folder.rename("Orchard.whiskrmeadow", to: "  Summer\u{202E} Orchard\n ", writtenBy: "1.0.0")
        #expect(renamed == "Summer Orchard.whiskrmeadow")
        #expect(folder.fileNames() == ["Pond.whiskrmeadow", "Summer Orchard.whiskrmeadow"])
        let read = try folder.read(renamed).document
        #expect(read.name == "Summer Orchard" && read.entries == orchard.entries)
        // Onto another's name: the next free one; only the case changed: the same file, renamed.
        #expect(try folder.rename(renamed, to: "Pond", writtenBy: "1.0.0") == "Pond 2.whiskrmeadow")
        #expect(try folder.rename("Pond 2.whiskrmeadow", to: "pond 2", writtenBy: "1.0.0") == "pond 2.whiskrmeadow")
        #expect(Set(folder.fileNames()) == ["Pond.whiskrmeadow", "pond 2.whiskrmeadow"])
        #expect(try folder.rename("pond 2.whiskrmeadow", to: "pond 2", writtenBy: "1.0.0") == "pond 2.whiskrmeadow", "nothing to change")
        #expect(throws: MeadowFileError.textTooLong(.name)) { try folder.rename("Pond.whiskrmeadow", to: " \u{200B} ", writtenBy: "1.0.0") }
        #expect(throws: MeadowFileError.textTooLong(.name)) { try folder.rename("Pond.whiskrmeadow", to: String(repeating: "x", count: 61), writtenBy: "1.0.0") }
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: url.path).sorted()
        #expect(leftovers == ["Pond.whiskrmeadow", "pond 2.whiskrmeadow"], "nothing half renamed")
    }

    @Test("an import is added byte for byte under its own name, the next free one when that is taken; never over another")
    func importing() throws {
        let url = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: url) }
        let folder = MeadowLibraryFolder(url)
        let data = try fixture("import-newer-catalog.whiskrmeadow")
        let reading = try MeadowDocument.read(data)
        #expect(folder.importedFileName(reading, fallback: "shared") == "Orchard Study.whiskrmeadow")
        let first = try folder.addImported(data, reading, fallback: "shared")
        let second = try folder.addImported(data, reading, fallback: "shared")
        #expect(first == "Orchard Study.whiskrmeadow" && second == "Orchard Study 2.whiskrmeadow")
        #expect(try folder.data(first) == data)
        #expect(try folder.data(second) == data)
        // No name inside: the name of the file it came in.
        let unnamed = try MeadowDocument.read(Data(#"{ "whiskrMeadow": 1, "items": [] }"#.utf8))
        #expect(folder.importedFileName(unnamed, fallback: "Picnic\u{0007} Spot") == "Picnic Spot.whiskrmeadow")
        #expect(folder.importedFileName(unnamed, fallback: "") == "Untitled Meadow.whiskrmeadow")
    }

    @Test("a file from anywhere is read only when it is an ordinary file no larger than a meadow, and no more of it than that")
    func boundedReading() throws {
        let url = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: url) }
        let big = url.appendingPathComponent("big.whiskrmeadow")
        try Data(repeating: 0x20, count: MeadowFormat.maxBytes + 1).write(to: big)
        #expect(throws: MeadowFileError.tooLarge(bytes: MeadowFormat.maxBytes + 1)) { try MeadowLibraryFolder.data(at: big) }
        #expect(throws: (any Error).self) { try MeadowLibraryFolder.data(at: url) }
        let pipe = url.appendingPathComponent("pipe.whiskrmeadow")
        #expect(mkfifo(pipe.path, 0o600) == 0)
        #expect(throws: (any Error).self) { try MeadowLibraryFolder.data(at: pipe) }
        let device = url.appendingPathComponent("zero.whiskrmeadow")
        try FileManager.default.createSymbolicLink(at: device, withDestinationURL: URL(fileURLWithPath: "/dev/zero"))
        #expect(throws: (any Error).self) { try MeadowLibraryFolder.data(at: device) }
        let fine = url.appendingPathComponent("fine.whiskrmeadow")
        try Data("{}".utf8).write(to: fine)
        #expect(try MeadowLibraryFolder.data(at: fine) == Data("{}".utf8))
    }
}

@Suite struct ChangesOnDisk {
    @Test("the meadow shown: its own save is nothing; another's change reloads it, or asks while it is edited; gone shows the Default, or asks")
    func judged() {
        #expect(MeadowDiskChange.judge(known: 7, onDisk: 7, editing: false) == .nothing)
        #expect(MeadowDiskChange.judge(known: 7, onDisk: 7, editing: true) == .nothing)
        #expect(MeadowDiskChange.judge(known: 7, onDisk: 8, editing: false) == .reload)
        #expect(MeadowDiskChange.judge(known: 7, onDisk: 8, editing: true) == .ask)
        #expect(MeadowDiskChange.judge(known: 7, onDisk: nil, editing: false) == .gone)
        #expect(MeadowDiskChange.judge(known: 7, onDisk: nil, editing: true) == .askGone)
        #expect(MeadowDiskChange.judge(known: nil, onDisk: nil, editing: true) == .nothing)
    }

    @Test("a file's digest follows its bytes, its stamp its size and time")
    func digests() throws {
        let url = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: url) }
        let folder = MeadowLibraryFolder(url)
        try folder.write(Data("one".utf8), as: "A.whiskrmeadow")
        let first = folder.digest("A.whiskrmeadow")
        #expect(first == MeadowLibraryFolder.digest(Data("one".utf8)) && folder.stamp("A.whiskrmeadow")?.size == 3)
        try folder.write(Data("two".utf8), as: "A.whiskrmeadow")
        #expect(folder.digest("A.whiskrmeadow") != first)
        #expect(folder.digest("B.whiskrmeadow") == nil && folder.stamp("B.whiskrmeadow") == nil)
    }

    @MainActor
    @Test("the folder watch tells of a meadow added, one written in place and one taken away")
    func watch() async throws {
        let url = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: url) }
        final class Count: @unchecked Sendable { var value = 0 }
        let count = Count()
        let watch = MeadowFolderWatch(folder: url) { count.value += 1 }
        func waitForChange(_ act: () throws -> Void) async rethrows -> Bool {
            let before = count.value
            try act()
            for _ in 0..<40 where count.value == before { try? await Task.sleep(for: .milliseconds(50)) }
            return count.value > before
        }
        try await Task.sleep(for: .milliseconds(100))
        let file = url.appendingPathComponent("A.whiskrmeadow")
        #expect(try await waitForChange { try Data("{}".utf8).write(to: file, options: .atomic) }, "added")
        watch.watch(file: file)
        try await Task.sleep(for: .milliseconds(100))
        #expect(try await waitForChange {
            let handle = try FileHandle(forWritingTo: file)
            try handle.write(contentsOf: Data(" ".utf8))
            try handle.close()
        }, "written in place")
        #expect(try await waitForChange { try FileManager.default.removeItem(at: file) }, "taken away")
        withExtendedLifetime(watch) {}
    }
}

@Suite struct ThingsFromANewerWhiskr {
    var meadow: MeadowDocument {
        MeadowDocument(entries: [
            item("tree.oak", 50, 10, seed: 7),
            .parcel(MeadowParcel(fields: ["id": .string("garden.pond"), "at": .array([.number(20), .number(-30)]), "lilies": .array([.number(1)])])),
            .parcel(MeadowParcel(fields: ["id": .string("cat.tower"), "at": .array([.number(36), .number(-4)])])),
            .parcel(MeadowParcel(fields: ["id": .string("garden.hedgeRun"), "points": .array([.array([.number(0), .number(60)]), .array([.number(10), .number(60)])])])),
            .parcel(MeadowParcel(fields: ["id": .string("light.beacon")])),
        ])
    }

    @Test("while editing each shows as a parcel where it stands (one with no spot is kept and not shown); out of editing none is drawn")
    func shown() {
        var session = MeadowEditSession(meadow)
        #expect(session.scenery.things.map(\.id) == ["tree.oak"] && session.undrawnCount == 4)
        session.showsParcels = true
        #expect(session.scenery.things.map(\.id) == ["tree.oak", MeadowScenery.parcel, MeadowScenery.parcel, MeadowScenery.parcel])
        #expect(session.shown == [1, 2, 3, 4] && session.thingIndex(of: 5) == nil)
        #expect(session.scenery.things[1].x == 20 && session.scenery.things[1].z == -30 && session.scenery.things[3].z == 60)
        #expect(session.isParcel(2) && session.isParcel(3) && session.isParcel(4) && session.isParcel(5) && !session.isParcel(1))
        #expect(session.spot(2) == MeadowPoint(20, -30) && session.spot(5) == nil)
        session.showsParcels = false
        #expect(session.scenery.things.map(\.id) == ["tree.oak"])
    }

    @Test("moved, they keep every field as it was but where they stand; never moved out of the meadow; saved and read back as moved")
    func moved() throws {
        var session = MeadowEditSession(meadow)
        session.showsParcels = true
        let change = try session.move([2, 4], by: SIMD2(1.25, -2)).get()
        #expect(change.edited.count == 2)
        let pond = try #require(session.parcel(2))
        #expect(pond.fields["at"] == .array([.number(21.25), .number(-32)]) && pond.fields["lilies"] == .array([.number(1)]))
        #expect(session.parcel(4)?.fields["points"] == .array([.array([.number(1.25), .number(58)]), .array([.number(11.25), .number(58)])]))
        #expect(session.scenery.things[1].x == 21.25)
        #expect(throws: MeadowEditRefused.self) { try session.move([2], by: SIMD2(200, 0)).get() }
        // Undone: as they were.
        session.apply(change.inverse)
        #expect(session.document.entries == meadow.entries)
        session.apply(change)
        let back = try MeadowDocument.read(try session.document.fileData(writtenBy: "1.0.0")).document
        #expect(back.parcels == session.document.parcels && back.parcels.count == 4)
    }

    @Test("taken away and put back (undone) in their place; the rest of a meadow's things from a newer Whiskr untouched")
    func deleted() throws {
        var session = MeadowEditSession(meadow)
        session.showsParcels = true
        let change = session.delete([2, 3])
        #expect(session.document.parcels.map(\.asset) == ["garden.hedgeRun", "light.beacon"] && session.document.items.map(\.asset) == ["tree.oak"])
        #expect(session.scenery.things.map(\.id) == ["tree.oak", MeadowScenery.parcel])
        session.apply(change.inverse)
        #expect(session.document.entries == meadow.entries)
        #expect(session.scenery.things.count == 4)
    }
}
