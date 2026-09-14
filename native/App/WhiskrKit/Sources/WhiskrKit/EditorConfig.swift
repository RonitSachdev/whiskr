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

    /// An `.editorconfig` larger than this is not one anybody wrote by hand, and is read as none: it is
    /// read at every save.
    static let largestFile = 256 * 1024

    public static func readFile(_ path: String) -> String? {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int, size <= largestFile,
              let data = FileManager.default.contents(atPath: path) else { return nil }
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
        return GlobMatcher(Array(pattern)).matches(Array(path))
    }

    /// A glob as a small automaton, run over the path once with every state it can be in at each
    /// character (as a Thompson NFA), so matching takes time in proportion to the path times the glob,
    /// never more. A regular expression of the same glob backtracks: `[*a*a*a*a*a*a*c]` from a cloned
    /// repository took longer than 40 seconds on a 60-character name, on the main thread at every save.
    ///
    /// `*` is any characters but "/", `**` any characters, `?` one but "/", `[seq]` and `[!seq]` (ranges
    /// such as `a-z` included), `{a,b}` (nested), `{1..5}` (a number in the range), and `\` escaping the
    /// next character. A `{` or `[` without its closing is itself.
    struct GlobMatcher {
        enum Step {
            /// One character that `test` accepts, then the next step.
            case one((Character) -> Bool)
            /// An optional sign and digits whose number is in the range, then the next step.
            case number(ClosedRange<Int>)
            /// Any of these steps, taking no character.
            case jump([Int])
        }

        private(set) var steps: [Step] = []

        init(_ glob: [Character]) {
            compile(glob)
        }

        func matches(_ path: [Character]) -> Bool {
            let accept = steps.count
            // reached[i]: the steps the automaton can be at before path[i].
            var reached = [Set<Int>](repeating: [], count: path.count + 1)
            reached[0] = [0]
            for position in 0...path.count {
                // Every step reachable without taking a character.
                var stack = Array(reached[position])
                var states = reached[position]
                while let state = stack.popLast() {
                    guard state < accept, case .jump(let targets) = steps[state] else { continue }
                    for target in targets where states.insert(target).inserted { stack.append(target) }
                }
                if position == path.count { return states.contains(accept) }
                for state in states where state < accept {
                    switch steps[state] {
                    case .one(let test):
                        if test(path[position]) { reached[position + 1].insert(state + 1) }
                    case .number(let range):
                        var end = position
                        if end < path.count, path[end] == "+" || path[end] == "-" { end += 1 }
                        var digitsEnd = end
                        while digitsEnd < path.count, path[digitsEnd].isASCII, path[digitsEnd].isNumber {
                            digitsEnd += 1
                            if let number = Int(String(path[position..<digitsEnd])), range.contains(number) { reached[digitsEnd].insert(state + 1) }
                        }
                    case .jump:
                        break
                    }
                }
            }
            return false
        }

        private mutating func add(_ step: Step) { steps.append(step) }

        /// Any number of what `test` accepts: a jump to it or past it, it, and a jump back.
        private mutating func repeating(_ test: @escaping (Character) -> Bool) {
            let start = steps.count
            add(.jump([start + 1, start + 3]))
            add(.one(test))
            add(.jump([start]))
        }

        /// Braces nested deeper than this are read as plain characters: each level is a call deeper, and a
        /// repository's `.editorconfig` must not be able to run a thread's stack out.
        static let deepestBraces = 32

        private mutating func compile(_ glob: [Character], depth: Int = 0) {
            var index = 0
            while index < glob.count {
                let character = glob[index]
                switch character {
                case "\\":
                    index += 1
                    if index < glob.count {
                        let escaped = glob[index]
                        add(.one { $0 == escaped })
                    }
                case "*":
                    if index + 1 < glob.count, glob[index + 1] == "*" {
                        // "**/" at the start of a segment also matches no folder at all.
                        let atSegment = index == 0 || glob[index - 1] == "/"
                        if atSegment, index + 2 < glob.count, glob[index + 2] == "/" {
                            let start = steps.count
                            add(.jump([start + 1, start + 5]))
                            add(.jump([start + 2, start + 4]))
                            add(.one { _ in true })
                            add(.jump([start + 1]))
                            add(.one { $0 == "/" })
                            index += 2
                        } else {
                            repeating { _ in true }
                            index += 1
                        }
                    } else {
                        repeating { $0 != "/" }
                    }
                case "?":
                    add(.one { $0 != "/" })
                case "[":
                    if let close = EditorConfig.closing("]", in: glob, from: index + 1), !glob[(index + 1)..<close].contains("/") {
                        add(.one(Self.characterClass(Array(glob[(index + 1)..<close]))))
                        index = close
                    } else {
                        add(.one { $0 == "[" })
                    }
                case "{":
                    if depth < Self.deepestBraces, let close = EditorConfig.closing("}", in: glob, from: index + 1, opening: "{") {
                        let body = Array(glob[(index + 1)..<close])
                        let alternatives = EditorConfig.split(body)
                        if let range = EditorConfig.numericRange(String(body)) {
                            add(.number(range))
                        } else if alternatives.count > 1 {
                            alternation(alternatives, depth: depth + 1)
                        } else {
                            add(.one { $0 == "{" })
                            compile(body, depth: depth + 1)
                            add(.one { $0 == "}" })
                        }
                        index = close
                    } else {
                        add(.one { $0 == "{" })
                    }
                default:
                    add(.one { $0 == character })
                }
                index += 1
            }
        }

        /// One of `alternatives`: a jump to each, and from the end of each a jump past them all.
        private mutating func alternation(_ alternatives: [[Character]], depth: Int) {
            let fork = steps.count
            add(.jump([]))
            var starts: [Int] = [], ends: [Int] = []
            for alternative in alternatives {
                starts.append(steps.count)
                compile(alternative, depth: depth)
                ends.append(steps.count)
                add(.jump([]))
            }
            steps[fork] = .jump(starts)
            for end in ends { steps[end] = .jump([steps.count]) }
        }

        /// `[seq]`'s test: its characters and ranges ("a-z"), or anything but them after "!" or "^".
        /// A "\\" takes the next character as itself.
        static func characterClass(_ body: [Character]) -> (Character) -> Bool {
            var body = body
            let negated = body.first == "!" || body.first == "^"
            if negated { body.removeFirst() }
            var singles = Set<Character>()
            var ranges: [ClosedRange<Character>] = []
            var index = 0
            while index < body.count {
                var low = body[index]
                if low == "\\", index + 1 < body.count {
                    index += 1
                    low = body[index]
                }
                if index + 2 < body.count, body[index + 1] == "-", body[index + 2] >= low {
                    ranges.append(low...body[index + 2])
                    index += 3
                } else {
                    singles.insert(low)
                    index += 1
                }
            }
            return { character in (singles.contains(character) || ranges.contains { $0.contains(character) }) != negated }
        }
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
