import Foundation

/// A program's output with every escape sequence and control character but line breaks and tabs taken
/// out, kept as a rolling tail, so a wait can look for text a program printed.
///
/// Cursor moves stand in for what they separate: a move along the line as spaces, a move to another
/// line as a line break, so words a program placed apart never run together.
public struct OutputText: Sendable {
    public let capacity: Int
    private var stream = TerminalStream()
    private var collector = Collector()
    private var kept = ""
    private var count = 0

    public init(capacity: Int = 64 * 1024) {
        self.capacity = max(capacity, 1)
    }

    /// Bytes may be split anywhere, inside a character or an escape sequence.
    public mutating func append(_ data: Data) {
        collector.text = ""
        collector.afterBreak = kept.last == "\n"
        stream.feed(data, into: &collector)
        guard !collector.text.isEmpty else { return }
        kept += collector.text
        count += collector.text.count
        // Trimmed now and then rather than on every call.
        if count > capacity + capacity / 4 {
            kept = String(kept.suffix(capacity))
            count = capacity
        }
    }

    /// The tail kept, at most `capacity` characters.
    public var text: String { count > capacity ? String(kept.suffix(capacity)) : kept }

    public func contains(_ needle: String) -> Bool {
        needle.isEmpty || text.contains(needle)
    }

    private struct Collector: TerminalPerformer {
        var text = ""
        /// What was kept before this piece ends with a line break.
        var afterBreak = false

        mutating func printScalar(_ scalar: Unicode.Scalar) {
            text.unicodeScalars.append(scalar)
        }

        mutating func control(_ byte: UInt8) {
            switch byte {
            case 0x0A, 0x0B, 0x0C: text.append("\n")
            case 0x09: text.append("\t")
            default: break
            }
        }

        mutating func controlSequence(_ sequence: ControlSequence) {
            guard sequence.marker == 0, sequence.intermediates.isEmpty else { return }
            switch sequence.final {
            case UInt8(ascii: "C"), UInt8(ascii: "a"):
                text.append(String(repeating: " ", count: min(sequence.count(0), 256)))
            case UInt8(ascii: "A"), UInt8(ascii: "B"), UInt8(ascii: "E"), UInt8(ascii: "F"), UInt8(ascii: "H"),
                 UInt8(ascii: "f"), UInt8(ascii: "d"), UInt8(ascii: "e"):
                lineBreak()
            default:
                break
            }
        }

        mutating func escape(intermediates: [UInt8], final: UInt8) {
            if intermediates.isEmpty, final == UInt8(ascii: "D") || final == UInt8(ascii: "E") || final == UInt8(ascii: "M") { lineBreak() }
        }

        /// One line break for a move to another line, however many moves in a row ask for one.
        private mutating func lineBreak() {
            if text.isEmpty ? !afterBreak : text.last != "\n" { text.append("\n") }
        }
    }
}
