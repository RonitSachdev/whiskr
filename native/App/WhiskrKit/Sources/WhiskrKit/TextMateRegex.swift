import COniguruma
import Foundation

// The regular expressions of TextMate grammars, run by Oniguruma (the engine they are written for, and the
// one VS Code runs as WebAssembly). Expressions and lines are given to it as UTF-8, as VS Code does: an
// expression means the same here as there (`\xHH` is a byte in Oniguruma, so the encoding is part of an
// expression's meaning). Offsets come back as UTF-16 units, which NSString and NSRange count; a line of
// ASCII (nearly every line of code) needs no conversion of either.
//
// `RegexScanner` finds the earliest match of a list of expressions, with the per-expression cache of
// vscode-oniguruma's OnigScanner (MIT, Copyright (c) Microsoft Corporation): a search that found nothing
// from a position, or found a match at or after the position asked for now, is still the answer.

/// A line as the expressions search it: its UTF-16 units (with the "\n" a grammar expects at the end, so
/// never empty), the same as UTF-8, and an identity that tells a scanner's cache which line its answers
/// are for.
final class RegexLine {
    let units: [UInt16]
    let id: Int
    /// How much of `units` (and of `bytes`) is the line: a capture tokenized again is searched in the
    /// line up to the capture's end, sharing the line's storage.
    let count: Int
    let byteCount: Int
    /// The line as UTF-8; for an ASCII line, byte offsets are unit offsets.
    let bytes: [UInt8]
    /// For a line beyond ASCII: each unit's byte offset, and each byte's unit offset (one past the end
    /// included in both).
    private let byteOffsets: [Int32]?
    private let unitOffsets: [Int32]?

    init(units: [UInt16], id: Int) {
        self.units = units
        self.id = id
        count = units.count
        if units.allSatisfy({ $0 < 0x80 }) {
            bytes = units.map { UInt8(truncatingIfNeeded: $0) }
            byteCount = bytes.count
            byteOffsets = nil
            unitOffsets = nil
            return
        }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(units.count * 2)
        var byteOffsets = [Int32](repeating: 0, count: units.count + 1)
        var unitOffsets: [Int32] = []
        unitOffsets.reserveCapacity(units.count * 2)
        var index = 0
        func append(_ scalar: UInt32, units count: Int) {
            for offset in 0..<count { byteOffsets[index + offset] = Int32(bytes.count) }
            let before = bytes.count
            switch scalar {
            case ..<0x80: bytes.append(UInt8(scalar))
            case ..<0x800: bytes += [UInt8(0xC0 | (scalar >> 6)), UInt8(0x80 | (scalar & 0x3F))]
            case ..<0x10000: bytes += [UInt8(0xE0 | (scalar >> 12)), UInt8(0x80 | ((scalar >> 6) & 0x3F)), UInt8(0x80 | (scalar & 0x3F))]
            default: bytes += [UInt8(0xF0 | (scalar >> 18)), UInt8(0x80 | ((scalar >> 12) & 0x3F)), UInt8(0x80 | ((scalar >> 6) & 0x3F)), UInt8(0x80 | (scalar & 0x3F))]
            }
            for _ in before..<bytes.count { unitOffsets.append(Int32(index)) }
            index += count
        }
        while index < units.count {
            let unit = units[index]
            if UTF16.isLeadSurrogate(unit), index + 1 < units.count, UTF16.isTrailSurrogate(units[index + 1]) {
                append(0x10000 + ((UInt32(unit) - 0xD800) << 10) + (UInt32(units[index + 1]) - 0xDC00), units: 2)
            } else if UTF16.isLeadSurrogate(unit) || UTF16.isTrailSurrogate(unit) {
                // A lone surrogate is not text: searched as U+FFFD.
                append(0xFFFD, units: 1)
            } else {
                append(UInt32(unit), units: 1)
            }
        }
        byteOffsets[units.count] = Int32(bytes.count)
        unitOffsets.append(Int32(units.count))
        byteCount = bytes.count
        self.bytes = bytes
        self.byteOffsets = byteOffsets
        self.unitOffsets = unitOffsets
    }

    /// The first `length` units of `line`.
    init(prefixOf line: RegexLine, length: Int, id: Int) {
        units = line.units
        bytes = line.bytes
        byteOffsets = line.byteOffsets
        unitOffsets = line.unitOffsets
        self.id = id
        count = length
        byteCount = line.byteOffset(length)
    }

    func byteOffset(_ unit: Int) -> Int { byteOffsets.map { Int($0[unit]) } ?? unit }
    func unitOffset(_ byte: Int) -> Int { unitOffsets.map { Int($0[byte]) } ?? byte }

    /// Units `start..<end` as text (a capture's text, for a name with "$1" or an end with "\1").
    func text(_ start: Int, _ end: Int) -> String {
        guard start >= 0, end > start, end <= count else { return "" }
        return String(decoding: units[start..<end], as: UTF16.self)
    }
}

/// A capture's range in UTF-16 units; both are -1 for a group that took no part in the match.
struct CaptureRange: Equatable {
    var start: Int
    var end: Int
    var length: Int { end - start }
}

struct RegexMatch {
    /// Which expression of the scanner's list matched.
    var index: Int
    /// The whole match, then each group.
    var captures: [CaptureRange]
}

/// Finds which of a list of expressions matches first in a line (the earliest start; the first in the
/// list among equals), as TextMate does at every step. Used by one thread at a time. An expression that
/// fails to compile never matches (a grammar with one broken expression still colours everything else).
///
/// As vscode-oniguruma does: a line under 1,000 bytes is searched for all the expressions at once
/// (Oniguruma's RegSet, trying each position for every expression before the next position); a longer
/// one expression by expression, each answer kept for the next search of the same line.
final class RegexScanner {
    /// Each expression's compiled form, nil for one that did not compile.
    private let regexes: [OnigRegex?]
    /// Expressions that anchor at the search's start (`\G`): their answer depends on where a search
    /// starts, so it is never kept.
    private let anchorsAtStart: [Bool]
    /// The compiled expressions as one set, and which expression each member is.
    private let set: OpaquePointer?
    private let members: [Int]
    private let region: UnsafeMutablePointer<OnigRegion>
    private let parameters: OpaquePointer?
    private var setParameters: [OpaquePointer?]
    /// Per expression: the line and position of its last search, and what it found.
    private var cache: [(line: Int, position: Int, result: [CaptureRange]?)]

    init(sources: [String]) {
        Oniguruma.setUp()
        let regexes = sources.map(Self.compile)
        let members = regexes.indices.filter { regexes[$0] != nil }
        self.regexes = regexes
        self.members = members
        anchorsAtStart = sources.map { $0.contains("\\G") }
        var compiled: [OnigRegex?] = members.map { regexes[$0] }
        var made: OpaquePointer?
        if !compiled.isEmpty, compiled.withUnsafeMutableBufferPointer({ onig_regset_new(&made, Int32($0.count), $0.baseAddress) }) == ONIG_NORMAL {
            set = made
        } else {
            set = nil
        }
        region = onig_region_new()
        parameters = Oniguruma.makeParameters()
        setParameters = members.map { _ in Oniguruma.makeParameters() }
        cache = Array(repeating: (-1, -1, nil), count: sources.count)
    }

    deinit {
        // The set owns its members; without one, each is freed on its own.
        if let set { onig_regset_free(set) } else { regexes.forEach { if let regex = $0 { onig_free(regex) } } }
        onig_region_free(region, 1)
        if let parameters { onig_free_match_param(parameters) }
        setParameters.forEach { if let parameters = $0 { onig_free_match_param(parameters) } }
    }

    private static func compile(_ source: String) -> OnigRegex? {
        // A NUL past the end keeps the buffer non-empty for an empty expression; it is not part of it.
        let bytes = Array(source.utf8) + [0]
        var compiled: OnigRegex?
        var info = OnigErrorInfo()
        let status = bytes.withUnsafeBufferPointer { buffer -> Int32 in
            let start = buffer.baseAddress!
            return onig_new(&compiled, start, start + (bytes.count - 1), whiskr_onig_capture_group(), whiskr_onig_utf8(), whiskr_onig_syntax(), &info)
        }
        return status == ONIG_NORMAL ? compiled : nil
    }

    func findNextMatch(_ line: RegexLine, from position: Int) -> RegexMatch? {
        guard position <= line.count else { return nil }
        if line.byteCount < 1000, let set {
            var location: Int32 = 0
            let index = line.bytes.withUnsafeBufferPointer { buffer -> Int32 in
                let base = buffer.baseAddress!, end = base + line.byteCount
                return setParameters.withUnsafeMutableBufferPointer { parameters in
                    onig_regset_search_with_param(set, base, end, base + line.byteOffset(position), end, ONIG_REGSET_POSITION_LEAD, ONIG_OPTION_NONE,
                                                  parameters.baseAddress, &location)
                }
            }
            guard index >= 0, let found = onig_regset_get_region(set, index) else { return nil }
            return RegexMatch(index: members[Int(index)], captures: captures(found, line))
        }
        var best: RegexMatch?
        var bestStart = Int.max
        for index in regexes.indices {
            guard let captures = search(index, line, position) else { continue }
            let start = captures[0].start
            if start < bestStart {
                bestStart = start
                best = RegexMatch(index: index, captures: captures)
                // Nothing can start earlier.
                if start == position { break }
            }
        }
        return best
    }

    private func search(_ index: Int, _ line: RegexLine, _ position: Int) -> [CaptureRange]? {
        guard let regex = regexes[index] else { return nil }
        let keeps = !anchorsAtStart[index]
        if keeps {
            let cached = cache[index]
            if cached.line == line.id, cached.position <= position {
                guard let result = cached.result else { return nil }
                if result[0].start >= position { return result }
            }
        }
        let found = line.bytes.withUnsafeBufferPointer { buffer -> Int32 in
            let base = buffer.baseAddress!, end = base + line.byteCount
            return onig_search_with_param(regex, base, end, base + line.byteOffset(position), end, region, ONIG_OPTION_NONE, parameters)
        }
        let result = found >= 0 ? captures(region, line) : nil
        if keeps { cache[index] = (line.id, position, result) }
        return result
    }

    private func captures(_ region: UnsafeMutablePointer<OnigRegion>, _ line: RegexLine) -> [CaptureRange] {
        let count = Int(region.pointee.num_regs)
        var captures: [CaptureRange] = []
        captures.reserveCapacity(count)
        for group in 0..<count {
            let begin = Int(region.pointee.beg[group]), end = Int(region.pointee.end[group])
            captures.append(begin < 0 ? CaptureRange(start: -1, end: -1) : CaptureRange(start: line.unitOffset(begin), end: line.unitOffset(end)))
        }
        return captures
    }
}

/// Oniguruma's one-time setup, and the limit that keeps a pathological expression from holding a line.
enum Oniguruma {
    /// How much backtracking one search may do before it gives up (as "no match"). Far beyond what any
    /// grammar's expressions need on an ordinary line (the colorize fixtures and 50,000-line files never come
    /// near it); an expression with catastrophic backtracking on a long line stops in milliseconds instead
    /// of seconds.
    static let searchLimit: UInt = 2_000_000

    /// How deeply an expression's groups may nest. Oniguruma parses recursively, and expressions compile
    /// lazily on threads with 512 KB stacks (the background tokenizer's, tasks'): its default of 4,096
    /// levels overflows one at about 700. Grammars nest a few dozen at most; a deeper expression does not
    /// compile, and so never matches.
    static let parseDepthLimit: UInt32 = 200

    private static let ready: Bool = {
        onig_set_parse_depth_limit(parseDepthLimit)
        var encodings: [OnigEncoding?] = [whiskr_onig_utf8()]
        return encodings.withUnsafeMutableBufferPointer { onig_initialize(&$0.baseAddress!.pointee, 1) } == ONIG_NORMAL
    }()

    static func setUp() {
        _ = ready
    }

    static func makeParameters() -> OpaquePointer? {
        guard let parameters = onig_new_match_param() else { return nil }
        onig_initialize_match_param(parameters)
        onig_set_retry_limit_in_search_of_match_param(parameters, searchLimit)
        return parameters
    }
}
