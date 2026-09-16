import Foundation
import Testing
@testable import MeadowFile

// The meadow file's own JSON: a strict reader with limits, and a writer that gives one set of bytes per value.

@Suite("Meadow files: JSON")
struct MeadowJSONTests {
    static let roomy = MeadowJSON.Limits(depth: 64, values: 1_000_000)

    func parse(_ text: String, _ limits: MeadowJSON.Limits = roomy) throws -> MeadowJSON {
        try MeadowJSON.parse(Data(text.utf8), limits: limits)
    }

    func error(_ bytes: [UInt8], _ limits: MeadowJSON.Limits = roomy) -> MeadowJSONError? {
        do {
            _ = try MeadowJSON.parse(Data(bytes), limits: limits)
            return nil
        } catch {
            return error as? MeadowJSONError
        }
    }

    func error(_ text: String, _ limits: MeadowJSON.Limits = roomy) -> MeadowJSONError? {
        error(Array(text.utf8), limits)
    }

    @Test("every kind of value reads, and numbers keep the text they were written with")
    func kinds() throws {
        let value = try parse(#" { "a": [null, true, false, -0, 1.50, 2e-3, 12345678901234567890123], "b": { }, "c": [ ] } "#)
        #expect(value == .object([
            "a": .array([.null, .bool(true), .bool(false), .number("-0"), .number("1.50"), .number("2e-3"), .number("12345678901234567890123")]),
            "b": .object([:]), "c": .array([]),
        ]))
        #expect(value.object?["a"]?.array?[4].double == 1.5)
        #expect(try parse("1e999").double == .infinity)
        #expect(try parse("7").integer == 7 && (try parse("7.5")).integer == nil && (try parse("7.0")).integer == 7)
    }

    @Test("escapes read as what they stand for, surrogate pairs included; a byte order mark is ignored")
    func escapes() throws {
        #expect(try parse(#""a\"b\\c\/d\b\f\n\r\t\u00e9\ud83d\udc08""#) == .string("a\"b\\c/d\u{8}\u{c}\n\r\t\u{E9}\u{1F408}"))
        #expect(try MeadowJSON.parse(Data([0xEF, 0xBB, 0xBF] + Array("[1]".utf8)), limits: Self.roomy) == .array([.number("1")]))
        #expect(try parse("\"ねこ ✿\"") == .string("ねこ ✿"))
    }

    @Test("what is not strict JSON is refused, with where")
    func refused() {
        #expect(error("[1,]") == .syntax(offset: 3))
        #expect(error("{\"a\":1,}") == .syntax(offset: 7))
        #expect(error("01") == .syntax(offset: 1))
        #expect(error("1.") == .truncated)
        #expect(error("1.e3") == .syntax(offset: 2))
        #expect(error("-") == .truncated)
        #expect(error("+1") == .syntax(offset: 0))
        #expect(error("NaN") == .syntax(offset: 0))
        #expect(error("Infinity") == .syntax(offset: 0))
        #expect(error("'a'") == .syntax(offset: 0))
        #expect(error("[1] // note") == .syntax(offset: 4))
        #expect(error("[1] [2]") == .syntax(offset: 4))
        #expect(error("tru") == .truncated)
        #expect(error("trux") == .syntax(offset: 3))
        #expect(error("\"a\tb\"") == .syntax(offset: 2))
        #expect(error(#""\x""#) == .syntax(offset: 2))
        #expect(error(#""\ud83d""#) == .syntax(offset: 7))
        #expect(error(#""\udc08""#) == .syntax(offset: 3))
        #expect(error(#""\ud83d\u0041""#) == .syntax(offset: 9))
        #expect(error("{\"a\":1") == .truncated)
        #expect(error("") == .truncated)
        #expect(error("{1:2}") == .syntax(offset: 1))
    }

    @Test("bytes that are not UTF-8 are refused, in a string and outside one")
    func notUTF8() {
        #expect(error([0x22, 0x61, 0xFF, 0x22]) == .invalidUTF8(offset: 0))
        #expect(error([0x22, 0xC3, 0x22]) == .invalidUTF8(offset: 0))
        #expect(error([0x22, 0xED, 0xA0, 0x80, 0x22]) == .invalidUTF8(offset: 0)) // an encoded surrogate
        #expect(error([0x22, 0x5C, 0x6E, 0xC0, 0xAF, 0x22]) == .invalidUTF8(offset: 0)) // overlong, after an escape
        #expect(error([0x5B, 0xC3, 0xA9, 0x5D]) == .syntax(offset: 1))
    }

    @Test("a key twice in one object is refused, also when the two differ only in normalisation")
    func duplicateKeys() {
        #expect(error(#"{"a":1,"a":2}"#) == .duplicateKey(offset: 7))
        #expect(error("{\"\u{E9}\":1,\"e\u{301}\":2}") == .duplicateKey(offset: 8))
        #expect(error(#"{"a":{"b":1},"b":{"b":2}}"#) == nil)
    }

    @Test("nesting and value counts stop at their limits")
    func limits() {
        let limits = MeadowJSON.Limits(depth: 16, values: 100)
        #expect(error(String(repeating: "[", count: 16) + String(repeating: "]", count: 16), limits) == nil)
        #expect(error(String(repeating: "[", count: 17) + String(repeating: "]", count: 17), limits) == .tooDeep)
        #expect(error(String(repeating: "[", count: 100_000), limits) == .tooDeep)
        #expect(error("[" + Array(repeating: "1", count: 99).joined(separator: ",") + "]", limits) == nil)
        #expect(error("[" + Array(repeating: "1", count: 100).joined(separator: ",") + "]", limits) == .tooManyValues)
        #expect(MeadowJSON.array([.number("1"), .object(["a": .null])]).valueCount == 4)
    }

    @Test("written with sorted keys, two-space indent, one thing per line, the same bytes every time")
    func layout() throws {
        let value = MeadowJSON.object([
            "b": .array([.object(["z": .number("1"), "a": .array([.number("1"), .number("2")])]), .object([:])]),
            "a": .object(["y": .array([.number("3")]), "x": .string("é")]),
            "c": .array([.number("1"), .array([.number("2")])]),
            "d": .object([:]),
            "B": .null,
        ])
        #expect(value.fileText == """
        {
          "B": null,
          "a": {
            "x": "é",
            "y": [3]
          },
          "b": [
            { "a": [1, 2], "z": 1 },
            {}
          ],
          "c": [1, [2]],
          "d": {}
        }

        """)
        #expect(try MeadowJSON.parse(Data(value.fileText.utf8), limits: Self.roomy) == value)
        #expect(value.inlineText == #"{ "B": null, "a": { "x": "é", "y": [3] }, "b": [{ "a": [1, 2], "z": 1 }, {}], "c": [1, [2]], "d": {} }"#)
    }

    @Test("strings are written with only what JSON needs escaped, and read back the same")
    func writtenStrings() throws {
        let text = "q\"b\\s/\u{0}\u{1F}\n\t\u{2028}\u{2029}é🐈\u{7F}"
        let written = MeadowJSON.string(text).inlineText
        #expect(written == #""q\"b\\s/\u0000\u001f\n\t\u2028\u2029é🐈"# + "\u{7F}\"")
        #expect(try parse(written) == .string(text))
    }

    @Test("numbers are written to 4 decimals, with no exponent and no negative zero, and read back as they were written")
    func numbers() throws {
        #expect(MeadowJSON.literal(0) == "0")
        #expect(MeadowJSON.literal(-0.0) == "0")
        #expect(MeadowJSON.literal(-0.00004) == "0")
        #expect(MeadowJSON.literal(1.23456) == "1.2346")
        #expect(MeadowJSON.literal(-3.1) == "-3.1")
        #expect(MeadowJSON.literal(150) == "150")
        #expect(MeadowJSON.literal(0.0001) == "0.0001")
        #expect(MeadowJSON.literal(4_294_967_295) == "4294967295")
        var random = SplitMix(7)
        for _ in 0..<20_000 {
            let value = Double.random(in: -400...400, using: &random)
            let q = MeadowJSON.quantized(value)
            #expect(Double(MeadowJSON.literal(value)) == q)
            #expect(MeadowJSON.quantized(q) == q && MeadowJSON.literal(q) == MeadowJSON.literal(value))
            #expect(abs(q - value) <= 0.00005 + 1e-12)
        }
    }
}
