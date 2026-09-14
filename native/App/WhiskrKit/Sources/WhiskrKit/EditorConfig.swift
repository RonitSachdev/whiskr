import Foundation

/// `.editorconfig` files (editorconfig.org, specification 0.17): the indentation, line breaks, encoding and
/// save-time fixes a repository asks of every editor. For a file, every `.editorconfig` from its folder up
/// to the first that says `root = true` is read; the nearest file wins, and within a file the last matching
/// section.
public enum EditorConfig {
    /// One `.editorconfig` file: whether it is the root, and its sections in order.
    public struct File: Equatable, Sendable {
        public struct Section: Equatable, Sendable {
            public var glob: String
            /// Lower-cased names; values as written.
            public var properties: [(name: String, value: String)]

            public static func == (lhs: Section, rhs: Section) -> Bool {
                lhs.glob == rhs.glob && lhs.properties.map(\.name) == rhs.properties.map(\.name) && lhs.properties.map(\.value) == rhs.properties.map(\.value)
            }
        }

        public var isRoot = false
        public var sections: [Section] = []

        /// Reads the INI-like format: `[glob]` sections, `name = value` pairs, comments on lines of their own
        /// starting with `#` or `;`. Lines that are none of these are skipped, as the specification says.
        public init(parsing text: String) {
            for raw in text.split(omittingEmptySubsequences: true, whereSeparator: { $0 == "\n" || $0 == "\r" || $0 == "\r\n" }) {
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") { continue }
                if line.hasPrefix("["), line.hasSuffix("]"), line.count >= 2 {
                    let glob = String(line.dropFirst().dropLast())
                    if glob.utf8.count <= 4096 { sections.append(Section(glob: glob, properties: [])) }
                    continue
                }
                guard let equals = line.firstIndex(of: "=") else { continue }
                let name = line[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
                let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty, name.utf8.count <= 1024, value.utf8.count <= 4096 else { continue }
                if sections.isEmpty {
                    if name == "root" { isRoot = value.lowercased() == "true" }
                } else {
                    sections[sections.count - 1].properties.append((name, value))
                }
            }
        }

        /// The properties its sections give a file at `path` (relative to this file's folder, "/"-separated),
        /// over the ones given so far.
        func apply(to properties: inout [String: String], path: String) {
            for section in sections where EditorConfig.matches(section.glob, path: path) {
                for (name, value) in section.properties { properties[name] = value }
            }
        }
    }

    public enum IndentStyle: String, Sendable {
        case tab, space
    }

    /// What applies to one file. nil is "not said" (and `unset` says nothing).
    public struct Properties: Equatable, Sendable {
        public var indentStyle: IndentStyle?
        /// Columns per level of indentation (`indent_size = tab` is taken as the tab width).
        public var indentSize: Int?
        public var tabWidth: Int?
        public var endOfLine: LineEnding?
        public var charset: TextEncoding?
        public var trimTrailingWhitespace: Bool?
        public var insertFinalNewline: Bool?

        public init() {}

        /// From the matched names and values, with the specification's rules between the sizes: a tab style
        /// indents by a tab, `indent_size = tab` is the tab width, and the tab width follows the indent size.
        init(_ values: [String: String]) {
            let value = { (name: String) -> String? in
                guard let raw = values[name]?.lowercased(), raw != "unset" else { return nil }
                return raw
            }
            let number = { (name: String) -> Int? in value(name).flatMap(Int.init).flatMap { $0 > 0 ? $0 : nil } }
            indentStyle = value("indent_style").flatMap(IndentStyle.init(rawValue:))
            tabWidth = number("tab_width")
            let indentIsTab = value("indent_size") == "tab" || (value("indent_size") == nil && indentStyle == .tab)
            indentSize = indentIsTab ? tabWidth : number("indent_size")
            if tabWidth == nil, !indentIsTab { tabWidth = indentSize }
            endOfLine = value("end_of_line").flatMap(LineEnding.init(rawValue:))
            charset = switch value("charset") {
            case "latin1": .latin1
            case "utf-8": .utf8
            case "utf-8-bom": .utf8WithBOM
            case "utf-16be": .utf16BigEndian
            case "utf-16le": .utf16LittleEndian
            default: nil
            }
            trimTrailingWhitespace = value("trim_trailing_whitespace").flatMap(Bool.init)
            insertFinalNewline = value("insert_final_newline").flatMap(Bool.init)
        }

        /// The indentation to edit a file with: what these properties say, then what the file's own lines
        /// show (`detected`), then the editor's settings (`fallback`).
        public func indentation(detected: Indentation?, fallback: Indentation) -> Indentation {
            let usesTabs = indentStyle.map { $0 == .tab } ?? detected?.usesTabs ?? fallback.usesTabs
            let width: Int
            if usesTabs {
                width = tabWidth ?? indentSize ?? (detected?.usesTabs == true ? detected?.width : nil) ?? fallback.width
            } else {
                width = indentSize ?? (detected?.usesTabs == false ? detected?.width : nil) ?? fallback.width
            }
            return Indentation(usesTabs: usesTabs, width: width)
        }
    }

    /// The properties for the file at `path`: every `.editorconfig` from its folder up to the root one,
    /// read through `read` (the file's text, or nil when there is none).
    public static func properties(forFileAt path: String, read: (String) -> String? = EditorConfig.readFile) -> Properties {
        var files: [(folder: String, file: File)] = []
        var folder = (path as NSString).deletingLastPathComponent
        while true {
            if let text = read((folder as NSString).appendingPathComponent(".editorconfig")) {
                let file = File(parsing: text)
                files.append((folder, file))
                if file.isRoot { break }
            }
            let parent = (folder as NSString).deletingLastPathComponent
            if parent == folder || parent.isEmpty { break }
            folder = parent
        }
        var values: [String: String] = [:]
        for (folder, file) in files.reversed() {
            let base = folder.hasSuffix("/") ? folder : folder + "/"
            guard path.hasPrefix(base) else { continue }
            file.apply(to: &values, path: String(path.dropFirst(base.count)))
        }
        return Properties(values)
    }

    public static func readFile(_ path: String) -> String? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: Globs

    /// Whether a section's glob matches a path relative to its file's folder. A glob with a "/" is relative
    /// to that folder (a leading "/" only says so); one without matches a file's name at any depth.
    public static func matches(_ glob: String, path: String) -> Bool {
        var pattern = glob
        if pattern.hasPrefix("/") {
            pattern.removeFirst()
        } else if !pattern.contains("/") {
            pattern = "**/" + pattern
        }
        var ranges: [ClosedRange<Int>] = []
        let source = "^" + translate(Array(pattern), ranges: &ranges) + "$"
        guard let expression = try? NSRegularExpression(pattern: source),
              let match = expression.firstMatch(in: path, range: NSRange(path.startIndex..., in: path)) else { return false }
        // Each numeric range's capture is a number within it.
        for (index, range) in ranges.enumerated() {
            let captured = match.range(at: index + 1)
            guard captured.location != NSNotFound, let number = Int((path as NSString).substring(with: captured)), range.contains(number) else { return false }
        }
        return true
    }

    /// A glob as a regular expression: `*` any characters but "/", `**` any characters, `?` one but "/",
    /// `[seq]` and `[!seq]`, `{a,b}` (nested), `{1..5}` (a number in the range, checked after matching),
    /// and `\` escaping the next character. A `{` or `[` without its closing is itself.
    static func translate(_ glob: [Character], ranges: inout [ClosedRange<Int>]) -> String {
        var out = ""
        var index = 0
        while index < glob.count {
            let character = glob[index]
            switch character {
            case "\\":
                index += 1
                if index < glob.count { out += NSRegularExpression.escapedPattern(for: String(glob[index])) }
            case "*":
                if index + 1 < glob.count, glob[index + 1] == "*" {
                    // "**/" at the start of a segment also matches no folder at all.
                    let atSegment = index == 0 || glob[index - 1] == "/"
                    if atSegment, index + 2 < glob.count, glob[index + 2] == "/" {
                        out += "(?:.*/)?"
                        index += 2
                    } else {
                        out += ".*"
                        index += 1
                    }
                } else {
                    out += "[^/]*"
                }
            case "?":
                out += "[^/]"
            case "[":
                if let close = closing("]", in: glob, from: index + 1), !glob[(index + 1)..<close].contains("/") {
                    var body = Array(glob[(index + 1)..<close])
                    let negated = body.first == "!" || body.first == "^"
                    if negated { body.removeFirst() }
                    let escaped = body.map { "\\^[]".contains($0) ? "\\\($0)" : String($0) }.joined()
                    out += "[" + (negated ? "^" : "") + escaped + "]"
                    index = close
                } else {
                    out += "\\["
                }
            case "{":
                if let close = closing("}", in: glob, from: index + 1, opening: "{") {
                    let body = Array(glob[(index + 1)..<close])
                    let alternatives = split(body)
                    if let range = numericRange(String(body)) {
                        ranges.append(range)
                        out += "([+-]?[0-9]+)"
                    } else if alternatives.count > 1 {
                        out += "(?:" + alternatives.map { translate($0, ranges: &ranges) }.joined(separator: "|") + ")"
                    } else {
                        out += "\\{" + translate(body, ranges: &ranges) + "\\}"
                    }
                    index = close
                } else {
                    out += "\\{"
                }
            default:
                out += NSRegularExpression.escapedPattern(for: String(character))
            }
            index += 1
        }
        return out
    }

    /// The index of the `close` that ends what opens before `start` (nested `opening`s counted, `\` escapes).
    static func closing(_ close: Character, in glob: [Character], from start: Int, opening: Character? = nil) -> Int? {
        var depth = 0
        var index = start
        while index < glob.count {
            let character = glob[index]
            if character == "\\" {
                index += 2
                continue
            }
            if let opening, character == opening {
                depth += 1
            } else if character == close {
                if depth == 0 { return index }
                depth -= 1
            }
            index += 1
        }
        return nil
    }

    /// A brace's body split at its top-level commas.
    static func split(_ body: [Character]) -> [[Character]] {
        var parts: [[Character]] = [[]]
        var depth = 0
        var index = 0
        while index < body.count {
            let character = body[index]
            if character == "\\", index + 1 < body.count {
                parts[parts.count - 1] += [character, body[index + 1]]
                index += 2
                continue
            }
            if character == "{" { depth += 1 }
            if character == "}" { depth -= 1 }
            if character == ",", depth == 0 {
                parts.append([])
            } else {
                parts[parts.count - 1].append(character)
            }
            index += 1
        }
        return parts
    }

    /// `{num1..num2}`'s numbers, in order.
    static func numericRange(_ body: String) -> ClosedRange<Int>? {
        let parts = body.components(separatedBy: "..")
        guard parts.count == 2, let low = Int(parts[0]), let high = Int(parts[1]) else { return nil }
        return min(low, high)...max(low, high)
    }
}
