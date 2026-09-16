import Foundation
import Testing
@testable import MeadowFile

// Whatever bytes arrive, reading gives a meadow or a clear refusal: no crash, and bounded time.

@Suite("Meadow files: fuzzing")
struct MeadowFuzzTests {
    static let fixtures = ["v1-catalog1-everything.whiskrmeadow", "v1-future-minor.whiskrmeadow", "v2-major.whiskrmeadow"]

    /// Reads `data`, which must give a meadow or a `MeadowFileError`; a meadow it gives must save and
    /// read back as itself.
    func survive(_ data: Data) throws {
        do {
            let reading = try MeadowDocument.read(data)
            var document = reading.document
            document.readFrom = nil
            let saved = try document.fileData(writtenBy: "0.1.0")
            var back = try MeadowDocument.read(saved).document
            back.readFrom = nil
            #expect(back == document)
        } catch is MeadowFileError {
            // A clear refusal.
        }
    }

    /// One random change to `bytes`.
    static func mutate(_ bytes: [UInt8], _ random: inout SplitMix) -> [UInt8] {
        var bytes = bytes
        let at = bytes.isEmpty ? 0 : Int.random(in: 0..<bytes.count, using: &random)
        let pieces: [String] = ["1e999", "-1e999", "NaN", "\"NaN\"", "null", "[]", "{}", "-0", "4294967296", "1e-400", "\"\\ud800\"",
                                "99999999999999999999999", "\"tree.oak\"", "\"water.pond\"", ",", ":", "\"", "[[[[[[[[", "}}}}", "\\u0000"]
        switch Int.random(in: 0..<7, using: &random) {
        case 0: bytes = Array(bytes.prefix(at))                                                     // truncate
        case 1: if !bytes.isEmpty { bytes[at] = UInt8.random(in: 0...255, using: &random) }         // flip a byte
        case 2: bytes.insert(contentsOf: Array(pieces.randomElement(using: &random)!.utf8), at: at) // insert a hostile piece
        case 3: if !bytes.isEmpty { bytes.remove(at: at) }                                          // drop a byte
        case 4: bytes.insert(contentsOf: [0xC3, 0x28, 0xFF, 0xED, 0xA0, 0x80], at: at)              // invalid UTF-8
        case 5:                                                                                     // swap a number for a huge one
            if let digit = bytes.indices.dropFirst(at).first(where: { (0x30...0x39).contains(bytes[$0]) }) {
                bytes.replaceSubrange(digit...digit, with: Array("123456789012345678901234567890e300".utf8))
            }
        default:                                                                                    // duplicate a slice
            let end = min(bytes.count, at + Int.random(in: 1...64, using: &random))
            bytes.insert(contentsOf: bytes[at..<end], at: end)
        }
        return bytes
    }

    @Test("thousands of mutated fixtures: each gives a meadow or a refusal")
    func mutations() throws {
        var random = SplitMix(1112)
        for name in Self.fixtures {
            let original = Array(try Fixtures.data(name))
            for _ in 0..<1_500 {
                var bytes = original
                for _ in 0..<Int.random(in: 1...4, using: &random) { bytes = Self.mutate(bytes, &random) }
                try survive(Data(bytes))
            }
        }
    }

    @Test("hostile shapes at the size limit are read or refused in under 200 ms")
    func hostile() throws {
        let limit = MeadowFormat.maxBytes
        func padded(_ prefix: String, _ fill: String, _ suffix: String) -> Data {
            let room = limit - prefix.utf8.count - suffix.utf8.count
            var text = prefix
            text += String(repeating: fill, count: room / fill.utf8.count)
            text += suffix
            return Data(text.utf8)
        }
        let invalidPrefix = #"{"whiskrMeadow": 1, "x": ""#
        // A section from a newer Whiskr may be as large as the file allows: it is kept, not refused.
        let cases: [(String, Data, MeadowFileError?)] = [
            ("deep nesting", padded("", "[", ""), .notJSON(.tooDeep)),
            ("a giant array", padded(#"{"whiskrMeadow": 1, "x": ["#, "1,", "1]}"), .notJSON(.tooManyValues)),
            ("a giant name", padded(#"{"whiskrMeadow": 1, "name": ""#, "ねこ", #""}"#), .textTooLong(.name)),
            ("a giant name of invisible characters", padded(#"{"whiskrMeadow": 1, "name": ""#, #"\u200b"#, #""}"#), .textTooLong(.name)),
            ("a giant escaped string", padded(invalidPrefix, #"\u00e9"#, #""}"#), nil),
            ("a giant number", padded(#"{"whiskrMeadow": 1, "x": "#, "9", "}"), nil),
            ("invalid UTF-8", Data(Array(invalidPrefix.utf8) + Array(repeating: 0xFF, count: limit - 30) + Array("\"}".utf8)),
             .notJSON(.invalidUTF8(offset: invalidPrefix.utf8.count - 1))),
            ("a giant run list", padded(#"{"whiskrMeadow": 1, "ground": {"cells": 512, "reach": 150, "paints": [], "runs": ["#, "0,1,", "0,1]}}"),
             .notJSON(.tooManyValues)),
            ("one past the size", Data(repeating: 0x20, count: limit + 1), .tooLarge(bytes: limit + 1)),
        ]
        for (what, data, expected) in cases {
            var error: MeadowFileError?
            let took = threadTime { error = readError(data) }
            #expect(error == expected, "\(what)")
            #expect(took < .milliseconds(200), "\(what) took \(took)")
        }
    }

    @Test("5,000 things read and write in bounded time")
    func full() throws {
        let items = (0..<5_000).map { i in
            #"{ "at": [\#(Double(i % 100) - 50), \#(Double(i / 100) - 25)], "id": "flower.daisy", "size": [1.04, 0.97, 1], "tilt": [0.02, -0.03], "turn": 0.7854, "variant": 1 }"#
        }.joined(separator: ",\n")
        let data = Data(#"{"whiskrMeadow": 1, "items": [\#(items)]}"#.utf8)
        var document = MeadowDocument()
        let reading = try threadTime { document = try MeadowDocument.read(data).document }
        #expect(document.items.count == 5_000)
        let writing = try threadTime { _ = try document.fileData(writtenBy: "0.1.0") }
        #expect(reading < .milliseconds(500) && writing < .milliseconds(1_000), "read \(reading), wrote \(writing)")
    }
}
