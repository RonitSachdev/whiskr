import Foundation

/// Any JSON value, as a meadow file holds it. A meadow file comes from anyone, so it is read by this
/// module's own parser (strict RFC 8259, with limits checked while reading) rather than by
/// `JSONSerialization`, and what this app does not understand is kept in this shape and written back
/// unchanged.
///
/// A number keeps the text it was written with ("1.50" stays "1.50", a 20-digit integer keeps every
/// digit), so content from a newer Whiskr survives a load and save exactly. Objects compare by their
/// keys' canonical equivalence (Swift's `String` equality), so two keys that differ only in Unicode
/// normalisation count as the same key, and a file that repeats a key is refused.
public indirect enum MeadowJSON: Sendable, Hashable {
    case null
    case bool(Bool)
    /// The number's literal text, always valid JSON number syntax.
    case number(String)
    case string(String)
    case array([MeadowJSON])
    case object([String: MeadowJSON])

    /// The number, written the way a meadow file writes its own numbers (`MeadowJSON.literal(_:)`).
    public static func number(_ value: Double) -> MeadowJSON { .number(literal(value)) }

    /// The number as a `Double`, if this is a number. Can be infinite for a literal like `1e999`.
    public var double: Double? {
        if case .number(let text) = self { Double(text) } else { nil }
    }

    /// The number as an integer, if this is a number with an exact integer value in `Int`'s range.
    public var integer: Int? {
        guard let value = double, value.isFinite, value == value.rounded(), abs(value) <= 9_007_199_254_740_992 else { return nil }
        return Int(value)
    }

    public var string: String? {
        if case .string(let value) = self { value } else { nil }
    }

    public var array: [MeadowJSON]? {
        if case .array(let value) = self { value } else { nil }
    }

    public var object: [String: MeadowJSON]? {
        if case .object(let value) = self { value } else { nil }
    }

    /// How many JSON values this is, counting itself and everything inside it.
    public var valueCount: Int {
        switch self {
        case .array(let items): items.reduce(1) { $0 + $1.valueCount }
        case .object(let fields): fields.values.reduce(1) { $0 + $1.valueCount }
        default: 1
        }
    }
}

// MARK: - Reading

/// Why bytes are not a JSON document this module accepts.
public enum MeadowJSONError: Error, Equatable, Sendable {
    /// Not JSON at `offset` (bytes from the start): a stray character, a missing comma, a bad number,
    /// a raw control character in a string, an escape for half a surrogate pair, text after the end.
    case syntax(offset: Int)
    /// A string that is not valid UTF-8, starting at `offset`.
    case invalidUTF8(offset: Int)
    /// The input ends in the middle of a value.
    case truncated
    /// Arrays and objects nested deeper than `MeadowJSON.Limits.depth`.
    case tooDeep
    /// More values than `MeadowJSON.Limits.values`.
    case tooManyValues
    /// An object names the same key twice, at `offset`.
    case duplicateKey(offset: Int)
}

extension MeadowJSON {
    /// What the parser stops at. Reading stops at the first value over a limit, so neither time nor
    /// memory grows with what is beyond it.
    public struct Limits: Sendable, Equatable {
        /// Arrays and objects inside one another; the outermost is 1.
        public var depth: Int
        /// Every value, scalars and containers alike.
        public var values: Int

        public init(depth: Int, values: Int) {
            self.depth = depth
            self.values = values
        }
    }

    /// Parses `data` as exactly one JSON value (white space around it allowed, and a UTF-8 byte order
    /// mark before it ignored).
    public static func parse(_ data: Data, limits: Limits) throws -> MeadowJSON {
        try data.withUnsafeBytes { raw in
            var parser = Parser(bytes: raw.bindMemory(to: UInt8.self), limits: limits)
            return try parser.document()
        }
    }

    private struct Parser {
        let bytes: UnsafeBufferPointer<UInt8>
        let limits: Limits
        var at = 0
        var depth = 0
        var values = 0

        init(bytes: UnsafeBufferPointer<UInt8>, limits: Limits) {
            self.bytes = bytes
            self.limits = limits
        }

        mutating func document() throws -> MeadowJSON {
            if bytes.count >= 3, bytes[0] == 0xEF, bytes[1] == 0xBB, bytes[2] == 0xBF { at = 3 }
            let value = try self.value()
            skipSpace()
            guard at == bytes.count else { throw MeadowJSONError.syntax(offset: at) }
            return value
        }

        mutating func skipSpace() {
            while at < bytes.count {
                switch bytes[at] {
                case 0x20, 0x09, 0x0A, 0x0D: at += 1
                default: return
                }
            }
        }

        mutating func next() throws -> UInt8 {
            skipSpace()
            guard at < bytes.count else { throw MeadowJSONError.truncated }
            return bytes[at]
        }

        mutating func count() throws {
            values += 1
            if values > limits.values { throw MeadowJSONError.tooManyValues }
        }

        mutating func value() throws -> MeadowJSON {
            let byte = try next()
            try count()
            switch byte {
            case UInt8(ascii: "{"): return try object()
            case UInt8(ascii: "["): return try array()
            case UInt8(ascii: "\""): return .string(try string())
            case UInt8(ascii: "t"): try word("true"); return .bool(true)
            case UInt8(ascii: "f"): try word("false"); return .bool(false)
            case UInt8(ascii: "n"): try word("null"); return .null
            case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"): return .number(try number())
            default: throw MeadowJSONError.syntax(offset: at)
            }
        }

        mutating func word(_ text: StaticString) throws {
            let length = text.utf8CodeUnitCount
            guard at + length <= bytes.count else { throw MeadowJSONError.truncated }
            for i in 0..<length where bytes[at + i] != text.utf8Start[i] { throw MeadowJSONError.syntax(offset: at + i) }
            at += length
        }

        mutating func enter() throws {
            depth += 1
            if depth > limits.depth { throw MeadowJSONError.tooDeep }
        }

        mutating func object() throws -> MeadowJSON {
            try enter()
            at += 1
            var fields: [String: MeadowJSON] = [:]
            if try next() == UInt8(ascii: "}") {
                at += 1
                depth -= 1
                return .object(fields)
            }
            while true {
                guard try next() == UInt8(ascii: "\"") else { throw MeadowJSONError.syntax(offset: at) }
                let keyAt = at
                let key = try string()
                guard try next() == UInt8(ascii: ":") else { throw MeadowJSONError.syntax(offset: at) }
                at += 1
                let value = try self.value()
                guard fields.updateValue(value, forKey: key) == nil else { throw MeadowJSONError.duplicateKey(offset: keyAt) }
                switch try next() {
                case UInt8(ascii: ","): at += 1
                case UInt8(ascii: "}"):
                    at += 1
                    depth -= 1
                    return .object(fields)
                default: throw MeadowJSONError.syntax(offset: at)
                }
            }
        }

        mutating func array() throws -> MeadowJSON {
            try enter()
            at += 1
            var items: [MeadowJSON] = []
            if try next() == UInt8(ascii: "]") {
                at += 1
                depth -= 1
                return .array(items)
            }
            while true {
                items.append(try value())
                switch try next() {
                case UInt8(ascii: ","): at += 1
                case UInt8(ascii: "]"):
                    at += 1
                    depth -= 1
                    return .array(items)
                default: throw MeadowJSONError.syntax(offset: at)
                }
            }
        }

        /// A string starting at its opening quote. A string without escapes (nearly all of them) is
        /// taken from the bytes as it is; one with escapes is decoded into a buffer as long as the string
        /// (an escape never takes more bytes than it stands for). Either way the result is checked as
        /// UTF-8 by the standard library. Plain pointer arithmetic throughout: a 4 MiB string of escapes
        /// must read in well under 200 ms, even unoptimised.
        mutating func string() throws -> String {
            guard let base = bytes.baseAddress else { throw MeadowJSONError.truncated }
            let start = at, count = bytes.count
            var end = start + 1
            var escaped = false
            while true {
                guard end < count else { throw MeadowJSONError.truncated }
                let byte = base[end]
                if byte == 0x22 { break }
                if byte < 0x20 { throw MeadowJSONError.syntax(offset: end) }
                if byte == 0x5C {
                    escaped = true
                    end += 2
                } else {
                    end += 1
                }
            }
            at = end + 1
            guard escaped else {
                guard let text = String(validating: UnsafeBufferPointer(start: base + start + 1, count: end - start - 1), as: UTF8.self) else {
                    throw MeadowJSONError.invalidUTF8(offset: start)
                }
                return text
            }
            let out = UnsafeMutablePointer<UInt8>.allocate(capacity: end - start)
            defer { out.deallocate() }
            var n = 0, i = start + 1
            while i < end {
                let byte = base[i]
                if byte != 0x5C {
                    out[n] = byte
                    n += 1
                    i += 1
                    continue
                }
                let kind = base[i + 1]
                i += 2
                switch kind {
                case 0x22, 0x5C, 0x2F: out[n] = kind            // " \ /
                case 0x62: out[n] = 0x08                        // b
                case 0x66: out[n] = 0x0C                        // f
                case 0x6E: out[n] = 0x0A                        // n
                case 0x72: out[n] = 0x0D                        // r
                case 0x74: out[n] = 0x09                        // t
                case 0x75:                                      // u
                    var scalar = try Self.hex4(base, &i, end)
                    if scalar >= 0xD800 && scalar <= 0xDBFF {
                        // A high surrogate must be followed by an escaped low one.
                        guard i + 1 < end, base[i] == 0x5C, base[i + 1] == 0x75 else { throw MeadowJSONError.syntax(offset: i) }
                        i += 2
                        let low = try Self.hex4(base, &i, end)
                        guard low >= 0xDC00 && low <= 0xDFFF else { throw MeadowJSONError.syntax(offset: i - 4) }
                        scalar = 0x10000 + ((scalar - 0xD800) << 10) + (low - 0xDC00)
                    } else if scalar >= 0xDC00 && scalar <= 0xDFFF {
                        throw MeadowJSONError.syntax(offset: i - 4)
                    }
                    n += Self.utf8(scalar, out + n) - 1
                default:
                    throw MeadowJSONError.syntax(offset: i - 1)
                }
                n += 1
            }
            guard let text = String(validating: UnsafeBufferPointer(start: out, count: n), as: UTF8.self) else {
                throw MeadowJSONError.invalidUTF8(offset: start)
            }
            return text
        }

        /// Four hex digits at `i` (before `end`), moving `i` past them. Unrolled: no iterator.
        static func hex4(_ base: UnsafePointer<UInt8>, _ i: inout Int, _ end: Int) throws -> UInt32 {
            var value: UInt32 = 0
            let stop = i + 4
            while i < stop {
                guard i < end else { throw MeadowJSONError.syntax(offset: i) }
                let digit = hexDigit(base[i])
                guard digit < 16 else { throw MeadowJSONError.syntax(offset: i) }
                value = value << 4 | digit
                i += 1
            }
            return value
        }

        /// A hex digit's value, or 16 for a byte that is not one.
        static func hexDigit(_ byte: UInt8) -> UInt32 {
            if byte >= 0x30 && byte <= 0x39 { return UInt32(byte &- 0x30) }
            if byte >= 0x61 && byte <= 0x66 { return UInt32(byte &- 0x57) }
            if byte >= 0x41 && byte <= 0x46 { return UInt32(byte &- 0x37) }
            return 16
        }

        /// Writes a scalar's UTF-8 at `out`; returns how many bytes.
        static func utf8(_ scalar: UInt32, _ out: UnsafeMutablePointer<UInt8>) -> Int {
            if scalar < 0x80 {
                out[0] = UInt8(scalar)
                return 1
            } else if scalar < 0x800 {
                out[0] = UInt8(0xC0 | scalar >> 6)
                out[1] = UInt8(0x80 | scalar & 0x3F)
                return 2
            } else if scalar < 0x10000 {
                out[0] = UInt8(0xE0 | scalar >> 12)
                out[1] = UInt8(0x80 | scalar >> 6 & 0x3F)
                out[2] = UInt8(0x80 | scalar & 0x3F)
                return 3
            }
            out[0] = UInt8(0xF0 | scalar >> 18)
            out[1] = UInt8(0x80 | scalar >> 12 & 0x3F)
            out[2] = UInt8(0x80 | scalar >> 6 & 0x3F)
            out[3] = UInt8(0x80 | scalar & 0x3F)
            return 4
        }

        /// A number by JSON's grammar: `-? (0 | [1-9][0-9]*) (. [0-9]+)? ([eE] [+-]? [0-9]+)?`.
        mutating func number() throws -> String {
            let start = at
            func digits(_ parser: inout Parser) -> Int {
                let from = parser.at
                while parser.at < parser.bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(parser.bytes[parser.at]) { parser.at += 1 }
                return parser.at - from
            }
            if bytes[at] == UInt8(ascii: "-") { at += 1 }
            guard at < bytes.count else { throw MeadowJSONError.truncated }
            if bytes[at] == UInt8(ascii: "0") {
                at += 1
            } else if digits(&self) == 0 {
                throw MeadowJSONError.syntax(offset: at)
            }
            if at < bytes.count, bytes[at] == UInt8(ascii: ".") {
                at += 1
                if digits(&self) == 0 { throw at < bytes.count ? MeadowJSONError.syntax(offset: at) : MeadowJSONError.truncated }
            }
            if at < bytes.count, bytes[at] == UInt8(ascii: "e") || bytes[at] == UInt8(ascii: "E") {
                at += 1
                if at < bytes.count, bytes[at] == UInt8(ascii: "+") || bytes[at] == UInt8(ascii: "-") { at += 1 }
                if digits(&self) == 0 { throw at < bytes.count ? MeadowJSONError.syntax(offset: at) : MeadowJSONError.truncated }
            }
            return String(decoding: UnsafeBufferPointer(rebasing: bytes[start..<at]), as: UTF8.self)
        }
    }
}

// MARK: - Writing

extension MeadowJSON {
    /// The value as a meadow file writes it: keys sorted by their UTF-8 bytes, two-space indent, no
    /// trailing white space, a newline at the end. The outermost object and the objects directly in it
    /// have one key per line; an array directly in the outermost object that holds objects has one
    /// element per line; everything deeper is written on one line (`{ "a": 1, "b": [1, 2] }`). So a
    /// meadow's file reads one thing per line, and the same value is always the same bytes.
    public var fileText: String {
        var out = ""
        write(&out, depth: 0)
        out += "\n"
        return out
    }

    /// The value on one line, as it appears inside a meadow file. Its UTF-8 length is what limits a
    /// thing from a newer Whiskr (`MeadowFormat.maxUnknownItemBytes`).
    public var inlineText: String {
        var out = ""
        writeInline(&out)
        return out
    }

    private static func sortedKeys(_ fields: [String: MeadowJSON]) -> [String] {
        fields.keys.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
    }

    private var holdsObject: Bool {
        switch self {
        case .object: true
        case .array(let items): items.contains { $0.holdsObject }
        default: false
        }
    }

    private func write(_ out: inout String, depth: Int) {
        let indent = String(repeating: "  ", count: depth)
        switch self {
        case .object(let fields) where depth <= 1 && !fields.isEmpty:
            out += "{\n"
            let keys = Self.sortedKeys(fields)
            for (i, key) in keys.enumerated() {
                out += indent + "  "
                Self.writeString(key, &out)
                out += ": "
                fields[key]!.write(&out, depth: depth + 1)
                out += i == keys.count - 1 ? "\n" : ",\n"
            }
            out += indent + "}"
        case .array(let items) where depth == 1 && holdsObject:
            out += "[\n"
            for (i, item) in items.enumerated() {
                out += indent + "  "
                item.writeInline(&out)
                out += i == items.count - 1 ? "\n" : ",\n"
            }
            out += indent + "]"
        default:
            writeInline(&out)
        }
    }

    private func writeInline(_ out: inout String) {
        switch self {
        case .null: out += "null"
        case .bool(let value): out += value ? "true" : "false"
        case .number(let text): out += text
        case .string(let text): Self.writeString(text, &out)
        case .array(let items):
            if items.isEmpty { out += "[]"; return }
            out += "["
            for (i, item) in items.enumerated() {
                if i > 0 { out += ", " }
                item.writeInline(&out)
            }
            out += "]"
        case .object(let fields):
            if fields.isEmpty { out += "{}"; return }
            out += "{ "
            for (i, key) in Self.sortedKeys(fields).enumerated() {
                if i > 0 { out += ", " }
                Self.writeString(key, &out)
                out += ": "
                fields[key]!.writeInline(&out)
            }
            out += " }"
        }
    }

    /// A string with only what JSON requires escaped (plus the line and paragraph separators, which
    /// some JavaScript readers choke on); everything else as UTF-8.
    private static func writeString(_ text: String, _ out: inout String) {
        out += "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case "\u{2028}": out += "\\u2028"
            case "\u{2029}": out += "\\u2029"
            default:
                if scalar.value < 0x20 {
                    out += "\\u00" + (scalar.value < 0x10 ? "0" : "") + String(scalar.value, radix: 16)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
    }

    /// A number as a meadow file writes its own: rounded to 4 decimals (0.1 mm at 13 cm a unit), no
    /// exponent, no trailing zeros, no "-0". `MeadowJSON.quantized` gives the value this text reads back as.
    public static func literal(_ value: Double) -> String {
        let n = ticks(value)
        if n == 0 { return "0" }
        let whole = abs(n) / 10_000, fraction = abs(n) % 10_000
        var text = (n < 0 ? "-" : "") + String(whole)
        if fraction != 0 {
            var digits = String(fraction)
            digits = String(repeating: "0", count: 4 - digits.count) + digits
            while digits.hasSuffix("0") { digits.removeLast() }
            text += "." + digits
        }
        return text
    }

    /// `value` rounded to 4 decimals: exactly the number its `literal` reads back as, so a value that
    /// has been through a file once never changes again.
    public static func quantized(_ value: Double) -> Double {
        Double(ticks(value)) / 10_000
    }

    private static func ticks(_ value: Double) -> Int64 {
        precondition(value.isFinite && abs(value) < 1e14, "a meadow number must be finite and in range")
        return Int64((value * 10_000).rounded())
    }
}
