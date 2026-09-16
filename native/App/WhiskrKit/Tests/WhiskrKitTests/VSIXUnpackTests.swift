import Foundation
import Testing
@testable import WhiskrKit

/// A zip archive written entry by entry (stored, not compressed), so a test can hold what no zip tool
/// writes: names that climb out ("../x"), absolute names, links, and a list of contents that lies.
struct ZipWriter {
    struct Entry {
        var name: String
        var data: Data
        /// A symbolic link to `data` (as text), as a Unix zip tool stores one.
        var isLink = false
        /// What the central directory says it unpacks to; the real size when nil.
        var declaredSize: UInt32?
    }

    var entries: [Entry] = []

    func data() -> Data {
        var out = Data(), directory = Data()
        func le16(_ value: Int, _ to: inout Data) { to.append(contentsOf: [UInt8(value & 0xff), UInt8(value >> 8 & 0xff)]) }
        func le32(_ value: UInt32, _ to: inout Data) { for shift in stride(from: 0, to: 32, by: 8) { to.append(UInt8(value >> UInt32(shift) & 0xff)) } }
        for entry in entries {
            let name = Data(entry.name.utf8), crc = Self.crc32(entry.data), offset = UInt32(out.count)
            le32(0x0403_4b50, &out); le16(20, &out); le16(0, &out); le16(0, &out); le16(0, &out); le16(0, &out)
            le32(crc, &out); le32(UInt32(entry.data.count), &out); le32(UInt32(entry.data.count), &out)
            le16(name.count, &out); le16(0, &out)
            out.append(name); out.append(entry.data)
            le32(0x0201_4b50, &directory); le16(3 << 8 | 20, &directory); le16(20, &directory); le16(0, &directory); le16(0, &directory)
            le16(0, &directory); le16(0, &directory)
            le32(crc, &directory); le32(UInt32(entry.data.count), &directory); le32(entry.declaredSize ?? UInt32(entry.data.count), &directory)
            le16(name.count, &directory); le16(0, &directory); le16(0, &directory); le16(0, &directory); le16(0, &directory)
            le32(UInt32(entry.isLink ? 0o120777 : 0o100644) << 16, &directory); le32(offset, &directory)
            directory.append(name)
        }
        let directoryOffset = UInt32(out.count)
        out.append(directory)
        le32(0x0605_4b50, &out); le16(0, &out); le16(0, &out); le16(entries.count, &out); le16(entries.count, &out)
        le32(UInt32(directory.count), &out); le32(directoryOffset, &out); le16(0, &out)
        return out
    }

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = crc & 1 == 1 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1 }
        }
        return ~crc
    }
}

@Suite("A .vsix: its size checked before unpacking, and nothing landing outside its folder")
struct VSIXUnpackTests {
    let scratch: URL

    init() throws {
        // Not "whiskr-vsix-…": that is the importer's own unpacking folder, which another suite counts.
        let made = FileManager.default.temporaryDirectory.appendingPathComponent("whiskr-unpack-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: made, withIntermediateDirectories: true)
        scratch = made.resolvingSymlinksInPath()
    }

    func write(_ zip: ZipWriter, as name: String = "x.vsix") throws -> URL {
        let url = scratch.appendingPathComponent(name)
        try zip.data().write(to: url)
        return url
    }

    @Test("names that climb out, absolute names and a write through a link all land inside the folder")
    func staysInside() throws {
        defer { try? FileManager.default.removeItem(at: scratch) }
        let outside = scratch.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let absolute = "/tmp/whiskr-absolute-\(UUID().uuidString).txt"
        defer { try? FileManager.default.removeItem(atPath: absolute) }
        let zip = ZipWriter(entries: [
            .init(name: "extension/package.json", data: Data(#"{ "name": "x", "publisher": "p" }"#.utf8)),
            .init(name: "../climbed.txt", data: Data("out".utf8)),
            .init(name: "extension/../../climbed-too.txt", data: Data("out".utf8)),
            .init(name: absolute, data: Data("out".utf8)),
            .init(name: "extension/link", data: Data(outside.path.utf8), isLink: true),
            .init(name: "extension/link/through.txt", data: Data("out".utf8)),
        ])
        #expect(ZipDirectory.contents(of: try write(zip))?.entries == 6)
        let folder = scratch.appendingPathComponent("unpacked", isDirectory: true)
        _ = try? ExtensionManifest.unpack(vsix: scratch.appendingPathComponent("x.vsix"), into: folder)
        #expect(!FileManager.default.fileExists(atPath: scratch.appendingPathComponent("climbed.txt").path))
        #expect(!FileManager.default.fileExists(atPath: scratch.appendingPathComponent("climbed-too.txt").path))
        #expect(!FileManager.default.fileExists(atPath: absolute))
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("extension/package.json").path))
    }

    @Test("an archive that says it unpacks past the limit, or holds too many files, is not unpacked")
    func refusesBombs() throws {
        defer { try? FileManager.default.removeItem(at: scratch) }
        let bomb = ZipWriter(entries: [
            .init(name: "extension/package.json", data: Data("{}".utf8)),
            .init(name: "extension/huge.bin", data: Data("x".utf8), declaredSize: 0xFFFF_FFF0),
        ])
        let folder = scratch.appendingPathComponent("bomb", isDirectory: true)
        #expect(throws: ExtensionManifest.Failure.self) { try ExtensionManifest.unpack(vsix: try write(bomb), into: folder) }
        #expect(!FileManager.default.fileExists(atPath: folder.path))

        let many = ZipWriter(entries: (0...ExtensionManifest.mostEntries).map { .init(name: "e/\($0)", data: Data()) })
        #expect(ZipDirectory.contents(of: try write(many, as: "many.vsix"))?.entries == ExtensionManifest.mostEntries + 1)
        #expect(throws: ExtensionManifest.Failure.self) { try ExtensionManifest.unpack(vsix: scratch.appendingPathComponent("many.vsix"), into: folder) }

        // Not a zip archive at all.
        try Data("not a zip".utf8).write(to: scratch.appendingPathComponent("junk.vsix"))
        #expect(ZipDirectory.contents(of: scratch.appendingPathComponent("junk.vsix")) == nil)

        // A ZIP64 end record whose directory would end past 2^64: read as not a zip, never a trap.
        func le(_ value: UInt64, _ bytes: Int) -> [UInt8] { (0..<bytes).map { UInt8(value >> (8 * UInt64($0)) & 0xff) } }
        var crafted: [UInt8] = le(0x0606_4b50, 4) + le(44, 8) + le(45, 2) + le(45, 2) + le(0, 4) + le(0, 4) + le(1, 8) + le(1, 8)
        crafted += le(UInt64(1024), 8) + le(UInt64.max - 10, 8)
        crafted += le(0x0706_4b50, 4) + le(0, 4) + le(0, 8) + le(1, 4)
        crafted += le(0x0605_4b50, 4) + le(0, 2) + le(0, 2) + le(0xFFFF, 2) + le(0xFFFF, 2) + le(0xFFFF_FFFF, 4) + le(0xFFFF_FFFF, 4) + le(0, 2)
        try Data(crafted).write(to: scratch.appendingPathComponent("zip64.vsix"))
        #expect(ZipDirectory.contents(of: scratch.appendingPathComponent("zip64.vsix")) == nil)
    }
}
