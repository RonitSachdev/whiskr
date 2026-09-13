import Foundation

/// What a program says of itself through its terminal (OSC 7501, the Program Status Protocol herdr and
/// Claude Code speak): working, blocked on a question, idle at its prompt. Claude Code reports only to a
/// terminal that answers its probe (`ESC ] 7501 ; ? ST`), which the session host does.
public struct ProgramReport: Sendable, Equatable, Codable {
    public enum State: String, Sendable, Codable, CaseIterable {
        case idle, working, done, blocked, error
    }

    public var state: State
    /// For `blocked`: what it waits for ("permission", "question", "auth"), when it says.
    public var kind: String?
    /// The program's own name for itself ("claude"), when it says.
    public var app: String?
    /// How many times it has gone from working (or blocked) to not working: its finished turns.
    public var turns: Int

    public init(state: State, kind: String? = nil, app: String? = nil, turns: Int = 0) {
        self.state = state
        self.kind = kind
        self.app = app
        self.turns = turns
    }

    /// Busy with something: working, or waiting for an answer in the middle of a turn.
    public var isBusy: Bool { state == .working || state == .blocked }

    /// The next report, from the fields of one OSC 7501 record: the turn count goes up when a busy
    /// program stops being busy. nil when the record clears the report (`state=clear`).
    public static func next(after previous: ProgramReport?, fields: [String: String]) -> ProgramReport? {
        guard let word = fields["state"] else { return previous }
        if word == "clear" { return nil }
        guard let state = State(rawValue: word) else { return previous }
        var report = ProgramReport(state: state, kind: fields["kind"], app: fields["app"] ?? previous?.app, turns: previous?.turns ?? 0)
        if previous?.isBusy == true && !report.isBusy { report.turns += 1 }
        return report
    }
}

/// Reads a terminal's output as it passes for the few things the host itself must act on: program
/// status reports (OSC 7501) for the program's own record (the one without an `id`), the probe asking
/// whether this terminal listens for them, and the mark a shell prints when its prompt is up (OSC 7, as
/// our zsh integration and Terminal use it). Everything else passes by. Bytes may arrive split anywhere.
public struct ProgramStatusScanner: Sendable {
    public enum Finding: Sendable, Equatable {
        /// A report's fields (`state=working:kind=…`), for the program's own record.
        case report([String: String])
        /// The probe; answer with `reply`.
        case probe(reply: Data)
        /// A shell's prompt is up (it said where it is).
        case prompt
    }

    private enum State: Sendable { case ground, escape, osc, oscEscape }
    private var state = State.ground
    private var collected: [UInt8] = []
    /// An OSC longer than this is not one we read; the rest of it is skipped.
    private static let longest = 4096
    private var overlong = false

    public init() {}

    /// What `data` holds, in order.
    public mutating func scan(_ data: Data) -> [Finding] {
        data.withUnsafeBytes { scan($0) }
    }

    public mutating func scan(_ bytes: UnsafeRawBufferPointer) -> [Finding] {
        var found: [Finding] = []
        var index = 0
        let count = bytes.count
        while index < count {
            if state == .ground {
                // Nearly all output is text: skip to the next escape.
                guard let base = bytes.baseAddress, let hit = memchr(base + index, 0x1B, count - index) else { return found }
                index = base.distance(to: UnsafeRawPointer(hit)) + 1
                state = .escape
                continue
            }
            let byte = bytes[index]
            index += 1
            switch state {
            case .ground:
                break
            case .escape:
                if byte == UInt8(ascii: "]") {
                    state = .osc
                    collected.removeAll(keepingCapacity: true)
                    overlong = false
                } else {
                    state = byte == 0x1B ? .escape : .ground
                }
            case .osc:
                switch byte {
                case 0x07:
                    finish(terminator: [0x07], into: &found)
                case 0x9C:
                    finish(terminator: [0x1B, UInt8(ascii: "\\")], into: &found)
                case 0x1B:
                    state = .oscEscape
                case 0x18, 0x1A:
                    // CAN and SUB abandon a sequence.
                    state = .ground
                default:
                    if collected.count < Self.longest { collected.append(byte) } else { overlong = true }
                }
            case .oscEscape:
                if byte == UInt8(ascii: "\\") {
                    finish(terminator: [0x1B, UInt8(ascii: "\\")], into: &found)
                } else {
                    // An escape that is not ST ends the string and begins something new.
                    state = .escape
                    index -= 1
                }
            }
        }
        return found
    }

    private mutating func finish(terminator: [UInt8], into found: inout [Finding]) {
        state = .ground
        guard !overlong else { return }
        let body = collected
        if body.starts(with: Self.statusPrefix) {
            let rest = body.dropFirst(Self.statusPrefix.count)
            if rest.elementsEqual([UInt8(ascii: "?")]) {
                // The answer is the probe itself: "I listen".
                found.append(.probe(reply: Data([0x1B, UInt8(ascii: "]")] + Self.statusPrefix + [UInt8(ascii: "?")] + terminator)))
                return
            }
            let fields = Self.fields(String(decoding: rest, as: UTF8.self))
            // Records of a program's parts (their own `id`) are not the program's own state.
            if (fields["id"] ?? "").isEmpty { found.append(.report(fields)) }
        } else if body.starts(with: [UInt8(ascii: "7"), UInt8(ascii: ";")]) {
            found.append(.prompt)
        }
    }

    private static let statusPrefix: [UInt8] = Array("7501;".utf8)

    /// `state=blocked:kind=permission` → ["state": "blocked", "kind": "permission"].
    static func fields(_ text: String) -> [String: String] {
        var fields: [String: String] = [:]
        for part in text.split(separator: ":", omittingEmptySubsequences: true) {
            guard let equals = part.firstIndex(of: "=") else { continue }
            fields[String(part[..<equals])] = String(part[part.index(after: equals)...])
        }
        return fields
    }
}
