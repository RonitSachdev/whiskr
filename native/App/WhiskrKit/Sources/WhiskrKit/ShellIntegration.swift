import Foundation

/// Makes every pane's shell hook-aware without touching the user's own files: inside our terminals,
/// `claude` resolves first to a small shim that runs the real Claude Code with this pane's hooks
/// (`--settings <file>`), so a session is seen however it was started (typed, `--resume`, a script).
///
/// The shim's folder goes first on `PATH` in the pane's environment. Shell startup files often
/// reorder `PATH` (macOS's `path_helper`, Homebrew's shellenv, version managers), so each shell puts
/// it back in front before every prompt:
///   - zsh: `ZDOTDIR` points at our folder, whose `.zshenv` restores the user's own `ZDOTDIR`, runs
///     their `.zshenv`, and adds a `precmd` hook; zsh then reads the rest of their startup files from
///     their own folder as usual. The hook also reports the folder (OSC 7), which tells the app the
///     prompt is up.
///   - fish: our folder is put first on `XDG_DATA_DIRS`, whose `fish/vendor_conf.d` script restores it
///     and adds a `fish_prompt` handler.
///   - bash (minimal): a `PROMPT_COMMAND`, which a `.bashrc` that sets its own replaces.
/// The shim falls through to the real `claude` unchanged when the pane's hooks file is gone (the app
/// has quit). When the user passes `--settings` themselves (a file or inline JSON, as a shell function
/// of their own may), the pane's hooks are added to theirs (`HookSettings.merged`, through `paw`), since
/// Claude Code takes only one.
///
/// Beside the shim are the app's own command-line tools (`paw`), as links to the copies inside the app.
public struct ShellIntegration: Sendable, Equatable {
    /// Where the integration's files live (inside the app's support folder).
    public let folder: URL

    public init(folder: URL) {
        self.folder = folder
    }

    public var shimFolder: URL { folder.appendingPathComponent("bin", isDirectory: true) }
    public var zshFolder: URL { folder.appendingPathComponent("zsh", isDirectory: true) }
    public var dataFolder: URL { folder.appendingPathComponent("share", isDirectory: true) }

    /// Environment variables the integration sets in a pane.
    public enum Key {
        public static let bin = "WHISKR_BIN"
        public static let pane = "WHISKR_PANE"
        public static let hooks = "WHISKR_HOOKS"
        public static let userZDOTDIR = "WHISKR_ZDOTDIR"
        public static let userDataDirs = "WHISKR_XDG_DATA_DIRS"
        /// Where `paw run --worktree` makes checkouts (Settings › General).
        public static let worktrees = "PAW_WORKTREES"
    }

    /// A file beside the shim, so one shim never runs another (two copies of the app, say): a folder
    /// that has it is skipped.
    static let marker = ".whiskr-shim"

    /// Writes (or rewrites) the files, and links each of `tools` (a name and the executable inside the
    /// app) into the shim's folder. Safe to call at every launch: the app may have moved since.
    public func install(tools: [String: URL] = [:]) throws {
        let files = FileManager.default
        for folder in [shimFolder, zshFolder, dataFolder.appendingPathComponent("fish/vendor_conf.d", isDirectory: true)] {
            try files.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let shim = shimFolder.appendingPathComponent("claude")
        try Data(Self.shim.utf8).write(to: shim, options: .atomic)
        try files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shim.path)
        try Data().write(to: shimFolder.appendingPathComponent(Self.marker), options: .atomic)
        try Data(Self.zshenv.utf8).write(to: zshFolder.appendingPathComponent(".zshenv"), options: .atomic)
        try Data(Self.fish.utf8).write(to: dataFolder.appendingPathComponent("fish/vendor_conf.d/whiskr.fish"), options: .atomic)
        for (name, executable) in tools {
            let link = shimFolder.appendingPathComponent(name)
            if (try? files.destinationOfSymbolicLink(atPath: link.path)) == executable.path { continue }
            try? files.removeItem(at: link)
            guard files.isExecutableFile(atPath: executable.path) else { continue }
            try files.createSymbolicLink(at: link, withDestinationURL: executable)
        }
    }

    /// `base` with the integration added for a pane: the shim first on `PATH`, the pane's id and hooks
    /// file, and the shell-specific hand-over described above. `hooksFile` is nil when the app's
    /// listener is not running; the shim then runs Claude Code unchanged.
    public func environment(_ base: [String: String], shell: String, paneID: String, hooksFile: String?, worktrees: String? = nil) -> [String: String] {
        var environment = base
        let bin = shimFolder.path
        let rest = (base["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin").split(separator: ":").map(String.init).filter { $0 != bin && !$0.isEmpty }
        environment["PATH"] = ([bin] + rest).joined(separator: ":")
        environment[Key.bin] = bin
        environment[Key.pane] = paneID
        if let hooksFile { environment[Key.hooks] = hooksFile } else { environment.removeValue(forKey: Key.hooks) }
        if let worktrees { environment[Key.worktrees] = worktrees } else { environment.removeValue(forKey: Key.worktrees) }

        // zsh: our .zshenv first; it hands back to the user's own ZDOTDIR (or none).
        environment.removeValue(forKey: Key.userZDOTDIR)
        if let theirs = base["ZDOTDIR"] { environment[Key.userZDOTDIR] = theirs }
        environment["ZDOTDIR"] = zshFolder.path

        // fish: our vendor_conf.d first; it puts XDG_DATA_DIRS back.
        environment.removeValue(forKey: Key.userDataDirs)
        if let theirs = base["XDG_DATA_DIRS"] { environment[Key.userDataDirs] = theirs }
        environment["XDG_DATA_DIRS"] = ([dataFolder.path] + [base["XDG_DATA_DIRS"] ?? "/usr/local/share:/usr/share"]).joined(separator: ":")

        // bash, minimally: before each prompt (a .bashrc that sets PROMPT_COMMAND itself replaces this).
        if Describe.basename(shell) == "bash" {
            environment["PROMPT_COMMAND"] = [Self.bashPromptCommand, base["PROMPT_COMMAND"]].compactMap { $0 }.joined(separator: "; ")
        }
        return environment
    }

    // MARK: The files

    /// POSIX sh, so it runs the same under any login shell. Finds the first `claude` on PATH that is not
    /// a shim, then runs it with this pane's hooks when the app is listening.
    static let shim = """
    #!/bin/sh
    # Whiskr: inside its terminals, `claude` runs the real Claude Code with this pane's hooks,
    # so the app sees the session however it was started. Without them it runs Claude Code unchanged.
    set -f
    real=
    saved_ifs=$IFS
    IFS=:
    for dir in $PATH; do
      [ -n "$dir" ] || continue
      [ -e "$dir/\(marker)" ] && continue
      candidate="$dir/claude"
      [ -f "$candidate" ] && [ -x "$candidate" ] || continue
      real=$candidate
      break
    done
    IFS=$saved_ifs
    set +f
    if [ -z "$real" ]; then
      echo "claude: command not found" >&2
      exit 127
    fi
    hooks=$\(Key.hooks)
    if [ -n "$hooks" ] && [ -r "$hooks" ]; then
      own=
      for arg in "$@"; do
        case $arg in
          --settings|--settings=*) own=1 ;;
        esac
      done
      [ -n "$own" ] || exec "$real" --settings "$hooks" "$@"
      # Claude Code takes one --settings: yours gets the pane's hooks added to it (and stays as it is
      # if that cannot be done).
      left=$#
      while [ "$left" -gt 0 ]; do
        arg=$1
        shift
        left=$((left - 1))
        case $arg in
          --settings)
            if [ "$left" -gt 0 ]; then
              value=$1
              shift
              left=$((left - 1))
              merged=$("$\(Key.bin)/paw" merge-settings "$hooks" "$value" 2>/dev/null) && [ -n "$merged" ] && value=$merged
              set -- "$@" --settings "$value"
            else
              set -- "$@" "$arg"
            fi ;;
          --settings=*)
            value=${arg#--settings=}
            merged=$("$\(Key.bin)/paw" merge-settings "$hooks" "$value" 2>/dev/null) && [ -n "$merged" ] && value=$merged
            set -- "$@" "--settings=$value" ;;
          *) set -- "$@" "$arg" ;;
        esac
      done
    fi
    exec "$real" "$@"

    """

    static let zshenv = """
    # Whiskr: hands zsh back to your own startup files, then keeps the app's `claude` shim
    # first on PATH before every prompt. Nothing of yours is changed.
    if [[ -n "${\(Key.userZDOTDIR)+set}" ]]; then
      ZDOTDIR=$\(Key.userZDOTDIR)
      unset \(Key.userZDOTDIR)
    else
      unset ZDOTDIR
    fi
    [[ -r "${ZDOTDIR:-$HOME}/.zshenv" ]] && builtin source "${ZDOTDIR:-$HOME}/.zshenv"
    if [[ -o interactive && -n "$\(Key.bin)" ]]; then
      __whiskr_precmd() {
        [[ "${path[1]}" == "$\(Key.bin)" ]] || path=("$\(Key.bin)" ${path:#${(b)\(Key.bin)}})
        # Where the shell is, and that its prompt is up (OSC 7, as Terminal uses it).
        builtin printf '\\e]7;file://%s%s\\a' "${HOST}" "${${PWD//\\%/%25}// /%20}"
      }
      typeset -ga precmd_functions
      precmd_functions+=(__whiskr_precmd)
    fi

    """

    static let fish = """
    # Whiskr: keeps the app's `claude` shim first on PATH before every prompt.
    if set -q \(Key.userDataDirs)
        set -gx XDG_DATA_DIRS $\(Key.userDataDirs)
        set -e \(Key.userDataDirs)
    else
        set -e XDG_DATA_DIRS
    end
    function __whiskr_path --on-event fish_prompt
        if set -q \(Key.bin); and test "$PATH[1]" != "$\(Key.bin)"
            set -gx PATH $\(Key.bin) (string match -v -- $\(Key.bin) $PATH)
        end
    end

    """

    static let bashPromptCommand = #"case "$PATH" in "$WHISKR_BIN":*) ;; *) PATH="$WHISKR_BIN:${PATH//"$WHISKR_BIN":/}" ;; esac"#
}
