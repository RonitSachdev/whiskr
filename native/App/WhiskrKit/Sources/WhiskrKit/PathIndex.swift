import Foundation

/// The files of a workspace, for Go to (⌘P) to find by a few letters of their name, as Xcode's Open
/// Quickly and VS Code's Quick Open do. Built once off the main thread from `git ls-files` (or a walk of
/// the folder); searched as you type, on a background task.
///
/// A file's name matters most, and its name without the extension more: "wbs" finds
/// `Workbench+Scene.swift` before `Workbench.swift` and `web/bootstrap.css`. The letters are looked for in
/// the name first, the whole path only when the name cannot hold them; a query with a "/" is matched
/// along the path, and so is one of several words the name cannot hold ("main java" finds
/// `src/main/java/App.java`). A quick greedy score ranks every candidate, and only the best few hundred get the
/// careful `FuzzyMatch`, so 100,000 paths cost a few tens of milliseconds.
public struct PathIndex: Sendable {
    public struct Match: Sendable, Equatable {
        /// Relative to the indexed folder, '/' separated.
        public let path: String
        /// Matched characters of the file's name (offsets in it), to draw bold; empty for a path match.
        public let nameOffsets: [Int]
        public let score: Int
    }

    /// Every path's lowercased bytes end to end, with which of them start a word, so the scan over all of
    /// them runs through one buffer (fast even in a debug build).
    private let bytes: [UInt8]
    private let starts: [Bool]
    private let records: [Record]
    /// Where each path lies in `bytes`, apart from its strings: the scan over every path reads only these.
    private let spans: [Span]

    private struct Span: Sendable {
        let from: Int, nameFrom: Int, stemTo: Int, to: Int
    }

    private struct Record: Sendable {
        let path: String
        let name: String
        /// Where the path, its name and its name's extension are in `bytes`.
        let from: Int, nameFrom: Int, stemTo: Int, to: Int
    }

    public init(paths: [String]) {
        var bytes: [UInt8] = [], starts: [Bool] = [], records: [Record] = [], spans: [Span] = []
        records.reserveCapacity(paths.count)
        spans.reserveCapacity(paths.count)
        for path in paths {
            let original = Array(path.utf8)
            let folded = original.map { (0x41...0x5A).contains($0) ? $0 + 32 : $0 }
            let from = bytes.count
            bytes += folded
            starts += Self.wordStarts(original)
            let slash = folded.lastIndex(of: UInt8(ascii: "/")).map { $0 + 1 } ?? 0
            let dot = folded[slash...].lastIndex(of: UInt8(ascii: ".")).flatMap { $0 > slash ? $0 : nil } ?? folded.count
            let name = String(decoding: original[slash...], as: UTF8.self)
            records.append(Record(path: path, name: name, from: from, nameFrom: from + slash, stemTo: from + dot, to: bytes.count))
            spans.append(Span(from: from, nameFrom: from + slash, stemTo: from + dot, to: bytes.count))
        }
        self.bytes = bytes
        self.starts = starts
        self.records = records
        self.spans = spans
    }

    public var count: Int { records.count }
    public var paths: [String] { records.map(\.path) }

    /// The best `limit` matches for `query`, best first. Every word of the query must match, in any order
    /// (`FuzzyMatch.Query`): in the name, or along the path when the name cannot hold them all.
    public func search(_ query: String, limit: Int = 50) -> [Match] {
        let query = FuzzyMatch.Query(query)
        guard !query.isEmpty else { return [] }
        // Every word's bytes end to end, capitals lowered as in `bytes`, and where each word lies in them.
        var needle: [UInt8] = [], words: [Word] = []
        for word in query.words {
            let from = needle.count
            needle += word.text.utf8.map { (0x41...0x5A).contains($0) ? $0 + 32 : $0 }
            words.append(Word(from: from, to: needle.count, isContiguous: word.isContiguous))
        }
        let wantsPath = query.mentionsFolder
        struct Candidate { let record: Int; let tier: Int; let quick: Int }
        var candidates: [Candidate] = []
        bytes.withUnsafeBufferPointer { bytes in
            starts.withUnsafeBufferPointer { starts in
                needle.withUnsafeBufferPointer { needle in
                    words.withUnsafeBufferPointer { words in
                        spans.withUnsafeBufferPointer { spans in
                            let text = Needle(bytes: needle, words: words)
                            // Plain loops here and below: a range's iterator is generic, and slow in a debug build.
                            var index = -1
                            while index + 1 < spans.count {
                                index += 1
                                let record = spans[index]
                                let length = record.to - record.from
                                // The name holding every word (its stem even more so), else the whole path.
                                if !wantsPath, let quick = Self.quickScore(bytes, starts, record.nameFrom, record.to, text) {
                                    let tier = Self.contains(bytes, record.nameFrom, record.stemTo, text) ? 2 : 1
                                    candidates.append(Candidate(record: index, tier: tier, quick: quick - length / 8))
                                } else if let quick = Self.quickScore(bytes, starts, record.from, record.to, text) {
                                    candidates.append(Candidate(record: index, tier: 0, quick: quick))
                                }
                            }
                        }
                    }
                }
            }
        }
        // Only the best few hundred go on to the careful match: they are picked by counting how many
        // candidates have each (tier, quick) rank, so the many that match loosely are never sorted.
        let kept = max(limit * 6, 300)
        if candidates.count > kept {
            var lowest = Int.max, highest = Int.min
            for candidate in candidates {
                lowest = min(lowest, candidate.quick)
                highest = max(highest, candidate.quick)
            }
            // A rank is the tier's band, then the quick score within it (both small numbers).
            let band = highest - lowest + 1
            let rank = { (candidate: Candidate) in candidate.tier * band + candidate.quick - lowest }
            var counts = [Int](repeating: 0, count: 3 * band)
            for candidate in candidates { counts[rank(candidate)] += 1 }
            var cutoff = counts.count - 1, above = 0
            while cutoff > 0 {
                above += counts[cutoff]
                if above >= kept { break }
                cutoff -= 1
            }
            candidates = candidates.filter { rank($0) >= cutoff }
        }
        candidates.sort { $0.tier != $1.tier ? $0.tier > $1.tier : $0.quick > $1.quick }
        // A one-word query that is the whole name, or the name without its extension.
        let only = query.words.count == 1 ? query.words[0].text.lowercased() : nil
        var found: [Match] = []
        for candidate in candidates.prefix(kept) {
            let record = records[candidate.record]
            let length = record.to - record.from
            if candidate.tier > 0, let match = FuzzyMatch.match(query, in: record.name) {
                let name = record.name.lowercased()
                let exact = only.map { name == $0 || name.hasPrefix($0 + ".") } ?? false
                found.append(Match(path: record.path, nameOffsets: match.offsets,
                                   score: candidate.tier * 100_000 + match.score + (exact ? 50_000 : 0) - length))
            } else if let match = FuzzyMatch.match(query, in: record.path) {
                found.append(Match(path: record.path, nameOffsets: [], score: match.score - length))
            }
        }
        found.sort { $0.score != $1.score ? $0.score > $1.score : $0.path < $1.path }
        return Array(found.prefix(limit))
    }

    /// One word of the query: where its bytes are in the needle, and whether they must sit side by side.
    private struct Word {
        let from: Int, to: Int
        let isContiguous: Bool
    }

    /// The query's words as the scan reads them.
    private struct Needle {
        let bytes: UnsafeBufferPointer<UInt8>
        let words: UnsafeBufferPointer<Word>
    }

    /// Whether every word of `needle` is in `bytes[from..<to]`: its bytes in order, or side by side for a
    /// word in quotes.
    private static func contains(_ bytes: UnsafeBufferPointer<UInt8>, _ from: Int, _ to: Int, _ needle: Needle) -> Bool {
        var index = 0
        while index < needle.words.count {
            let word = needle.words[index]
            index += 1
            if word.isContiguous {
                guard run(word, of: needle, in: bytes, from: from, to: to) else { return false }
                continue
            }
            var position = from, wanted = word.from
            while wanted < word.to {
                guard let found = next(needle.bytes[wanted], in: bytes, from: position, to: to) else { return false }
                position = found + 1
                wanted += 1
            }
        }
        return true
    }

    /// A cheap first ranking: each word's letters matched greedily, each worth more at a word's start or
    /// right after the previous one, the words' scores added; nil when some word is not in
    /// `bytes[from..<to]` (in order, or side by side for a word in quotes).
    private static func quickScore(_ bytes: UnsafeBufferPointer<UInt8>, _ starts: UnsafeBufferPointer<Bool>, _ from: Int, _ to: Int, _ needle: Needle) -> Int? {
        var score = 0, index = 0
        while index < needle.words.count {
            let word = needle.words[index]
            index += 1
            if word.isContiguous, !run(word, of: needle, in: bytes, from: from, to: to) { return nil }
            var previous = -2, position = from, wanted = word.from
            while wanted < word.to {
                guard let found = next(needle.bytes[wanted], in: bytes, from: position, to: to) else { return nil }
                score += 1 + (starts[found] ? 4 : 0) + (found == previous + 1 ? 3 : 0) + (found == from ? 3 : 0)
                previous = found
                position = found + 1
                wanted += 1
            }
        }
        return score
    }

    /// Whether `word`'s bytes appear side by side in `bytes[from..<to]`.
    private static func run(_ word: Word, of needle: Needle, in bytes: UnsafeBufferPointer<UInt8>, from: Int, to: Int) -> Bool {
        guard from < to, let base = bytes.baseAddress, let letters = needle.bytes.baseAddress else { return false }
        return memmem(base + from, to - from, letters + word.from, word.to - word.from) != nil
    }

    /// Where `byte` is next in `bytes[from..<to]`. `memchr` steps through a hundred thousand paths per
    /// keystroke far faster than a loop of Swift's own (above all in a debug build).
    @inline(__always)
    private static func next(_ byte: UInt8, in bytes: UnsafeBufferPointer<UInt8>, from: Int, to: Int) -> Int? {
        guard from < to, let base = bytes.baseAddress, let hit = memchr(base + from, Int32(byte), to - from) else { return nil }
        return base.distance(to: hit.assumingMemoryBound(to: UInt8.self))
    }

    static func wordStarts(_ bytes: [UInt8]) -> [Bool] {
        func isAlphanumeric(_ byte: UInt8) -> Bool { (0x30...0x39).contains(byte) || (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte) || byte >= 0x80 }
        return bytes.indices.map { index in
            guard index > 0 else { return true }
            let before = bytes[index - 1], here = bytes[index]
            if !isAlphanumeric(before) { return isAlphanumeric(here) }
            return (0x41...0x5A).contains(here) && (0x61...0x7A).contains(before)
        }
    }
}

/// Folders a walk never goes into: tool output and dependency trees that would bury the user's own files.
public enum PathWalk {
    public static let skippedFolders: Set<String> = [
        ".git", "node_modules", ".build", "build", "DerivedData", "Pods", "target", "dist", ".next", ".nuxt",
        "__pycache__", ".venv", "venv", ".tox", ".gradle", ".idea", ".swiftpm", "Carthage", ".cache", "Library",
    ]
}
