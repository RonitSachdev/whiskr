import Foundation

/// The switches a program has set on its terminal, read from its output as it passes through the host:
/// the alternate screen, bracketed paste, mouse and focus reporting, application cursor keys, the
/// keyboard protocol, the cursor's shape. A program sets these once, often at its start; when the kept
/// output no longer reaches back that far (`ReplayBuffer.truncated`), a window attaching would
/// otherwise draw the program's screen with none of them: a paste into Claude Code would arrive as
/// typed lines, a full-screen editor would be drawn over the scrollback.
///
/// Only the sequences that set such switches are understood; everything else passes by. Bytes may
/// arrive split anywhere.
public struct TerminalModes: Sendable, Equatable {
    /// DEC private modes by number: true after `CSI ? n h`, false after `CSI ? n l`.
    private var privateModes: [Int: Bool] = [:]
    /// The Kitty keyboard protocol's stack of flags (`CSI > f u` pushes, `CSI < n u` pops).
    private var keyboardFlags: [Int] = []
    /// xterm's modifyOtherKeys level (`CSI > 4 ; n m`).
    private var modifyOtherKeys = 0
    /// The cursor's shape (`CSI n SP q`), 0 when the program never chose.
    private var cursorShape = 0
    private var applicationKeypad = false

    private enum State: Equatable { case ground, escape, control }
    private var state = State.ground
    private var collected: [UInt8] = []

    /// Modes that are on in a fresh terminal: wraparound and a visible cursor.
    private static let onByDefault: Set<Int> = [7, 25]
    /// Never put back: synchronized output is a moment, not a setting.
    private static let transient: Set<Int> = [2026]
    private static let alternateScreens: Set<Int> = [47, 1047, 1049]
    private static let escape: UInt8 = 0x1B

    public init() {}

    public mutating func scan(_ data: Data) {
        data.withUnsafeBytes { scan($0) }
    }

    public mutating func scan(_ bytes: UnsafeRawBufferPointer) {
        var index = 0
        let count = bytes.count
        while index < count {
            if state == .ground {
                // Nearly all output is text: skip to the next escape.
                guard let found = memchr(bytes.baseAddress! + index, Int32(Self.escape), count - index) else { return }
                index = bytes.baseAddress!.distance(to: UnsafeRawPointer(found)) + 1
                state = .escape
                continue
            }
            let byte = bytes[index]
            index += 1
            switch state {
            case .ground:
                break
            case .escape:
                switch byte {
                case UInt8(ascii: "["):
                    state = .control
                    collected.removeAll(keepingCapacity: true)
                case UInt8(ascii: "c"):
                    // A full reset.
                    self = TerminalModes()
                case UInt8(ascii: "="):
                    applicationKeypad = true
                    state = .ground
                case UInt8(ascii: ">"):
                    applicationKeypad = false
                    state = .ground
                case Self.escape:
                    break
                default:
                    state = .ground
                }
            case .control:
                switch byte {
                case 0x20...0x3F where collected.count < 64:
                    collected.append(byte)
                case 0x40...0x7E:
                    finish(final: byte)
                    state = .ground
                case Self.escape:
                    state = .escape
                default:
                    state = .ground
                }
            }
        }
    }

    /// A control sequence ended: `collected` holds its parameters, `final` says what it is.
    private mutating func finish(final: UInt8) {
        let text = String(decoding: collected, as: UTF8.self)
        switch final {
        case UInt8(ascii: "h"), UInt8(ascii: "l"):
            guard text.hasPrefix("?") else { return }
            for mode in numbers(text.dropFirst()) where !Self.transient.contains(mode) { privateModes[mode] = final == UInt8(ascii: "h") }
        case UInt8(ascii: "u"):
            if text.hasPrefix(">") {
                keyboardFlags.append(numbers(text.dropFirst()).first ?? 0)
                if keyboardFlags.count > 32 { keyboardFlags.removeFirst() }
            } else if text.hasPrefix("<") {
                keyboardFlags.removeLast(min(keyboardFlags.count, max(numbers(text.dropFirst()).first ?? 1, 1)))
            } else if text.hasPrefix("=") {
                let values = numbers(text.dropFirst())
                let flags = values.first ?? 0
                let current = keyboardFlags.last ?? 0
                let next = switch values.count > 1 ? values[1] : 1 {
                case 2: current | flags
                case 3: current & ~flags
                default: flags
                }
                if keyboardFlags.isEmpty { keyboardFlags = [next] } else { keyboardFlags[keyboardFlags.count - 1] = next }
            }
        case UInt8(ascii: "m"):
            guard text.hasPrefix(">") else { return }
            let values = numbers(text.dropFirst())
            if values.first == 4 { modifyOtherKeys = values.count > 1 ? values[1] : 0 }
        case UInt8(ascii: "q"):
            guard text.hasSuffix(" "), !text.hasPrefix(">") else { return }
            cursorShape = numbers(text.dropLast()).first ?? 0
        case UInt8(ascii: "p"):
            // A soft reset puts the cursor keys, the keypad, wraparound and the cursor back.
            guard text == "!" else { return }
            for mode in [1, 6, 7, 25, 66] { privateModes[mode] = nil }
            applicationKeypad = false
        default:
            break
        }
    }

    private func numbers(_ text: Substring) -> [Int] {
        text.split(separator: ";", omittingEmptySubsequences: false).map { Int($0) ?? 0 }
    }

    /// The program is on the alternate screen (a full-screen program: an editor, a pager).
    public var onAlternateScreen: Bool {
        Self.alternateScreens.contains { privateModes[$0] == true }
    }

    /// The program takes a paste between markers (`CSI ? 2004 h`), so pasted lines are not typed lines.
    public var bracketedPaste: Bool { privateModes[2004] == true }

    /// The cursor keys send their application form (`CSI ? 1 h`): ESC O A rather than ESC [ A.
    public var applicationCursorKeys: Bool { privateModes[1] == true }

    /// What to feed a fresh terminal so it has these switches again, before the kept output.
    public var restoring: Data {
        var text = ""
        // The screen first: the other switches belong to the screen that is showing.
        if onAlternateScreen { text += "\u{1B}[?1049h" }
        for (mode, on) in privateModes.sorted(by: { $0.key < $1.key }) where !Self.alternateScreens.contains(mode) {
            if on != Self.onByDefault.contains(mode) { text += "\u{1B}[?\(mode)\(on ? "h" : "l")" }
        }
        if applicationKeypad { text += "\u{1B}=" }
        if let flags = keyboardFlags.last { text += "\u{1B}[>\(flags)u" }
        if modifyOtherKeys != 0 { text += "\u{1B}[>4;\(modifyOtherKeys)m" }
        if cursorShape != 0 { text += "\u{1B}[\(cursorShape) q" }
        return Data(text.utf8)
    }
}
