import Foundation

/// The text the session host types into terminals on a program's behalf (`paw`): messages tagged with
/// who sent them, the notes a parent gets about its helpers, the keys a name stands for, and how a
/// first task reaches a helper. Kept apart from the host so each rule can be tested on its own.
public enum AgentText {
    /// How a message reads in an agent's input: `<paw from="t4 review">…</paw>`, so the agent can tell a
    /// helper's report (or another agent's message) from what its person typed.
    public static func tagged(_ text: String, from sender: String?, note: String? = nil) -> String {
        var attributes = " from=\"\(sender ?? "outside")\""
        if let note { attributes += " note=\"\(note)\"" }
        return "<paw\(attributes)>\(text)</paw>"
    }

    /// What a parent is told when a helper it started needs an answer, stopped on an error, or ended.
    public enum Note: Sendable, Equatable {
        case blocked(kind: String?)
        case error
        case exited(code: Int32?)

        /// The word in the tag's `note` attribute.
        public var word: String {
            switch self {
            case .blocked: "blocked"
            case .error: "error"
            case .exited: "exited"
            }
        }

        /// The sentence, for a helper with this address and name.
        public func text(label: String, address: String) -> String {
            switch self {
            case .blocked(let kind):
                let what = kind.map { " (\($0))" } ?? ""
                return "\(label) is waiting for an answer\(what). Look with: paw read \(address)"
            case .error:
                return "\(label) stopped on an error. Look with: paw read \(address)"
            case .exited(let code):
                return code.map { "\(label) has ended (exit code \($0))." } ?? "\(label) has ended."
            }
        }
    }

    /// A terminal's name: a lower-case letter, then letters, digits, "-" or "_", at most 32 (herdr's
    /// rule), so it can be typed and never looks like an address ("t4").
    public static func isValidName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, ("a"..."z").contains(first), name.count <= 32 else { return false }
        guard !isAddressShaped(name) else { return false }
        return name.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" || $0 == "_" }
    }

    /// "t" and digits: what the host gives as addresses.
    public static func isAddressShaped(_ text: String) -> Bool {
        text.count > 1 && text.hasPrefix("t") && text.dropFirst().allSatisfy { $0.isASCII && $0.isNumber }
    }

    // MARK: First tasks

    /// How a task given to `run` reaches the program.
    public enum Delivery: Sendable, Equatable {
        /// Claude Code takes its first message on its command line and holds it until it is ready (past
        /// a trust question, say): the line typed passes it from the environment, unquoted nowhere.
        case argument
        /// Anything else gets it pasted once it is ready for input.
        case paste
    }

    /// The environment variable a first task travels in when it goes on Claude's command line.
    public static let taskVariable = "PAW_TASK"

    public static func delivery(for command: String) -> Delivery {
        isClaude(command) ? .argument : .paste
    }

    /// The line typed at the prompt for `command` with `task`: Claude's gets the task as its argument,
    /// after `--`, so an option that takes several values (`--allowedTools A B`) cannot swallow it.
    public static func typedLine(command: String, task: String?) -> String {
        guard task != nil, delivery(for: command) == .argument else { return command }
        let endsOptions = command.split(whereSeparator: \.isWhitespace).contains("--")
        return command + (endsOptions ? "" : " --") + " \"$\(taskVariable)\""
    }

    /// Whether a command line runs Claude Code: its first word, after any `NAME=value` settings, is
    /// `claude` (or a path to it).
    public static func isClaude(_ command: String) -> Bool {
        let words = command.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let program = words.first(where: { !$0.contains("=") || $0.hasPrefix("/") || $0.hasPrefix(".") }) else { return false }
        let name = program.split(separator: "/").last.map(String.init) ?? program
        return name == "claude"
    }
}

/// Keys by the names `paw keys` takes ("enter", "esc", "ctrl+c", "up"), as the bytes a terminal sends.
public enum TerminalKeys {
    /// The bytes for each name, in order; nil (and nothing sent) if any name is unknown. A single
    /// character stands for itself ("1", "y"). Cursor keys follow the program's choice of form.
    public static func encode(_ names: [String], applicationCursor: Bool = false) -> Data? {
        var bytes = Data()
        for name in names {
            guard let key = encode(name, applicationCursor: applicationCursor) else { return nil }
            bytes.append(key)
        }
        return bytes
    }

    public static func encode(_ name: String, applicationCursor: Bool = false) -> Data? {
        if name.count == 1 { return Data(name.utf8) }
        let lower = name.lowercased()
        let cursor = applicationCursor ? "\u{1B}O" : "\u{1B}["
        if let fixed = named[lower] { return Data(fixed.utf8) }
        switch lower {
        case "up": return Data((cursor + "A").utf8)
        case "down": return Data((cursor + "B").utf8)
        case "right": return Data((cursor + "C").utf8)
        case "left": return Data((cursor + "D").utf8)
        case "home": return Data((cursor + "H").utf8)
        case "end": return Data((cursor + "F").utf8)
        default: break
        }
        if lower.hasPrefix("ctrl+"), lower.count == 6, let scalar = lower.unicodeScalars.last {
            switch scalar {
            case "a"..."z": return Data([UInt8(scalar.value) - 0x60])
            case "[": return Data([0x1B])
            case "\\": return Data([0x1C])
            case "]": return Data([0x1D])
            case "@", " ": return Data([0x00])
            default: return nil
            }
        }
        if lower.hasPrefix("alt+"), name.count == 5, let last = name.last {
            return Data(("\u{1B}" + String(last)).utf8)
        }
        return nil
    }

    private static let named: [String: String] = [
        "enter": "\r", "return": "\r", "esc": "\u{1B}", "escape": "\u{1B}", "tab": "\t", "shift+tab": "\u{1B}[Z",
        "backspace": "\u{7F}", "delete": "\u{1B}[3~", "space": " ", "pageup": "\u{1B}[5~", "pagedown": "\u{1B}[6~",
        "f1": "\u{1B}OP", "f2": "\u{1B}OQ", "f3": "\u{1B}OR", "f4": "\u{1B}OS", "f5": "\u{1B}[15~", "f6": "\u{1B}[17~",
        "f7": "\u{1B}[18~", "f8": "\u{1B}[19~", "f9": "\u{1B}[20~", "f10": "\u{1B}[21~", "f11": "\u{1B}[23~", "f12": "\u{1B}[24~",
    ]
}
