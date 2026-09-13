import Foundation

/// The latest output of a terminal, kept by the host so a window that attaches later can draw the
/// screen and scrollback as they were: the bytes are fed to its terminal again, in order.
///
/// Bounded: past `capacity` the oldest output goes. What is left then begins somewhere in the
/// history, so `replay` starts it after a line break (never inside an escape sequence or a
/// character), and the host puts the terminal's modes back first (`TerminalModes`).
///
/// It also notes each size the terminal was given (`resized`), as a mark between the bytes (an OSC
/// sequence of the host's own, `ReplaySize`), so a viewer can lay each stretch of output out at the size
/// it was printed for: a shell's prompt printed before its window had its real size, or a screen drawn
/// before the window was made wider, comes back where it was. Terminals that do not know the mark pass
/// over it, as they do any unknown OSC.
public struct ReplayBuffer: Sendable {
    public let capacity: Int
    private var chunks: [Data] = []
    /// Which chunks are size marks (they count toward nothing and are never cut from).
    private var marks: Set<Int> = []
    /// The size in force at the oldest output kept.
    private var sizeAtStart: TerminalSize?
    private var lastSize: TerminalSize?
    /// Chunks before this index have been dropped (the array is trimmed now and then, not per chunk).
    private var first = 0
    public private(set) var count = 0
    /// Output older than what is kept has been dropped.
    public private(set) var truncated = false

    /// 4 MiB: tens of thousands of lines of ordinary output, hours of a Claude session's redraws.
    public static let defaultCapacity = 4 * 1024 * 1024

    public init(capacity: Int = ReplayBuffer.defaultCapacity) {
        self.capacity = max(capacity, 1)
    }

    public mutating func append(_ bytes: Data) {
        guard !bytes.isEmpty else { return }
        chunks.append(bytes)
        count += bytes.count
        // Whole chunks go, never part of one: the newest is always kept, so the buffer may hold a
        // little more than its capacity.
        while count > capacity, first < chunks.count - 1 {
            if marks.remove(first) != nil {
                sizeAtStart = ReplaySize.size(in: chunks[first])
            } else {
                count -= chunks[first].count
                truncated = true
            }
            chunks[first] = Data()
            first += 1
        }
        if first > 64 {
            chunks.removeFirst(first)
            marks = Set(marks.map { $0 - first })
            first = 0
        }
    }

    /// The terminal was given this size: what follows was printed for it.
    public mutating func resized(to size: TerminalSize) {
        guard size != lastSize else { return }
        lastSize = size
        if chunks.count == first {
            // Nothing kept since the last mark: it simply stands for this size now.
            sizeAtStart = size
            return
        }
        marks.insert(chunks.count)
        chunks.append(ReplaySize.mark(size))
    }

    /// Everything kept, ready to feed to a terminal. When older output was dropped, it starts after
    /// the first line break that is left.
    public var replay: Data {
        var data = Data(capacity: count)
        for chunk in chunks[first...] { data.append(chunk) }
        if truncated {
            guard let lineBreak = data.firstIndex(of: 0x0A) else { return sizeAtStart.map(ReplaySize.mark) ?? Data() }
            data = data.subdata(in: lineBreak + 1..<data.endIndex)
        }
        // The size the oldest output kept was printed for, first.
        guard let sizeAtStart else { return data }
        return ReplaySize.mark(sizeAtStart) + data
    }
}

/// The host's mark of a size in a terminal's kept output: `ESC ] 7600 ; size=<columns>x<rows> BEL`. It is
/// only ever in what is replayed, never in what a program prints live.
public enum ReplaySize {
    private static let prefix = Array("\u{1B}]7600;size=".utf8)

    public static func mark(_ size: TerminalSize) -> Data {
        Data(prefix + Array("\(size.columns)x\(size.rows)".utf8) + [0x07])
    }

    /// The size a mark names; nil for anything else.
    public static func size(in data: Data) -> TerminalSize? {
        let bytes = Array(data)
        guard bytes.starts(with: prefix), bytes.last == 0x07 else { return nil }
        let text = String(decoding: bytes[prefix.count..<bytes.count - 1], as: UTF8.self)
        let parts = text.split(separator: "x").compactMap { Int($0) }
        guard parts.count == 2, parts[0] > 0, parts[1] > 0 else { return nil }
        return TerminalSize(columns: parts[0], rows: parts[1])
    }

    /// Replayed output split at its marks: each stretch with the size to take before it is drawn (nil
    /// for none). A mark cut in two is not one; it passes as output (terminals skip it).
    public static func split(_ data: Data) -> [(size: TerminalSize?, bytes: Data)] {
        var pieces: [(size: TerminalSize?, bytes: Data)] = []
        var size: TerminalSize?
        var start = data.startIndex
        var index = data.startIndex
        while let found = data[index...].firstIndex(of: 0x1B) {
            guard data[found...].starts(with: prefix), let end = data[found...].firstIndex(of: 0x07),
                  let marked = Self.size(in: data.subdata(in: found..<end + 1)) else {
                index = found + 1
                continue
            }
            if found > start || size != nil { pieces.append((size, data.subdata(in: start..<found))) }
            size = marked
            start = end + 1
            index = start
        }
        if start < data.endIndex || size != nil { pieces.append((size, data.subdata(in: start..<data.endIndex))) }
        return pieces
    }
}
