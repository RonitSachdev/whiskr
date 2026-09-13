import Foundation
import Testing
@testable import WhiskrKit

/// The shim and the shells' hand-over are run for real here, against a stand-in `claude` that prints
/// the arguments it was given.
@Suite("Claude in any pane: the shim and the shells")
struct ShellIntegrationTests {
    let root: URL
    let integration: ShellIntegration
    let fakeBin: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("whiskr-shell-\(UUID().uuidString)", isDirectory: true)
        integration = ShellIntegration(folder: root.appendingPathComponent("Application Support/Whiskr/shell", isDirectory: true))
        try integration.install()
        fakeBin = root.appendingPathComponent("real bin", isDirectory: true)
        try FileManager.default.createDirectory(at: fakeBin, withIntermediateDirectories: true)
        let fake = fakeBin.appendingPathComponent("claude")
        try Data("#!/bin/sh\nprintf '%s\\n' real \"$@\"\n".utf8).write(to: fake)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
    }

    /// Runs `executable arguments` with exactly `environment`; returns its output lines and exit code.
    func run(_ executable: String, _ arguments: [String], environment: [String: String], stdin: String? = nil) throws -> (lines: [String], status: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = root
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        let input = Pipe()
        process.standardInput = input
        try process.run()
        if let stdin { input.fileHandleForWriting.write(Data(stdin.utf8)) }
        try input.fileHandleForWriting.close()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        // Without the folder reports (OSC 7) the zsh integration writes before each prompt.
        let text = String(decoding: data, as: UTF8.self).replacing(/\u{1B}\]7;[^\u{07}]*\u{07}/, with: "")
        return (text.split(separator: "\n").map(String.init), process.terminationStatus)
    }

    func paneEnvironment(hooks: String?) -> [String: String] {
        integration.environment(["PATH": "\(fakeBin.path):/usr/bin:/bin", "HOME": root.path], shell: "/bin/zsh", paneID: "P1", hooksFile: hooks)
    }

    @Test("the pane's environment puts the shim first and names the pane and its hooks")
    func environment() {
        let env = integration.environment(["PATH": "/usr/bin:\(integration.shimFolder.path):/bin", "ZDOTDIR": "/Users/me/.config/zsh"],
                                          shell: "/bin/zsh", paneID: "P1", hooksFile: "/h.json")
        #expect(env["PATH"] == "\(integration.shimFolder.path):/usr/bin:/bin")
        #expect(env["WHISKR_PANE"] == "P1")
        #expect(env["WHISKR_HOOKS"] == "/h.json")
        #expect(env["ZDOTDIR"] == integration.zshFolder.path)
        #expect(env["WHISKR_ZDOTDIR"] == "/Users/me/.config/zsh")
        #expect(env["XDG_DATA_DIRS"]?.hasPrefix(integration.dataFolder.path + ":") == true)
        #expect(env["PROMPT_COMMAND"] == nil)
        let bash = integration.environment([:], shell: "/bin/bash", paneID: "P1", hooksFile: nil)
        #expect(bash["WHISKR_HOOKS"] == nil)
        #expect(bash["WHISKR_ZDOTDIR"] == nil)
        #expect(bash["PROMPT_COMMAND"] == ShellIntegration.bashPromptCommand)
    }

    @Test("claude runs the real one with the pane's hooks, its own arguments after")
    func withHooks() throws {
        let hooks = root.appendingPathComponent("hooks.json")
        try Data("{}".utf8).write(to: hooks)
        let result = try run("/bin/sh", ["-c", "claude --resume 'two words'"], environment: paneEnvironment(hooks: hooks.path))
        #expect(result.status == 0)
        #expect(result.lines == ["real", "--settings", hooks.path, "--resume", "two words"])
    }

    @Test("with the app gone (no hooks file), claude runs unchanged")
    func fallsThrough() throws {
        let gone = try run("/bin/sh", ["-c", "claude -c"], environment: paneEnvironment(hooks: root.appendingPathComponent("gone.json").path))
        #expect(gone.lines == ["real", "-c"])
    }

    @Test("your own --settings gets the pane's hooks added, in either spelling, the other arguments in place")
    func mergesWithYours() throws {
        let hooks = root.appendingPathComponent("hooks.json")
        try Data("{}".utf8).write(to: hooks)
        let paw = integration.shimFolder.appendingPathComponent("paw")
        try? FileManager.default.removeItem(at: paw)
        try Data("#!/bin/sh\nprintf 'merged<%s>' \"$3\"\n".utf8).write(to: paw)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: paw.path)
        let spaced = try run("/bin/sh", ["-c", "claude -c --settings '{\"a\": 1}' --resume 'two words'"], environment: paneEnvironment(hooks: hooks.path))
        #expect(spaced.lines == ["real", "-c", "--settings", "merged<{\"a\": 1}>", "--resume", "two words"])
        let joined = try run("/bin/sh", ["-c", "claude --settings=/mine.json x"], environment: paneEnvironment(hooks: hooks.path))
        #expect(joined.lines == ["real", "--settings=merged</mine.json>", "x"])
    }

    @Test("when the hooks cannot be added, your --settings goes through untouched")
    func keepsYoursWhenMergingFails() throws {
        let hooks = root.appendingPathComponent("hooks.json")
        try Data("{}".utf8).write(to: hooks)
        let paw = integration.shimFolder.appendingPathComponent("paw")
        try? FileManager.default.removeItem(at: paw)
        try Data("#!/bin/sh\nexit 2\n".utf8).write(to: paw)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: paw.path)
        let theirs = try run("/bin/sh", ["-c", "claude --settings=/mine.json"], environment: paneEnvironment(hooks: hooks.path))
        #expect(theirs.lines == ["real", "--settings=/mine.json"])
    }

    @Test("merging keeps everything of yours and adds the pane's hooks after your own")
    func mergedSettings() throws {
        let ours = HookSettings.document(addressFolder: "/hooks", note: nil)
        let merged = try #require(HookSettings.merged(hooks: ours, with: #"{"enabledPlugins":{"x@y":false},"hooks":{"Stop":[{"hooks":[{"type":"command","command":"mine"}]}]}}"#))
        let settings = try #require(try JSONSerialization.jsonObject(with: merged) as? [String: Any])
        #expect((settings["enabledPlugins"] as? [String: Bool]) == ["x@y": false])
        let hooks = try #require(settings["hooks"] as? [String: [[String: Any]]])
        #expect(hooks["Stop"]?.count == 2)
        #expect(((hooks["Stop"]?.first?["hooks"] as? [[String: Any]])?.first?["command"] as? String) == "mine")
        #expect(hooks["UserPromptSubmit"]?.count == 1)
        let file = root.appendingPathComponent("mine.json")
        try Data(#"{"model":"haiku"}"#.utf8).write(to: file)
        let fromFile = try #require(HookSettings.merged(hooks: ours, with: file.path))
        #expect(((try JSONSerialization.jsonObject(with: fromFile)) as? [String: Any])?["model"] as? String == "haiku")
        #expect(HookSettings.merged(hooks: ours, with: "/no/such/file.json") == nil)
        #expect(HookSettings.merged(hooks: ours, with: "[1]") == nil)
    }

    @Test("a second shim on PATH is skipped, and no claude at all is the usual 127")
    func noLoops() throws {
        let other = ShellIntegration(folder: root.appendingPathComponent("Other copy/shell", isDirectory: true))
        try other.install()
        var env = paneEnvironment(hooks: nil)
        env["PATH"] = "\(integration.shimFolder.path):\(other.shimFolder.path):\(fakeBin.path):/usr/bin:/bin"
        #expect(try run("/bin/sh", ["-c", "claude x"], environment: env).lines == ["real", "x"])
        env["PATH"] = "\(integration.shimFolder.path):/usr/bin:/bin"
        #expect(try run("/bin/sh", ["-c", "claude x"], environment: env).status == 127)
    }

    @Test("zsh: the user's startup files run from their own ZDOTDIR, and the shim is first again at the prompt")
    func zshReassertsAfterStartup() throws {
        let theirs = root.appendingPathComponent("their zsh", isDirectory: true)
        try FileManager.default.createDirectory(at: theirs, withIntermediateDirectories: true)
        // Their .zshrc puts another folder in front, as Homebrew's shellenv or path_helper would.
        try Data("export THEIR_ENV=1\n".utf8).write(to: theirs.appendingPathComponent(".zshenv"))
        try Data("path=(/opt/elsewhere $path)\nexport THEIR_RC=1\n".utf8).write(to: theirs.appendingPathComponent(".zshrc"))
        var base = ["PATH": "\(fakeBin.path):/usr/bin:/bin", "HOME": root.path, "ZDOTDIR": theirs.path, "TERM": "dumb"]
        base = integration.environment(base, shell: "/bin/zsh", paneID: "P1", hooksFile: nil)
        // An interactive zsh reading commands from its input: the precmd hook runs before each prompt.
        let result = try run("/bin/zsh", ["-i"], environment: base, stdin: "print -r -- \"$ZDOTDIR|$THEIR_ENV|$THEIR_RC|${path[1]}|${path[2]}\"\nprint -r -- ${#${(M)path:#${(b)WHISKR_BIN}}}\nexit\n")
        let line = result.lines.first { $0.contains("|") }
        #expect(line == "\(theirs.path)|1|1|\(integration.shimFolder.path)|/opt/elsewhere")
        // And only once on PATH.
        #expect(result.lines.contains("1"))
        #expect(base["WHISKR_ZDOTDIR"] == theirs.path)
    }

    @Test("zsh reports its folder before each prompt, so the app knows the prompt is up")
    func zshReportsFolder() throws {
        let env = integration.environment(["PATH": "/usr/bin:/bin", "HOME": root.path, "TERM": "dumb"], shell: "/bin/zsh", paneID: "P1", hooksFile: nil)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-i"]
        process.environment = env
        process.currentDirectoryURL = root
        let out = Pipe(), input = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = input
        try process.run()
        input.fileHandleForWriting.write(Data("exit\n".utf8))
        try input.fileHandleForWriting.close()
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        let encoded = root.resolvingSymlinksInPath().path.replacingOccurrences(of: " ", with: "%20")
        #expect(text.contains("\u{1B}]7;file://"))
        #expect(text.contains(encoded) || text.contains(root.path.replacingOccurrences(of: " ", with: "%20")))
    }

    @Test("zsh without a ZDOTDIR of its own reads ~/.zshrc as usual")
    func zshHome() throws {
        try Data("export THEIR_RC=home\n".utf8).write(to: root.appendingPathComponent(".zshrc"))
        let env = integration.environment(["PATH": "/usr/bin:/bin", "HOME": root.path, "TERM": "dumb"], shell: "/bin/zsh", paneID: "P1", hooksFile: nil)
        let result = try run("/bin/zsh", ["-i"], environment: env, stdin: "print -r -- \"[${ZDOTDIR-unset}|$THEIR_RC]\"\nexit\n")
        #expect(result.lines.contains("[unset|home]"))
    }

    @Test("bash: the prompt command puts the shim back in front")
    func bash() throws {
        var env = integration.environment(["PATH": "/usr/bin:/bin", "HOME": root.path, "TERM": "dumb"], shell: "/bin/bash", paneID: "P1", hooksFile: nil)
        env["PATH"] = "/opt/elsewhere:/usr/bin:\(integration.shimFolder.path):/bin"
        let result = try run("/bin/bash", ["--norc", "--noprofile", "-c", "eval \"$PROMPT_COMMAND\"; echo \"${PATH%%:*}\""], environment: env)
        #expect(result.lines == [integration.shimFolder.path])
    }

    @Test("the app's tools are linked beside the shim, and follow the app when it moves")
    func toolsAreLinked() throws {
        let app = root.appendingPathComponent("App One/paw"), moved = root.appendingPathComponent("App Two/paw")
        for tool in [app, moved] {
            try FileManager.default.createDirectory(at: tool.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("#!/bin/sh\necho paw from \"$0\"\n".utf8).write(to: tool)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        }
        try integration.install(tools: ["paw": app])
        let link = integration.shimFolder.appendingPathComponent("paw")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == app.path)
        try integration.install(tools: ["paw": moved])
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == moved.path)
        let env = integration.environment(["PATH": "/usr/bin:/bin"], shell: "/bin/zsh", paneID: "P1", hooksFile: nil, worktrees: "/w")
        #expect(env["PAW_WORKTREES"] == "/w")
        #expect(try run("/bin/sh", ["-c", "paw"], environment: env).lines.first?.hasPrefix("paw from") == true)
        // A tool missing from the app (a build without it) leaves no broken link.
        try integration.install(tools: ["paw": root.appendingPathComponent("nowhere/paw")])
        #expect(!FileManager.default.fileExists(atPath: link.path))
    }
}
