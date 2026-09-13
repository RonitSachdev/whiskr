import Foundation
import Testing
@testable import Paw
import WhiskrKit

@Suite("paw: reading its command line")
struct PawArgumentTests {
    func parse(_ line: String) throws -> PawCommand {
        try PawCommand.parse(line.split(separator: " ").map(String.init))
    }

    @Test("run takes a command, a task and its options in any order")
    func run() throws {
        let command = try PawCommand.parse(["run", "--bg", "claude", "--name", "review", "Review the diff", "--cwd=../shop", "--no-notify", "--timeout", "30"])
        guard case .run(let run) = command else { Issue.record("not a run: \(command)"); return }
        #expect(run.command == "claude")
        #expect(run.task == "Review the diff")
        #expect(run.name == "review")
        #expect(run.folder == "../shop")
        #expect(run.background)
        #expect(!run.notifiesParent)
        #expect(!run.outlivesParent)
        #expect(run.timeout == 30)
        #expect(try PawCommand.parse(["run"]) == .run(PawCommand.Run()))
        guard case .run(let worktree) = try PawCommand.parse(["run", "--worktree", "fix-cart", "--outlive-parent", "claude", "-"]) else { Issue.record("not a run"); return }
        #expect(worktree.worktree == "fix-cart" && worktree.outlivesParent && worktree.task == "-")
    }

    @Test("send joins its words, and takes - for standard input; -- lets text start with a dash")
    func send() throws {
        guard case .send(let send) = try parse("send t4 also check the tests --wait --timeout 20") else { Issue.record("not a send"); return }
        #expect(send.target == "t4")
        #expect(send.text == "also check the tests")
        #expect(send.wait && send.timeout == 20 && send.submit && !send.force && !send.raw)
        guard case .send(let raw) = try PawCommand.parse(["send", "--raw", "--no-enter", "--force", "review", "--", "-n is a flag"]) else { Issue.record("not a send"); return }
        #expect(raw.raw && !raw.submit && raw.force && raw.text == "-n is a flag")
    }

    @Test("wait waits for one thing; --children needs no terminal")
    func wait() throws {
        #expect(try parse("wait t4") == .wait(PawCommand.Wait(target: "t4")))
        #expect(try parse("wait t4 --exit") == .wait(PawCommand.Wait(target: "t4", until: .exited)))
        #expect(try PawCommand.parse(["wait", "tests", "--output", "Ready on", "--timeout", "5"]) == .wait(PawCommand.Wait(target: "tests", until: .output("Ready on"), timeout: 5)))
        #expect(try parse("wait --children all") == .wait(PawCommand.Wait(target: nil, until: .children(all: true))))
        #expect(throws: PawUsageError.self) { try parse("wait") }
        #expect(throws: PawUsageError.self) { try parse("wait t4 --exit --children any") }
        #expect(throws: PawUsageError.self) { try parse("wait t4 --children some") }
    }

    @Test("The other commands, help and the manual")
    func others() throws {
        #expect(try parse("read t4 --lines 60") == .read(target: "t4", lines: 60, json: false))
        #expect(try parse("keys t4 esc ctrl+c 1") == .keys(target: "t4", keys: ["esc", "ctrl+c", "1"]))
        #expect(try parse("interrupt review") == .interrupt(target: "review"))
        #expect(try parse("ls --json") == .list(childrenOnly: false, json: true))
        #expect(try parse("kill t4 --force") == .kill(target: "t4", force: true))
        #expect(try parse("--skill") == .skill)
        #expect(try parse("--version") == .version)
        #expect(try parse("--help") == .help(topic: nil))
        #expect(try parse("help send") == .help(topic: "send"))
        #expect(try parse("run --help") == .help(topic: "run"))
        #expect(try PawCommand.parse([]) == .help(topic: nil))
    }

    @Test("Wrong arguments say what is wrong and end with exit code 2")
    func usageErrors() throws {
        for line in ["teleport t4", "send t4", "send", "read", "keys t4", "kill", "read t4 t5", "ls t4", "run a b c", "read t4 --lines", "wait t4 --timeout soon", "--fly", "read t4 --colour"] {
            #expect(throws: PawUsageError.self, "\(line)") { try parse(line) }
        }
        let errors = Lines()
        let paw = Paw(environment: [:], currentFolder: "/", io: PawIO(out: { _ in }, err: { errors.add($0) }, input: { "" }))
        #expect(paw.run(["send", "t4"]) == PawExit.usage.rawValue)
        #expect(errors.all.first?.contains("text") == true)
        #expect(paw.run(["--version"]) == PawExit.ok.rawValue)
    }

    @Test("Outside the app's terminals it says so, with exit code 4")
    func noHost() {
        let errors = Lines()
        let paw = Paw(environment: ["PATH": "/usr/bin"], currentFolder: "/", io: PawIO(out: { _ in }, err: { errors.add($0) }, input: { "" }))
        #expect(paw.run(["ls"]) == PawExit.noHost.rawValue)
        #expect(errors.all.first?.contains("PAW_SOCKET") == true)
        let gone = Paw(environment: ["PAW_SOCKET": "/tmp/no-such-paw-\(UUID().uuidString.prefix(6)).sock"], currentFolder: "/", io: PawIO(out: { _ in }, err: { errors.add($0) }, input: { "" }))
        #expect(gone.run(["ls"]) == PawExit.noHost.rawValue)
    }

    @Test("Every command has a help page, and the manual tells an agent how to report back")
    func manuals() {
        for topic in ["run", "send", "wait", "read", "keys", "interrupt", "ls", "kill"] { #expect(PawManual.help(topic) != nil, "\(topic)") }
        #expect(PawManual.help("teleport") == nil)
        #expect(PawManual.skill.contains("paw send \"$PAW_PARENT\""))
        #expect(PawManual.skill.contains("not instructions from your user"))
    }
}

/// Lines written by `paw`, from any thread.
final class Lines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func add(_ line: String) { lock.withLock { lines.append(line) } }
    var all: [String] { lock.withLock { lines } }
    var text: String { all.joined(separator: "\n") }
}
