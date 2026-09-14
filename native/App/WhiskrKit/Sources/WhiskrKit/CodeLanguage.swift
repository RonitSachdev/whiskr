import Foundation

/// A language a file can be in, as VS Code knows it: its id ("typescriptreact"), its name ("TypeScript JSX"),
/// the TextMate grammar that colours it and its language configuration (comments, brackets, pairs that close
/// themselves). Languages come from `LanguageRegistry`: the ones bundled from VS Code's built-in extensions
/// and their upstreams, and the ones a person adds.
///
/// Two values are the same language when their ids are equal.
public struct CodeLanguage: Hashable, Sendable, Identifiable {
    /// VS Code's language id: "swift", "typescript", "shellscript", "plaintext".
    public let id: String
    /// VS Code's name for it, its first alias ("TypeScript JSX"); the id when it has none.
    public let displayName: String
    /// The other names it goes by, as contributed ("TypeScript", "ts", "typescript").
    public let aliases: [String]
    /// The file extensions it claims, with their dot (".ts", ".mts").
    public let extensions: [String]
    /// The file names it claims ("Dockerfile", "Gemfile").
    public let filenames: [String]
    /// Its grammar's scope ("source.ts"); nil for plain text and languages without a grammar.
    public let scopeName: String?
    /// Its language configuration, with VS Code's defaults where the file says nothing.
    public let configuration: LanguageConfiguration

    public init(id: String, displayName: String, aliases: [String] = [], extensions: [String] = [], filenames: [String] = [],
                scopeName: String? = nil, configuration: LanguageConfiguration = LanguageConfiguration()) {
        self.id = id
        self.displayName = displayName
        self.aliases = aliases
        self.extensions = extensions
        self.filenames = filenames
        self.scopeName = scopeName
        self.configuration = configuration
    }

    public static func == (lhs: CodeLanguage, rhs: CodeLanguage) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }

    /// VS Code's id for plain text.
    public static let plainTextID = "plaintext"

    public var isPlainText: Bool { id == Self.plainTextID }

    public static var plainText: CodeLanguage { known(plainTextID) }
    public static var markdown: CodeLanguage { known("markdown") }
    public static var diff: CodeLanguage { known("diff") }
    public static var json: CodeLanguage { known("json") }
    public static var jsonWithComments: CodeLanguage { known("jsonc") }
    public static var shellScript: CodeLanguage { known("shellscript") }
    public static var gitCommit: CodeLanguage { known("git-commit") }
    public static var gitRebase: CodeLanguage { known("git-rebase") }
    public static var log: CodeLanguage { known("log") }

    /// A bundled language by id; always there, as the bundle's tests check.
    private static func known(_ id: String) -> CodeLanguage {
        LanguageRegistry.shared.language(id: id) ?? CodeLanguage(id: id, displayName: id)
    }
}

/// A language configuration (`language-configuration.json`), read as VS Code reads one
/// (`languageConfigurationExtensionPoint.ts`): entries of the wrong shape are left out, and what is absent
/// takes VS Code's default (auto-closing pairs are the brackets, surrounding pairs the auto-closing pairs,
/// the word pattern VS Code's default one).
public struct LanguageConfiguration: Hashable, Sendable {
    /// A block comment's opening and closing ("/*", "*/").
    public struct CommentPair: Hashable, Sendable {
        public var open: String
        public var close: String
        public init(open: String, close: String) {
            self.open = open
            self.close = close
        }
    }

    /// A JavaScript regular expression, as configurations write them: a pattern and its flags ("i", "u").
    public struct Pattern: Hashable, Sendable {
        public var source: String
        public var flags: String
        public init(_ source: String, flags: String = "") {
            self.source = source
            self.flags = flags
        }

        /// The pattern for Foundation, with the flags it has an equivalent of ("i", "m", "s"); nil when ICU
        /// cannot read it.
        public func regularExpression() -> NSRegularExpression? {
            var options: NSRegularExpression.Options = []
            if flags.contains("i") { options.insert(.caseInsensitive) }
            if flags.contains("m") { options.insert(.anchorsMatchLines) }
            if flags.contains("s") { options.insert(.dotMatchesLineSeparators) }
            return try? NSRegularExpression(pattern: source, options: options)
        }
    }

    /// When a line's indentation changes the next line's (`indentationRules`).
    public struct IndentationRules: Hashable, Sendable {
        public var increaseIndentPattern: Pattern
        public var decreaseIndentPattern: Pattern
        public var indentNextLinePattern: Pattern?
        public var unIndentedLinePattern: Pattern?
    }

    /// What pressing Enter does to the new line when a rule matches (`onEnterRules`).
    public struct OnEnterRule: Hashable, Sendable {
        public enum Indent: String, Hashable, Sendable {
            /// Keep the line's indentation.
            case none
            /// Indent the new line once more.
            case indent
            /// Put the cursor on an indented line and the text after it on a line back at the old indentation.
            case indentOutdent
            /// Indent the new line once less.
            case outdent
        }

        /// What the text before the cursor on its line must match.
        public var beforeText: Pattern
        /// What the text after the cursor on its line must match.
        public var afterText: Pattern?
        /// What the line above must match.
        public var previousLineText: Pattern?
        public var indent: Indent
        /// Text added after the new line's indentation (" * " in a doc comment).
        public var appendText: String?
        /// How many characters of indentation to take off the new line.
        public var removeText: Int?
    }

    /// The line comment's start ("//", "#").
    public var lineComment: String?
    public var blockComment: CommentPair?
    /// What bracket matching pairs up.
    public var brackets: [EditingPairs.Pair]
    /// Pairs whose closing is added when the opening is typed, and where not (`notIn`).
    public var autoClosingPairs: [EditingPairs.AutoClosingPair]
    /// What a typed opening wraps a selection in.
    public var surroundingPairs: [EditingPairs.Pair]
    /// The characters before which a pair closes; nil for VS Code's defaults (`EditingPairs` applies them).
    public var autoCloseBefore: String?
    public var indentationRules: IndentationRules?
    /// What a word is (double-click, word moves); nil for VS Code's default, `defaultWordPattern`.
    public var wordPattern: Pattern?
    /// Blocks are marked by indentation, not brackets (`folding.offSide`: Python, YAML): a block's last
    /// line is its last indented one, blank lines after it left outside.
    public var offSide = false
    /// Rules for Enter, in the order they are tried; rules of the wrong shape are left out, as in VS Code.
    public var onEnterRules: [OnEnterRule] = []

    /// No comments, brackets or pairs: what VS Code uses for a language without a configuration.
    public init() {
        brackets = []
        autoClosingPairs = []
        surroundingPairs = []
    }

    /// The configuration in a `language-configuration.json` (JSON with comments).
    public init(data: Data) throws {
        self.init(json: try JSONC.dictionary(data))
    }

    /// The configuration in a parsed `language-configuration.json`.
    public init(json: [String: Any]) {
        // A pair with an empty side is no pair (nothing could be typed or found for it), and is left out.
        func pair(_ value: Any?) -> EditingPairs.Pair? {
            guard let strings = value as? [Any], strings.count == 2, let open = strings[0] as? String, let close = strings[1] as? String,
                  !open.isEmpty, !close.isEmpty else { return nil }
            return EditingPairs.Pair(open, close)
        }
        func stringList(_ value: Any?) -> [String]? {
            guard let list = value as? [Any] else { return nil }
            let strings = list.compactMap { $0 as? String }
            return strings.count == list.count ? strings : nil
        }
        // A list in which no entry is valid counts as absent, as in VS Code.
        func nonEmpty<T>(_ list: [T]) -> [T]? { list.isEmpty ? nil : list }

        let comments = json["comments"] as? [String: Any]
        if let line = comments?["lineComment"] as? String {
            lineComment = line
        } else if let line = (comments?["lineComment"] as? [String: Any])?["comment"] as? String {
            lineComment = line
        }
        blockComment = pair(comments?["blockComment"]).map { CommentPair(open: $0.open, close: $0.close) }

        let brackets = nonEmpty((json["brackets"] as? [Any] ?? []).compactMap(pair))
        self.brackets = brackets ?? []

        let closing: [EditingPairs.AutoClosingPair]? = nonEmpty((json["autoClosingPairs"] as? [Any] ?? []).compactMap { entry in
            if let simple = pair(entry) { return EditingPairs.AutoClosingPair(simple.open, simple.close) }
            guard let object = entry as? [String: Any], let open = object["open"] as? String, let close = object["close"] as? String,
                  !open.isEmpty, !close.isEmpty else { return nil }
            var notIn: Set<TokenContext> = []
            if object["notIn"] != nil {
                guard let names = stringList(object["notIn"]) else { return nil }
                for name in names {
                    switch name {
                    case "string": notIn.insert(.string)
                    case "comment": notIn.insert(.comment)
                    case "regex": notIn.insert(.regex)
                    default: break
                    }
                }
            }
            return EditingPairs.AutoClosingPair(open, close, notIn: notIn)
        })
        autoClosingPairs = closing ?? self.brackets.map { EditingPairs.AutoClosingPair($0.open, $0.close) }

        let surrounding: [EditingPairs.Pair]? = nonEmpty((json["surroundingPairs"] as? [Any] ?? []).compactMap { entry in
            if let simple = pair(entry) { return simple }
            guard let object = entry as? [String: Any], let open = object["open"] as? String, let close = object["close"] as? String,
                  !open.isEmpty, !close.isEmpty else { return nil }
            return EditingPairs.Pair(open, close)
        })
        surroundingPairs = surrounding ?? autoClosingPairs.map { EditingPairs.Pair($0.open, $0.close) }

        autoCloseBefore = json["autoCloseBefore"] as? String
        wordPattern = Self.pattern(json["wordPattern"])
        onEnterRules = Self.onEnterRules(json["onEnterRules"])
        offSide = (json["folding"] as? [String: Any])?["offSide"] as? Bool ?? false
        if let rules = json["indentationRules"] as? [String: Any],
           let increase = Self.pattern(rules["increaseIndentPattern"]), let decrease = Self.pattern(rules["decreaseIndentPattern"]) {
            indentationRules = IndentationRules(increaseIndentPattern: increase, decreaseIndentPattern: decrease,
                                                indentNextLinePattern: Self.pattern(rules["indentNextLinePattern"]),
                                                unIndentedLinePattern: Self.pattern(rules["unIndentedLinePattern"]))
        }
    }

    /// `onEnterRules`, as VS Code's `_extractValidOnEnterRules` reads them.
    private static func onEnterRules(_ value: Any?) -> [OnEnterRule] {
        (value as? [Any] ?? []).compactMap { entry in
            guard let rule = entry as? [String: Any], let action = rule["action"] as? [String: Any],
                  let indentName = action["indent"] as? String, let indent = OnEnterRule.Indent(rawValue: indentName),
                  let before = pattern(rule["beforeText"]) else { return nil }
            // Optional parts of the wrong shape are left out, the rule kept.
            let removeText = (action["removeText"] as? NSNumber)?.intValue
            return OnEnterRule(beforeText: before, afterText: pattern(rule["afterText"]), previousLineText: pattern(rule["previousLineText"]),
                               indent: indent, appendText: (action["appendText"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                               removeText: removeText.flatMap { $0 == 0 ? nil : $0 })
        }
    }

    /// The pairs as the editor's typing and bracket matching use them.
    public var editingPairs: EditingPairs {
        EditingPairs(brackets: brackets, autoClosingPairs: autoClosingPairs, surroundingPairs: surroundingPairs, autoCloseBefore: autoCloseBefore)
    }

    /// VS Code's word definition when a language gives none (`DEFAULT_WORD_REGEXP` in `wordHelper.ts`): a
    /// number with a decimal point, or a run of characters that are neither spaces nor separators.
    public static let defaultWordPattern: Pattern = {
        let separators = "`~!@#$%^&*()-=+[{]}\\|;:'\",.<>/?"
        return Pattern("(-?\\d*\\.\\d\\w*)|([^" + separators.map { "\\" + String($0) }.joined() + "\\s]+)")
    }()

    /// A pattern written as a string or as `{ "pattern": …, "flags": … }`.
    private static func pattern(_ value: Any?) -> Pattern? {
        if let source = value as? String { return Pattern(source) }
        guard let object = value as? [String: Any], let source = object["pattern"] as? String else { return nil }
        if object["flags"] != nil, !(object["flags"] is String) { return nil }
        return Pattern(source, flags: object["flags"] as? String ?? "")
    }
}
