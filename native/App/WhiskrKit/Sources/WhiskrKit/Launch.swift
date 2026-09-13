import Foundation

/// What to run in a pane's pseudo-terminal: the program, its arguments, its argv[0], where and with
/// which environment.
public struct ProcessSpec: Sendable, Equatable {
    public var executable: String
    public var arguments: [String]
    /// argv[0]. A leading "-" makes a shell a login shell, as Terminal does.
    public var argv0: String
    public var environment: [String: String]
    public var directory: String

    public init(executable: String, arguments: [String], argv0: String, environment: [String: String], directory: String) {
        self.executable = executable
        self.arguments = arguments
        self.argv0 = argv0
        self.environment = environment
        self.directory = directory
    }
}

public enum Launch {
    /// The user's interactive login shell, as a terminal opens it.
    public static func shell(_ shell: String, directory: String, environment: [String: String]) -> ProcessSpec {
        ProcessSpec(executable: shell, arguments: [], argv0: "-" + Describe.basename(shell), environment: environment, directory: directory)
    }

    /// Variables the app may have inherited (when started from a terminal, or from inside a Claude
    /// session) that would mislead a program in our terminal: another terminal's identity, or a parent
    /// Claude session's.
    static let inheritedNoise = ["CLAUDECODE", "CLAUDE_PID", "CLAUDE_EFFORT", "CLAUDE_CONFIG_DIR", "AI_AGENT",
                                  "TERM", "COLORTERM", "TERM_PROGRAM", "TERM_PROGRAM_VERSION", "TERM_SESSION_ID",
                                  "LC_TERMINAL", "LC_TERMINAL_VERSION", "TMUX", "TMUX_PANE", "STY",
                                  "PWD", "OLDPWD", "SHLVL", "_"]
    static let inheritedNoisePrefixes = ["CLAUDE_CODE_", "ITERM_", "KITTY_", "WEZTERM_", "GHOSTTY_", "VSCODE_", "__CF", "PAW_"]

    /// `environment` without what another terminal or a Claude session left in it (`inheritedNoise`).
    public static func withoutNoise(_ environment: [String: String]) -> [String: String] {
        environment.filter { key, _ in !inheritedNoise.contains(key) && !inheritedNoisePrefixes.contains { key.hasPrefix($0) } }
    }

    /// The environment for a pane's process: the app's own, cleaned of noise, plus what a terminal
    /// sets (`TERM`, `COLORTERM`, our `TERM_PROGRAM`) and a UTF-8 locale when there is none. The
    /// account (`CLAUDE_CONFIG_DIR`) is never set here: whatever the user's own shell setup chooses
    /// wins, as in any other terminal.
    public static func environment(
        base: [String: String],
        shell: String,
        appVersion: String,
        localeIdentifier: String,
        localeExists: (String) -> Bool
    ) -> [String: String] {
        var environment = withoutNoise(base)
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        environment["TERM_PROGRAM"] = "Whiskr"
        environment["TERM_PROGRAM_VERSION"] = appVersion
        environment["SHELL"] = shell
        let hasUTF8 = [environment["LC_ALL"], environment["LC_CTYPE"], environment["LANG"]]
            .compactMap { $0 }.first { !$0.isEmpty }?.uppercased().contains("UTF-8") ?? false
        if !hasUTF8 {
            let candidate = localeIdentifier.split(separator: "@").first.map(String.init) ?? ""
            environment["LANG"] = localeExists("\(candidate).UTF-8") ? "\(candidate).UTF-8" : "en_US.UTF-8"
            if let ctype = environment["LC_CTYPE"], !ctype.uppercased().contains("UTF-8") { environment.removeValue(forKey: "LC_CTYPE") }
            if environment["LC_ALL"] != nil { environment.removeValue(forKey: "LC_ALL") }
        }
        return environment
    }
}
