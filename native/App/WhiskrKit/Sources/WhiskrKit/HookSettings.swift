import Foundation

/// The settings our `claude` shim passes to Claude Code in a pane (`claude --settings <file>`). Claude
/// Code merges them with the account's own settings, so the user's hooks still run and nothing in any
/// `~/.claude*/settings.json` is touched.
///
/// The hooks are command hooks that post the event to the app's listener with `curl`, not HTTP hooks:
/// an organisation's managed settings can restrict HTTP hooks to listed URLs (`allowedHttpHookUrls`),
/// which refuses the app's local listener (seen with a Claude Team account), while command hooks run.
/// They also let SessionStart through, which runs only command hooks, so a session reports from the
/// moment it starts. The listener's answer is discarded: these hooks only report, never decide.
public enum HookSettings {
    /// Every event whose payload the state model uses. Claude Code skips names it does not know. Left
    /// out on purpose:
    ///   Setup           fires only for --init and --maintenance runs.
    ///   PreModelSwitch  a hook that answers late cancels the switch; PostModelSwitch says the same after.
    ///   WorktreeCreate  a hook here replaces git's own worktree creation, so an empty answer would break it.
    ///   WorktreeRemove  fires only for worktrees such a hook created.
    ///   FileChanged     watches only the file names a hook lists, so there is nothing general to hear.
    public static let events = [
        "SessionStart", "SessionEnd", "UserPromptSubmit", "UserPromptExpansion", "MessageDisplay",
        "PreToolUse", "PostToolUse", "PostToolUseFailure", "PostToolBatch",
        "PermissionRequest", "PermissionDenied", "Notification", "Elicitation", "ElicitationResult",
        "SubagentStart", "SubagentStop", "TeammateIdle", "TaskCreated", "TaskCompleted",
        "Stop", "StopFailure", "PreCompact", "PostCompact", "PostModelSwitch",
        "InstructionsLoaded", "ConfigChange", "CwdChanged", "DirectoryAdded",
    ]

    /// Claude Code waits for each hook. The listener answers at once; the short timeout only bounds the
    /// wait if the app ever stops answering (it is refused instantly once the app has quit).
    public static let timeoutSeconds = 2

    /// The command that posts a hook's event (its standard input) to the app's listener, saying nothing
    /// back. The listener's address is read, each time, from the file named after the pane in
    /// `addressFolder` (`<pane id>.url`; the pane is the `WHISKR_PANE` the terminal was started
    /// with), not written into the command: Claude Code reads its settings once, and a session outlives
    /// the app (it runs in the session host), so the app writes its new port and secret there at each
    /// launch and the session reports again. Every pane shares this one command, so a terminal the host
    /// starts for an agent (`paw run`) reports as its own pane with no file written for it first. While
    /// the app is not running the file is gone and the hook does nothing. It always succeeds: a hook that
    /// fails would show as an error in Claude Code.
    public static func command(addressFolder: String) -> String {
        let post = "/usr/bin/curl -sS -m \(timeoutSeconds) -o /dev/null -X POST -H \"Content-Type: application/json\" --data-binary @- \"$u\""
        return "/bin/sh -c 'u=$(/bin/cat \"$1/$\(ShellIntegration.Key.pane).url\" 2>/dev/null) && \(post) 2>/dev/null; :' sh \(ClaudeResume.shellQuoted(addressFolder))"
    }

    /// Prints `note` for Claude to read at the start of a session (a SessionStart hook's output is added
    /// to what it knows), when `paw` is there to be used.
    public static func noteCommand(_ note: String) -> String {
        "/bin/sh -c 'command -v paw >/dev/null 2>&1 && printf \"%s\\n\" \"$1\"; :' sh \(ClaudeResume.shellQuoted(note))"
    }

    /// The one line Claude Code reads at the start of every session in the app's terminals: that it can
    /// start and steer helper terminals. Kept to a sentence, so it costs nearly nothing.
    public static let pawNote = "In this terminal you can start and steer helper terminals (other Claude Code sessions, long commands) with the `paw` command; run `paw --skill` before using it."

    /// The settings document every pane's `claude` gets: one command hook per event, all posting to the
    /// address kept for the pane in `addressFolder`, and at session start the note about `paw`.
    public static func document(addressFolder: String, note: String? = pawNote) -> Data {
        let hook: JSONValue = .object([
            "type": .string("command"),
            "command": .string(command(addressFolder: addressFolder)),
            "timeout": .number(Double(timeoutSeconds + 1)),
        ])
        var hooks: [String: JSONValue] = [:]
        for event in events {
            hooks[event] = .array([.object(["hooks": .array([hook])])])
        }
        if let note {
            let tell: JSONValue = .object(["type": .string("command"), "command": .string(noteCommand(note)), "timeout": .number(Double(timeoutSeconds + 1))])
            hooks["SessionStart"] = .array([.object(["hooks": .array([hook])]), .object(["hooks": .array([tell])])])
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        // Encoding a tree of plain values cannot fail.
        return (try? encoder.encode(JSONValue.object(["hooks": .object(hooks)]))) ?? Data()
    }
}
