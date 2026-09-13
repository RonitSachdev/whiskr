import Foundation

/// What the answer bar offers for one ask: each option with the keys that pick it in Claude Code's own
/// menu in the terminal, and a fingerprint of the ask as shown, so an answer is refused when the ask
/// has changed or gone since (as Ovis refuses with `prompt_changed`).
///
/// What is verified and what is assumed, against the installed Claude Code 2.1.305 (its menus read from
/// the shipped program's own source, not tried in a live session):
///   - Verified: the order of each menu's rows, as noted per kind below, and that Esc on a permission
///     dialog answers "No" (its cancel is a deny, and the dialog labels its "No" row "(esc)").
///   - Assumed: that typing a row's number picks it at once, as Ovis does it and as `docs/DESIGN.md`
///     records; the menus show the numbers, but no answer has been sent this way by this app yet.
///   - Assumed where a row's position depends on something hooks do not report; those options say so
///     with `positionVerified == false`.
public struct AnswerPlan: Sendable, Equatable {
    public enum Role: Sendable, Equatable {
        case allow, allowAlways, deny
        /// One of a question's choices, or an approval of a plan.
        case choose
        /// Picks Claude Code's own free-text row; the reply is then typed in the terminal.
        case typeInstead
        /// Nothing can be picked from here: the answer is given in the terminal (focus the pane).
        case answerInTerminal
    }

    public struct Option: Sendable, Equatable, Identifiable {
        public let id: Int                // its place in this bar, from 0
        public let label: String
        public let role: Role
        /// The keystrokes to type into the pane, e.g. "1" or "\u{1B}" (Esc); nil when there are none
        /// to send and the pane is focused instead.
        public let keys: String?
        /// Whether Enter alone (the row Claude Code's menu starts on) would pick it.
        public let isDefault: Bool
        /// Whether the row's position, and so `keys`, was read from the installed Claude Code. False
        /// when it depends on a setting or state that hooks do not report.
        public let positionVerified: Bool
    }

    public let askID: String
    /// The ask as it was shown. Before sending keys, `isCurrent(in:)` checks the asks open now.
    public let fingerprint: String
    public let options: [Option]

    /// - Parameter planClearsContext: the account's `showClearContextOnPlanAccept` setting (off by
    ///   default). When on, Claude Code puts a "Yes, clear context…" row first on plan approval.
    public init(ask: Ask, planClearsContext: Bool = false) {
        askID = ask.id
        fingerprint = Self.fingerprint(of: ask)
        var options: [Option] = []
        func add(_ label: String, _ role: Role, keys: String?, isDefault: Bool = false, verified: Bool = true) {
            options.append(Option(id: options.count, label: label, role: role, keys: keys, isDefault: isDefault, positionVerified: verified))
        }
        switch ask.kind {
        case .permission:
            // 2.1.305: "Yes", then one row applying every suggested rule when Claude Code suggests any,
            // [a row turning on auto mode where that is offered], then "No". The menu starts on "Yes".
            add("Allow", .allow, keys: "1", isDefault: true)
            // For a command the always-row can be an editable prefix that waits for Enter; whether "2"
            // alone applies it then is not known, so this one is marked unverified.
            if !ask.options.isEmpty {
                add("Always: \(ask.options.joined(separator: "; "))", .allowAlways, keys: "2", verified: !["Bash", "PowerShell"].contains(ask.tool))
            }
            // "No" moves down when an auto-mode row is offered, so Esc is used: it is "No" wherever the row is.
            add("Deny", .deny, keys: "\u{1B}")
            add("Deny and say why…", .answerInTerminal, keys: nil)
        case .question where ask.questionCount <= 1 && !ask.multiSelect:
            // 2.1.305: the question's options in order, then "Other" (a text field: "Type something."),
            // then sometimes "Chat about this". The menu starts on the first option.
            for (at, label) in ask.options.enumerated() {
                add(label, .choose, keys: "\(at + 1)", isDefault: at == 0)
            }
            add("Something else…", .typeInstead, keys: "\(ask.options.count + 1)")
        case .question:
            // Several questions step through tabs, and several picks need a submit row; neither is
            // answered from here, so the choices are shown and the answer is given in the terminal.
            add("Answer in the terminal", .answerInTerminal, keys: nil, isDefault: true)
        case .plan:
            // 2.1.305 without the clear-context row: "Yes, auto-accept edits" (or the bypass or auto
            // mode variant, in the same place), "Yes, manually approve edits", [Ultraplan], then
            // "No, keep planning" (a text field). The approvals are withheld when the plan is too long to
            // show, which hooks cannot tell; so these positions are unverified.
            let first = planClearsContext ? 2 : 1
            if planClearsContext { add("Approve, clear context, auto-accept edits", .choose, keys: "1", isDefault: true, verified: false) }
            add("Approve, auto-accept edits", .choose, keys: "\(first)", isDefault: !planClearsContext, verified: false)
            add("Approve, review each edit", .choose, keys: "\(first + 1)", verified: false)
            add("Keep planning…", .answerInTerminal, keys: nil)
        case .form:
            // MCP forms are filled in Claude Code's own dialog.
            add("Answer in the terminal", .answerInTerminal, keys: nil, isDefault: true)
        }
        self.options = options
    }

    /// Whether the ask this plan was made for is still open and unchanged among `asks` (the session's
    /// current asks). An answer must not be sent otherwise: the keys would land on another prompt.
    public func isCurrent(in asks: [Ask]) -> Bool {
        asks.contains { $0.id == askID && Self.fingerprint(of: $0) == fingerprint }
    }

    /// A short digest of everything the bar shows about an ask, plus its id and time, so the same
    /// request asked twice is still two asks. FNV-1a: stable across launches, not a secret.
    public static func fingerprint(of ask: Ask) -> String {
        let fields = [
            ask.id, String(ask.at.timeIntervalSince1970), ask.kind.rawValue, ask.agentID, ask.tool, ask.summary, ask.description,
            ask.target, ask.options.joined(separator: "\u{1E}"), ask.input, String(ask.questionCount), String(ask.multiSelect),
        ]
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in fields.joined(separator: "\u{1F}").utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(format: "%016llx", hash)
    }
}
