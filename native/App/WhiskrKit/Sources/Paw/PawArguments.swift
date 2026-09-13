import Foundation

/// What `paw` was asked to do, read from its command line. Options may come anywhere among the
/// arguments, as `--name value` or `--name=value`; `--` ends them.
public enum PawCommand: Sendable, Equatable {
    case run(Run)
    case send(Send)
    case wait(Wait)
    case read(target: String, lines: Int, json: Bool)
    case keys(target: String, keys: [String])
    case interrupt(target: String)
    case list(childrenOnly: Bool, json: Bool)
    case kill(target: String, force: Bool)
    case help(topic: String?)
    case skill
    case version

    public struct Run: Sendable, Equatable {
        public var command: String?
        /// The first task; "-" reads it from standard input.
        public var task: String?
        public var name: String?
        public var folder: String?
        public var worktree: String?
        public var background = false
        public var outlivesParent = false
        public var notifiesParent = true
        public var timeout: Double = 60
        public var json = false
    }

    public struct Send: Sendable, Equatable {
        public var target: String
        /// "-" reads it from standard input.
        public var text: String
        public var force = false
        public var raw = false
        public var submit = true
        public var wait = false
        public var timeout: Double = PawCommand.defaultWait
        public var json = false
    }

    public struct Wait: Sendable, Equatable {
        public enum Until: Sendable, Equatable { case settled, exited, output(String), children(all: Bool) }
        /// nil: the terminal `paw` runs in (for `--children`).
        public var target: String?
        public var until = Until.settled
        public var timeout: Double = PawCommand.defaultWait
        public var json = false
    }

    /// How long a wait lasts unless told: less than the two minutes Claude Code gives a command by
    /// default, so a wait comes back and can simply be run again.
    public static let defaultWait: Double = 90
}

public struct PawUsageError: Error, Equatable, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

extension PawCommand {
    /// Reads `arguments` (without the program's own name).
    public static func parse(_ arguments: [String]) throws(PawUsageError) -> PawCommand {
        var reader = ArgumentReader(arguments)
        guard let first = reader.positionals.first ?? reader.flags.first?.name else { return .help(topic: nil) }
        // `paw --help`, `paw -h`, `paw help run`, `paw run --help`.
        if reader.has("help") || reader.has("h") || first == "help" {
            let topic = first == "help" ? reader.positionals.dropFirst().first : (reader.positionals.first)
            return .help(topic: topic.flatMap { $0 == "help" ? nil : $0 })
        }
        if reader.positionals.isEmpty {
            if reader.has("skill") { return .skill }
            if reader.has("version") || reader.has("V") { return .version }
            throw PawUsageError("unknown option \(reader.flags.first.map { "--\($0.name)" } ?? first)")
        }
        let verb = reader.positionals.removeFirst()
        let command: PawCommand
        switch verb {
        case "run":
            var run = Run()
            run.background = reader.take("bg") || reader.take("background")
            run.name = try reader.value("name")
            run.folder = try reader.value("cwd")
            run.worktree = try reader.value("worktree")
            run.outlivesParent = reader.take("outlive-parent")
            run.notifiesParent = !reader.take("no-notify")
            run.timeout = try reader.number("timeout") ?? run.timeout
            run.json = reader.take("json")
            run.command = reader.positionals.first
            run.task = reader.positionals.dropFirst().first
            if reader.positionals.count > 2 {
                throw PawUsageError("run takes a command and a task; quote each one (paw run \"claude --model haiku\" \"Review the diff\")")
            }
            command = .run(run)
        case "send":
            guard let target = reader.positionals.first else { throw PawUsageError("send needs a terminal (t4, or its name) and the text") }
            let words = reader.positionals.dropFirst()
            guard !words.isEmpty else { throw PawUsageError("send needs the text to send (or - to read it from standard input)") }
            var send = Send(target: target, text: words.joined(separator: " "))
            send.force = reader.take("force")
            send.raw = reader.take("raw")
            send.submit = !reader.take("no-enter")
            send.wait = reader.take("wait")
            send.timeout = try reader.number("timeout") ?? send.timeout
            send.json = reader.take("json")
            command = .send(send)
        case "wait":
            var wait = Wait(target: reader.positionals.first)
            var conditions = 0
            if reader.take("exit") {
                wait.until = .exited
                conditions += 1
            }
            if let text = try reader.value("output") {
                wait.until = .output(text)
                conditions += 1
            }
            if let which = try reader.value("children") {
                guard which == "all" || which == "any" else { throw PawUsageError("--children takes all or any") }
                wait.until = .children(all: which == "all")
                conditions += 1
            }
            guard conditions <= 1 else { throw PawUsageError("wait for one thing at a time: --exit, --output or --children") }
            if wait.target == nil, case .children = wait.until {} else if wait.target == nil {
                throw PawUsageError("wait needs a terminal (t4, or its name)")
            }
            wait.timeout = try reader.number("timeout") ?? wait.timeout
            wait.json = reader.take("json")
            if reader.positionals.count > 1 { throw PawUsageError("wait takes one terminal") }
            command = .wait(wait)
        case "read":
            guard let target = reader.positionals.first else { throw PawUsageError("read needs a terminal (t4, or its name)") }
            let lines = try reader.number("lines").map { Int($0) } ?? 0
            guard lines >= 0 else { throw PawUsageError("--lines takes a number of lines") }
            command = .read(target: target, lines: lines, json: reader.take("json"))
        case "keys":
            guard let target = reader.positionals.first else { throw PawUsageError("keys needs a terminal and the keys (enter, esc, ctrl+c, up …)") }
            let keys = Array(reader.positionals.dropFirst())
            guard !keys.isEmpty else { throw PawUsageError("keys needs at least one key (enter, esc, ctrl+c, up …)") }
            command = .keys(target: target, keys: keys)
        case "interrupt":
            guard let target = reader.positionals.first else { throw PawUsageError("interrupt needs a terminal (t4, or its name)") }
            command = .interrupt(target: target)
        case "ls", "list":
            command = .list(childrenOnly: reader.take("children"), json: reader.take("json"))
        case "kill":
            guard let target = reader.positionals.first else { throw PawUsageError("kill needs a terminal (t4, or its name)") }
            command = .kill(target: target, force: reader.take("force"))
        default:
            throw PawUsageError("unknown command \(verb) (see paw --help)")
        }
        if let stray = reader.flags.first { throw PawUsageError("\(verb) does not take --\(stray.name)") }
        let oneTerminal: Bool = switch command {
        case .read, .interrupt, .kill: true
        default: false
        }
        if oneTerminal && reader.positionals.count > 1 { throw PawUsageError("\(verb) takes one terminal") }
        if case .list = command, !reader.positionals.isEmpty { throw PawUsageError("ls takes no terminal") }
        return command
    }
}

/// Splits a command line into flags (with their values, when one follows) and the rest.
private struct ArgumentReader {
    struct Flag { let name: String; var value: String?; let joined: Bool }
    var flags: [Flag] = []
    var positionals: [String] = []
    /// Flags whose value is the next argument.
    private static let taking: Set = ["name", "cwd", "worktree", "timeout", "output", "children", "lines"]

    init(_ arguments: [String]) {
        var index = 0
        var optionsEnded = false
        while index < arguments.count {
            let argument = arguments[index]
            index += 1
            if optionsEnded || argument == "-" || !argument.hasPrefix("-") {
                positionals.append(argument)
                continue
            }
            if argument == "--" {
                optionsEnded = true
                continue
            }
            let body = argument.hasPrefix("--") ? String(argument.dropFirst(2)) : String(argument.dropFirst())
            if let equals = body.firstIndex(of: "=") {
                flags.append(Flag(name: String(body[..<equals]), value: String(body[body.index(after: equals)...]), joined: true))
            } else if Self.taking.contains(body), index < arguments.count, !arguments[index].hasPrefix("--") {
                flags.append(Flag(name: body, value: arguments[index], joined: false))
                index += 1
            } else {
                flags.append(Flag(name: body, value: nil, joined: false))
            }
        }
    }

    func has(_ name: String) -> Bool { flags.contains { $0.name == name } }

    /// A switch: true if present (and taken out).
    mutating func take(_ name: String) -> Bool {
        guard let index = flags.firstIndex(where: { $0.name == name }) else { return false }
        flags.remove(at: index)
        return true
    }

    mutating func value(_ name: String) throws(PawUsageError) -> String? {
        guard let index = flags.firstIndex(where: { $0.name == name }) else { return nil }
        let flag = flags.remove(at: index)
        guard let value = flag.value, !value.isEmpty else { throw PawUsageError("--\(name) needs a value") }
        return value
    }

    mutating func number(_ name: String) throws(PawUsageError) -> Double? {
        guard let text = try value(name) else { return nil }
        guard let number = Double(text), number.isFinite, number >= 0 else { throw PawUsageError("--\(name) takes a number, not \(text)") }
        return number
    }
}
