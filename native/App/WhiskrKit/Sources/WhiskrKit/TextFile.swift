import Foundation

// A text file as the editor holds it: its text with line breaks made "\n", and what it takes to write it
// back exactly as it was found (the encoding, a byte order mark, the line breaks). Reading and writing
// an unchanged file gives back the same bytes.

/// How a file's characters are stored.
public enum TextEncoding: String, Sendable, Codable, CaseIterable {
    case utf8, utf8WithBOM, utf16LittleEndian, utf16BigEndian, latin1

    /// As the status bar and the Reopen With menu name it.
    public var displayName: String {
        switch self {
        case .utf8: "UTF-8"
        case .utf8WithBOM: "UTF-8 with BOM"
        case .utf16LittleEndian: "UTF-16 LE"
        case .utf16BigEndian: "UTF-16 BE"
        case .latin1: "Western (ISO Latin 1)"
        }
    }

    var byteOrderMark: [UInt8] {
        switch self {
        case .utf8WithBOM: [0xEF, 0xBB, 0xBF]
        case .utf16LittleEndian: [0xFF, 0xFE]
        case .utf16BigEndian: [0xFE, 0xFF]
        case .utf8, .latin1: []
        }
    }

    var foundation: String.Encoding {
        switch self {
        case .utf8, .utf8WithBOM: .utf8
        case .utf16LittleEndian: .utf16LittleEndian
        case .utf16BigEndian: .utf16BigEndian
        case .latin1: .isoLatin1
        }
    }
}

/// How a file breaks its lines.
public enum LineEnding: String, Sendable, Codable, CaseIterable {
    case lf, crlf, cr

    public var characters: String {
        switch self {
        case .lf: "\n"
        case .crlf: "\r\n"
        case .cr: "\r"
        }
    }

    /// "LF", "CRLF", "CR", as editors show them.
    public var displayName: String { rawValue.uppercased() }
}

public struct TextFile: Sendable, Equatable {
    /// The text, every line break a "\n".
    public var text: String
    public var encoding: TextEncoding
    public var lineEnding: LineEnding
    /// The file broke its lines in more than one way; it is written back with the most common.
    public var hadMixedLineEndings: Bool

    public init(text: String, encoding: TextEncoding = .utf8, lineEnding: LineEnding = .lf, hadMixedLineEndings: Bool = false) {
        self.text = text
        self.encoding = encoding
        self.lineEnding = lineEnding
        self.hadMixedLineEndings = hadMixedLineEndings
    }

    public enum Reading: Sendable, Equatable {
        case text(TextFile)
        /// Not text: a NUL byte near the start (git's own test) and no UTF-16 byte order mark.
        case binary
    }

    /// Reads a file's bytes: a byte order mark decides the encoding, else UTF-8 if the bytes are valid
    /// UTF-8, else Latin 1 (which reads any bytes and writes them back unchanged).
    public static func read(_ data: Data) -> Reading {
        let bytes = [UInt8](data)
        let marked: TextEncoding? = if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { .utf8WithBOM }
            else if bytes.starts(with: [0xFF, 0xFE]) { .utf16LittleEndian }
            else if bytes.starts(with: [0xFE, 0xFF]) { .utf16BigEndian }
            else { nil }
        if marked == nil, looksBinary(bytes) { return .binary }
        let encoding = marked ?? (String(validating: bytes, as: UTF8.self) != nil ? .utf8 : .latin1)
        let body = Data(bytes.dropFirst(encoding.byteOrderMark.count))
        guard let raw = String(data: body, encoding: encoding.foundation) else { return .binary }
        let (text, ending, mixed) = normalizingLineEndings(raw)
        return .text(TextFile(text: text, encoding: encoding, lineEnding: ending, hadMixedLineEndings: mixed))
    }

    /// `text` as this file stores it: its line breaks and encoding, with its byte order mark. A character
    /// the encoding cannot hold (typed into a Latin 1 file) is written as UTF-8 instead: nothing is lost.
    public func data(for text: String) -> Data {
        let broken = lineEnding == .lf ? text : text.replacingOccurrences(of: "\n", with: lineEnding.characters)
        if let body = broken.data(using: encoding.foundation, allowLossyConversion: false) {
            return Data(encoding.byteOrderMark) + body
        }
        return Data(broken.utf8)
    }

    /// The encoding to write with once `text` may hold characters this file's encoding cannot.
    public func encodingNeeded(for text: String) -> TextEncoding {
        text.data(using: encoding.foundation, allowLossyConversion: false) == nil ? .utf8 : encoding
    }

    /// git's heuristic: a NUL byte in the first 8,000 bytes.
    static func looksBinary(_ bytes: [UInt8]) -> Bool {
        bytes.prefix(8000).contains(0)
    }

    /// The text with every "\r\n" and lone "\r" made "\n", the most common line break, and whether there
    /// was more than one kind.
    static func normalizingLineEndings(_ text: String) -> (String, LineEnding, Bool) {
        guard text.utf8.contains(UInt8(ascii: "\r")) else { return (text, .lf, false) }
        var lf = 0, crlf = 0, cr = 0
        var scalars = String.UnicodeScalarView()
        var previousCR = false
        for scalar in text.unicodeScalars {
            if previousCR {
                previousCR = false
                if scalar == "\n" {
                    crlf += 1
                    continue
                }
                cr += 1
            }
            switch scalar {
            case "\r":
                previousCR = true
                scalars.append("\n")
            case "\n":
                lf += 1
                scalars.append(scalar)
            default:
                scalars.append(scalar)
            }
        }
        if previousCR { cr += 1 }
        guard crlf + cr > 0 else { return (text, .lf, false) }
        let kinds = [lf, crlf, cr].filter { $0 > 0 }.count
        let ending: LineEnding = crlf >= lf && crlf >= cr ? .crlf : lf >= cr ? .lf : .cr
        return (String(scalars), ending, kinds > 1)
    }
}

/// How a file indents: with tabs, or with a number of spaces.
public struct Indentation: Sendable, Equatable, Codable {
    public var usesTabs: Bool
    /// Spaces per level; for tabs, how wide a tab is drawn.
    public var width: Int

    public init(usesTabs: Bool, width: Int) {
        self.usesTabs = usesTabs
        self.width = max(1, min(width, 16))
    }

    /// One level of indentation.
    public var unit: String { usesTabs ? "\t" : String(repeating: " ", count: width) }

    /// What the file's own lines say, from its first 5,000: tabs if more lines start with a tab than
    /// with spaces, else the step between one line's indentation and the next's that occurs most (2, 4
    /// or 8, …). nil when the file says nothing (no indented lines).
    public static func detect(in text: String, tabWidth: Int = 4) -> Indentation? {
        var tabs = 0, spaces = 0
        var steps: [Int: Int] = [:]
        var previous = 0
        var lines = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            lines += 1
            if lines > 5000 { break }
            guard let first = line.first(where: { $0 != " " && $0 != "\t" }) else { continue }
            // A block comment's continuation (" * …") is not a step of the code's indentation.
            if first == "*" { continue }
            if line.first == "\t" {
                tabs += 1
                previous = 0
                continue
            }
            let indent = line.prefix { $0 == " " }.count
            if indent > 0 { spaces += 1 }
            let step = indent - previous
            if step > 1 { steps[step, default: 0] += 1 }
            previous = indent
        }
        if tabs == 0 && spaces == 0 { return nil }
        if tabs > spaces { return Indentation(usesTabs: true, width: tabWidth) }
        // The most common step; between equals, the smaller (a file of 2-space steps also has some 4s).
        guard let step = steps.max(by: { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key })?.key else {
            return Indentation(usesTabs: false, width: tabWidth)
        }
        return Indentation(usesTabs: false, width: step)
    }
}
