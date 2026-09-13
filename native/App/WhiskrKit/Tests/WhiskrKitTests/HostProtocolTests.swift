import Foundation
import Testing
@testable import WhiskrKit

@Suite("Session host: frames, messages and versions")
struct HostProtocolTests {
    let terminal = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

    func decodeAll(_ bytes: Data, pieces: Int) throws -> [HostFrame] {
        var decoder = HostFrameDecoder()
        var frames: [HostFrame] = []
        var index = bytes.startIndex
        while index < bytes.endIndex {
            let end = min(index + pieces, bytes.endIndex)
            decoder.append(bytes.subdata(in: index..<end))
            while let frame = try decoder.next() { frames.append(frame) }
            index = end
        }
        return frames
    }

    @Test("Frames come back whole however the bytes are cut")
    func framesSurviveAnySplit() throws {
        let frames: [HostFrame] = [
            .message(Data(#"{"id":1,"op":"list"}"#.utf8)),
            .output(terminal: terminal, Data("hello \u{1B}[31mred\u{1B}[0m\r\n".utf8)),
            .input(terminal: terminal, Data([0x03])),
            .output(terminal: terminal, Data()),
            .output(terminal: terminal, Data(repeating: 0x41, count: 300_000)),
        ]
        let stream = frames.reduce(into: Data()) { $0.append($1.encoded) }
        for pieces in [1, 2, 3, 7, 4096, stream.count] where pieces > 1 || stream.count < 400_000 {
            #expect(try decodeAll(stream, pieces: pieces) == frames)
        }
        #expect(try decodeAll(stream.prefix(2000), pieces: 1).count == 4)
    }

    @Test("A frame of a kind from a newer peer is passed over; an absurd length ends the connection")
    func unknownAndOversizedFrames() throws {
        var stream = Data([0, 0, 0, 3, 99, 1, 2])
        stream.append(HostFrame.input(terminal: terminal, Data("x".utf8)).encoded)
        #expect(try decodeAll(stream, pieces: 5) == [.input(terminal: terminal, Data("x".utf8))])

        var decoder = HostFrameDecoder()
        decoder.append(Data([0x7F, 0, 0, 0, 1]))
        #expect(throws: HostFramingError.tooLarge(0x7F00_0000)) { try decoder.next() }
        var empty = HostFrameDecoder()
        empty.append(Data([0, 0, 0, 0]))
        #expect(throws: HostFramingError.empty) { try empty.next() }
    }

    @Test("Every request and answer survives the wire")
    func messagesRoundTrip() throws {
        let size = TerminalSize(columns: 120, rows: 40, pixelWidth: 1920, pixelHeight: 1280)
        let spec = TerminalSpec(terminal: terminal, process: Launch.shell("/bin/zsh", directory: "/tmp", environment: ["TERM": "xterm-256color"]), size: size)
        let requests: [HostRequest] = [
            .hello(HostProtocol.current, client: "app"), .create(spec), .attach(terminal: terminal), .detach(terminal: terminal),
            .resize(terminal: terminal, size), .redraw(terminal: terminal), .signal(terminal: terminal, 2), .close(terminal: terminal, after: 10),
            .keep(terminal: terminal), .list, .shutdown,
        ]
        for (index, request) in requests.enumerated() {
            let call = HostCall(id: index + 1, request: request)
            #expect(try JSONDecoder().decode(HostCall.self, from: JSONEncoder().encode(call)) == call)
        }
        let status = TerminalStatus(foreground: ForegroundProcess(pid: 42, name: "claude", executable: "/usr/local/bin/claude", arguments: ["claude", "--resume"]), folder: "/tmp")
        let info = TerminalInfo(id: terminal, pid: 41, size: size, status: status, exited: true, exitCode: 3, closing: true)
        let messages: [HostMessage] = [
            .reply(id: 1, .hello(HostInfo(version: 1, oldest: 1, build: "0.1.0", pid: 7, terminals: 2))),
            .reply(id: 2, .created(info)), .reply(id: 3, .attached(info, replay: 4096, truncated: true)), .reply(id: 4, .list([info])),
            .reply(id: 5, .done), .reply(id: 6, .failed(HostFailure(.noSuchTerminal, "gone"))),
            .event(.status(terminal: terminal, status)), .event(.exited(terminal: terminal, exitCode: nil)), .event(.exited(terminal: terminal, exitCode: 0)),
        ]
        for message in messages {
            #expect(try JSONDecoder().decode(HostMessage.self, from: JSONEncoder().encode(message)) == message)
        }
    }

    @Test("hello keeps its shape for good; what a newer peer says that we do not know is not fatal")
    func helloIsStableAndUnknownsAreTolerated() throws {
        let hello = try JSONDecoder().decode(HostCall.self, from: Data(#"{"id":1,"op":"hello","version":7,"oldest":5,"client":"cli","later":true}"#.utf8))
        #expect(hello == HostCall(id: 1, request: .hello(HostVersion(version: 7, oldest: 5), client: "cli")))
        let answer = try JSONDecoder().decode(HostMessage.self, from: Data(#"{"re":1,"kind":"hello","host":{"version":7,"oldest":5,"build":"9.0","pid":12,"terminals":3,"later":1}}"#.utf8))
        #expect(answer == .reply(id: 1, .hello(HostInfo(version: 7, oldest: 5, build: "9.0", pid: 12, terminals: 3))))

        let unknown = try JSONDecoder().decode(HostCall.self, from: Data(#"{"id":9,"op":"teleport","terminal":"x"}"#.utf8))
        #expect(unknown.request == .unknown("teleport"))
        #expect(try JSONDecoder().decode(HostMessage.self, from: Data(#"{"event":"weather","rain":true}"#.utf8)) == .event(.unknown("weather")))
        guard case .reply(4, .failed(let failure)) = try JSONDecoder().decode(HostMessage.self, from: Data(#"{"re":4,"kind":"hologram"}"#.utf8)) else {
            Issue.record("an unknown answer should read as a failure")
            return
        }
        #expect(failure.code == .unknownRequest)
    }

    @Test("Two builds talk when each is at least as new as the other's oldest")
    func compatibility() {
        func check(_ client: (Int, Int), _ host: (Int, Int)) -> HostCompatibility {
            HostProtocol.compatibility(client: HostVersion(version: client.0, oldest: client.1), host: HostVersion(version: host.0, oldest: host.1))
        }
        #expect(check((1, 1), (1, 1)) == .compatible)
        // A newer app that still speaks the running host's version keeps using it.
        #expect(check((3, 1), (1, 1)) == .compatible)
        #expect(check((3, 2), (2, 1)) == .compatible)
        // An older app and a newer host that still speaks the app's version.
        #expect(check((1, 1), (3, 1)) == .compatible)
        #expect(check((3, 2), (1, 1)) == .hostTooOld)
        #expect(check((1, 1), (3, 2)) == .hostTooNew)
    }
}

@Suite("Session host: kept output")
struct ReplayBufferTests {
    @Test("Under its capacity everything comes back, in order")
    func keepsEverythingThatFits() {
        var buffer = ReplayBuffer(capacity: 1000)
        buffer.append(Data("one\r\n".utf8))
        buffer.append(Data())
        buffer.append(Data("two\r\n".utf8))
        #expect(buffer.replay == Data("one\r\ntwo\r\n".utf8))
        #expect(!buffer.truncated)
        #expect(buffer.count == 10)
    }

    @Test("Past its capacity the oldest goes, and what is left starts on a fresh line")
    func dropsTheOldestAtALineBreak() {
        var buffer = ReplayBuffer(capacity: 64)
        for line in 0..<100 { buffer.append(Data("line \(line) \u{1B}[32mgreen\u{1B}[0m\r\n".utf8)) }
        let text = String(decoding: buffer.replay, as: UTF8.self)
        #expect(buffer.truncated)
        #expect(buffer.count <= 64 + 30)
        #expect(text.hasSuffix("line 99 \u{1B}[32mgreen\u{1B}[0m\r\n"))
        #expect(text.hasPrefix("line "))
        #expect(!text.contains("line 0 "))
    }

    @Test("The newest piece is kept even when it alone is larger than the capacity")
    func keepsTheNewestPiece() {
        var buffer = ReplayBuffer(capacity: 8)
        buffer.append(Data("old\n".utf8))
        buffer.append(Data("a very long line\nand its end\n".utf8))
        #expect(String(decoding: buffer.replay, as: UTF8.self) == "and its end\n")
        var unbroken = ReplayBuffer(capacity: 4)
        unbroken.append(Data("first".utf8))
        unbroken.append(Data("no line break here".utf8))
        #expect(unbroken.replay.isEmpty)
    }

    @Test("A long history stays bounded")
    func staysBounded() {
        var buffer = ReplayBuffer(capacity: 10_000)
        for _ in 0..<5_000 { buffer.append(Data(repeating: 0x0A, count: 100)) }
        #expect(buffer.count <= 10_000)
        #expect(buffer.replay.count == buffer.count - 1)
    }
}

@Suite("Session host: a terminal's modes")
struct TerminalModesTests {
    func modes(_ pieces: String...) -> TerminalModes {
        var modes = TerminalModes()
        for piece in pieces { modes.scan(Data(piece.utf8)) }
        return modes
    }

    func restoring(_ pieces: String...) -> String {
        var modes = TerminalModes()
        for piece in pieces { modes.scan(Data(piece.utf8)) }
        return String(decoding: modes.restoring, as: UTF8.self)
    }

    @Test("A fresh terminal, and one whose program put everything back, need nothing")
    func nothingToRestore() {
        #expect(restoring("plain text\r\n") == "")
        #expect(restoring("\u{1B}[?1049h\u{1B}[?2004h\u{1B}[?25l", "work", "\u{1B}[?25h\u{1B}[?2004l\u{1B}[?1049l") == "")
        #expect(restoring("\u{1B}[?7h\u{1B}[?25h") == "")
    }

    @Test("What Claude Code sets: bracketed paste, focus reports, the keyboard protocol, a hidden cursor")
    func claudeCode() {
        let text = restoring("\u{1B}[?2004h\u{1B}[?1004h\u{1B}[>1u\u{1B}[?25l", "\u{1B}[?2026h frame \u{1B}[?2026l")
        #expect(text == "\u{1B}[?25l\u{1B}[?1004h\u{1B}[?2004h\u{1B}[>1u")
    }

    @Test("A full-screen program: the alternate screen first, then the mouse and cursor keys")
    func fullScreenProgram() {
        let vim = modes("\u{1B}[?1049h\u{1B}[?1h\u{1B}=\u{1B}[?1000;1006h\u{1B}[2 q")
        #expect(vim.onAlternateScreen)
        #expect(String(decoding: vim.restoring, as: UTF8.self) == "\u{1B}[?1049h\u{1B}[?1h\u{1B}[?1000h\u{1B}[?1006h\u{1B}=\u{1B}[2 q")
    }

    @Test("Sequences cut anywhere between two reads are still understood")
    func splitSequences() {
        let whole = "\u{1B}[?1049h\u{1B}[?2004h\u{1B}[>5u\u{1B}[>4;2m"
        let expected = restoring(whole)
        #expect(expected == "\u{1B}[?1049h\u{1B}[?2004h\u{1B}[>5u\u{1B}[>4;2m")
        for cut in 1..<whole.utf8.count {
            var modes = TerminalModes()
            let bytes = Array(whole.utf8)
            modes.scan(Data(bytes[..<cut]))
            modes.scan(Data(bytes[cut...]))
            #expect(String(decoding: modes.restoring, as: UTF8.self) == expected, "cut at \(cut)")
        }
    }

    @Test("The keyboard protocol's stack, a full reset and a soft reset")
    func stackAndResets() {
        #expect(restoring("\u{1B}[>1u\u{1B}[>3u\u{1B}[<u") == "\u{1B}[>1u")
        #expect(restoring("\u{1B}[>1u\u{1B}[<5u") == "")
        #expect(restoring("\u{1B}[=5u\u{1B}[=2;2u\u{1B}[=4;3u") == "\u{1B}[>3u")
        #expect(restoring("\u{1B}[?2004h\u{1B}[?1049h\u{1B}c") == "")
        #expect(restoring("\u{1B}[?1h\u{1B}[?25l\u{1B}[?2004h\u{1B}[!p") == "\u{1B}[?2004h")
    }

    @Test("Text that only looks like a switch is not one")
    func lookalikes() {
        #expect(restoring("[?1049h is how vim starts", "\u{1B}]0;title [?2004h\u{07}", "\u{1B}[31mred\u{1B}[0m", "\u{1B}[2004h") == "")
    }
}

@Suite("Session host: where it lives and when it leaves")
struct HostLifecycleTests {
    @Test("The socket is inside the support folder, or in the short private folder when that path is too long")
    func socketPaths() {
        let temporary = URL(fileURLWithPath: "/var/folders/ab/cdefgh/T", isDirectory: true)
        let usual = HostPlaces(supportFolder: URL(fileURLWithPath: "/Users/someone/Library/Application Support/Whiskr"), temporaryFolder: temporary)
        #expect(usual.primary.path == "/Users/someone/Library/Application Support/Whiskr/host/host.sock")
        #expect(usual.primary.lock == "/Users/someone/Library/Application Support/Whiskr/host/host.lock")
        #expect(usual.alternate(for: 3).path.hasSuffix("/host/host-v3.sock"))

        let deep = URL(fileURLWithPath: "/private/tmp/" + String(repeating: "deep/", count: 30) + "support")
        let long = HostPlaces(supportFolder: deep, temporaryFolder: temporary)
        #expect(long.primary.path.hasPrefix("/var/folders/ab/cdefgh/T/whiskr-host-"))
        #expect(long.primary.path.utf8.count <= HostPlaces.longestSocketPath)
        // The lock and the log stay with the support folder; another support folder gets another socket.
        #expect(long.primary.lock.hasPrefix(deep.path))
        let other = HostPlaces(supportFolder: deep.appendingPathComponent("2"), temporaryFolder: temporary)
        #expect(other.primary.path != long.primary.path)
    }

    @Test("A host this app cannot talk to is never ended: the app starts its own beside it")
    func choosingAHost() {
        #expect(HostChoice.choose(primary: .absent, alternate: .absent) == .use(.primary, start: true))
        #expect(HostChoice.choose(primary: .compatible, alternate: .absent) == .use(.primary, start: false))
        #expect(HostChoice.choose(primary: .stranger(terminals: 4), alternate: .absent) == .use(.alternate, start: true))
        #expect(HostChoice.choose(primary: .stranger(terminals: 4), alternate: .compatible) == .use(.alternate, start: false))
        // The stranger has gone, ours is still on the alternate socket with our terminals: stay with it.
        #expect(HostChoice.choose(primary: .absent, alternate: .compatible) == .use(.alternate, start: false))
        #expect(HostChoice.choose(primary: .stranger(terminals: 1), alternate: .stranger(terminals: 2)) == .none)
        #expect(HostChoice.strangers(primary: .stranger(terminals: 4), alternate: .compatible) == 4)
        #expect(HostChoice.strangers(primary: .compatible, alternate: .absent) == 0)
    }

    @Test("The host leaves only with no terminal running and no client, after a while")
    func leaving() {
        let start = Date(timeIntervalSince1970: 1_000)
        func delay(terminals: Int, clients: Int, lastClient: TimeInterval, lastTerminal: TimeInterval, at now: TimeInterval, abandonedAfter: TimeInterval? = nil) -> TimeInterval? {
            HostLifecycle.exitDelay(runningTerminals: terminals, clients: clients, lastClient: start + lastClient, lastTerminal: start + lastTerminal,
                                    now: start + now, idleGrace: 30, abandonedAfter: abandonedAfter)
        }
        #expect(delay(terminals: 0, clients: 1, lastClient: 0, lastTerminal: 0, at: 500) == nil)
        #expect(delay(terminals: 2, clients: 0, lastClient: 0, lastTerminal: 0, at: 500) == nil)
        #expect(delay(terminals: 0, clients: 0, lastClient: 0, lastTerminal: 0, at: 10) == 20)
        // Counted from whichever went last: the app quit at 0, the last program ended at 100.
        #expect(delay(terminals: 0, clients: 0, lastClient: 0, lastTerminal: 100, at: 110) == 20)
        #expect(delay(terminals: 0, clients: 0, lastClient: 0, lastTerminal: 100, at: 130) == 0)
        // A test run's host also gives up on terminals nobody has come back for.
        #expect(delay(terminals: 2, clients: 0, lastClient: 0, lastTerminal: 0, at: 50, abandonedAfter: 120) == 70)
        #expect(delay(terminals: 2, clients: 0, lastClient: 0, lastTerminal: 0, at: 121, abandonedAfter: 120) == 0)
        #expect(delay(terminals: 2, clients: 1, lastClient: 0, lastTerminal: 0, at: 500, abandonedAfter: 120) == nil)
    }
}

@Suite("Session host: protocol 2 beside protocol 1")
struct HostProtocolTwoTests {
    let terminal = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    let parent = UUID(uuidString: "66666666-7777-8888-9999-000000000000")!

    @Test("Every new request, answer and event survives the wire")
    func roundTrips() throws {
        let run = RunRequest(terminal: terminal, parent: parent, command: "claude", task: "Review", name: "review", directory: "/tmp", background: true,
                             outlivesParent: true, notifiesParent: false, environment: ["A": "b"], size: TerminalSize(columns: 80, rows: 24))
        let requests: [HostRequest] = [
            .run(run), .send(SendRequest(terminal: terminal, sender: parent, text: "hi", raw: true, force: true, submit: false)),
            .keys(terminal: terminal, ["esc", "ctrl+c"]), .interrupt(terminal: terminal), .read(terminal: terminal), .subscribe,
            .wait(WaitRequest(terminal: terminal, until: .settled, timeout: 5)), .wait(WaitRequest(terminal: terminal, until: .output("Ready"), timeout: 1)),
            .wait(WaitRequest(terminal: terminal, until: .children(all: false), timeout: 9)), .wait(WaitRequest(terminal: terminal, until: .started, timeout: 60)),
        ]
        for (index, request) in requests.enumerated() {
            let call = HostCall(id: index, request: request)
            #expect(try JSONDecoder().decode(HostCall.self, from: JSONEncoder().encode(call)) == call)
            #expect(call.introducedIn == HostProtocol.agents)
        }
        #expect(HostCall(id: 1, request: .list).introducedIn == 1)
        let status = TerminalStatus(foreground: ForegroundProcess(pid: 4, name: "claude"), folder: "/tmp", program: ProgramReport(state: .blocked, kind: "permission", app: "claude", turns: 3))
        let info = TerminalInfo(id: terminal, pid: 9, size: TerminalSize(columns: 80, rows: 24), status: status, address: "t4", name: "review",
                                origin: TerminalOrigin(parent: parent, background: true, outlivesParent: false, notifiesParent: true), directory: "/tmp")
        let messages: [HostMessage] = [
            .reply(id: 1, .waited(WaitResult(outcome: .blocked, terminal: info, children: [info]))), .reply(id: 2, .snapshot(info, bytes: 12, truncated: true)),
            .reply(id: 3, .created(info)), .event(.added(info)), .event(.passed(PassedMessage(from: parent, to: terminal, kind: .note))),
            .event(.status(terminal: terminal, status)), .reply(id: 4, .failed(HostFailure(.blocked, "waits"))),
        ]
        for message in messages {
            #expect(try JSONDecoder().decode(HostMessage.self, from: JSONEncoder().encode(message)) == message)
        }
        #expect(info.activity == .blocked && info.isAgent && info.label == "t4 review")
    }

    /// `TerminalInfo` and `TerminalStatus` as a protocol-1 app has them.
    struct OldInfo: Decodable, Equatable {
        struct Status: Decodable, Equatable { var foreground: ForegroundProcess?; var folder: String? }
        var id: UUID; var pid: Int32; var size: TerminalSize; var status: Status; var exited: Bool; var exitCode: Int32?; var closing: Bool
    }

    @Test("An older app reads what a newer host says of a terminal; a newer app reads an older host's")
    func bothDirections() throws {
        let info = TerminalInfo(id: terminal, pid: 9, size: TerminalSize(columns: 80, rows: 24),
                                status: TerminalStatus(foreground: nil, folder: "/x", program: ProgramReport(state: .working)),
                                address: "t2", name: "n", origin: TerminalOrigin(parent: parent, background: false))
        let old = try JSONDecoder().decode(OldInfo.self, from: JSONEncoder().encode(info))
        #expect(old.id == terminal && old.status.folder == "/x" && old.size.columns == 80)
        // A protocol-1 host's terminal, as it sends it.
        let v1 = #"{"id":"11111111-2222-3333-4444-555555555555","pid":5,"size":{"columns":10,"rows":4,"pixelWidth":0,"pixelHeight":0},"status":{"folder":"/y"},"exited":false,"closing":false}"#
        let read = try JSONDecoder().decode(TerminalInfo.self, from: Data(v1.utf8))
        #expect(read.address == nil && read.origin == nil && read.status.program == nil && read.status.folder == "/y")
        #expect(read.activity == .idle && !read.isAgent)
        // A failure code from a newer host is still a failure, not an unreadable message.
        let newer = try JSONDecoder().decode(HostMessage.self, from: Data(#"{"re":7,"kind":"failed","failure":{"code":"quantum","message":"?"}}"#.utf8))
        #expect(newer == .reply(id: 7, .failed(HostFailure(.other, "?"))))
        // The version both speak is the older's.
        #expect(HostProtocol.spoken(client: HostVersion(version: 2, oldest: 1), host: HostVersion(version: 1, oldest: 1)) == 1)
        #expect(HostProtocol.spoken(client: HostVersion(version: 1, oldest: 1), host: HostVersion(version: 2, oldest: 1)) == 1)
        #expect(HostProtocol.compatibility(client: HostProtocol.current, host: HostVersion(version: 1, oldest: 1)) == .compatible)
        #expect(HostProtocol.compatibility(client: HostVersion(version: 1, oldest: 1), host: HostProtocol.current) == .compatible)
    }
}

@Suite("Program status reports (OSC 7501)")
struct ProgramStatusTests {
    func scanAll(_ text: String, split: Int) -> [ProgramStatusScanner.Finding] {
        var scanner = ProgramStatusScanner()
        let bytes = Data(text.utf8)
        var found: [ProgramStatusScanner.Finding] = []
        var index = 0
        while index < bytes.count {
            let end = min(index + split, bytes.count)
            found += scanner.scan(bytes.subdata(in: index..<end))
            index = end
        }
        return found
    }

    @Test("Reports, probes and prompt marks are found however the bytes are cut")
    func findsEverything() {
        let text = "hi \u{1B}]7501;state=working:app=claude\u{1B}\\x\u{1B}[31m\u{1B}]7501;?\u{07}" +
            "\u{1B}]7501;state=done:id=helper-1\u{07}\u{1B}]7;file://mac/Users/me\u{07}\u{1B}]7501;state=blocked:kind=permission\u{07}\u{1B}]0;title\u{07}"
        let expected: [ProgramStatusScanner.Finding] = [
            .report(["state": "working", "app": "claude"]), .probe(reply: Data("\u{1B}]7501;?\u{07}".utf8)), .prompt,
            .report(["state": "blocked", "kind": "permission"]),
        ]
        for split in [1, 2, 3, 5, 8, 1000] { #expect(scanAll(text, split: split) == expected, "split \(split)") }
        // The probe is answered with its own ending: ST for ST (and for C1 ST), BEL for BEL.
        #expect(scanAll("\u{1B}]7501;?\u{1B}\\", split: 1) == [.probe(reply: Data("\u{1B}]7501;?\u{1B}\\".utf8))])
        var c1 = ProgramStatusScanner()
        #expect(c1.scan(Data([0x1B, 0x5D] + Array("7501;?".utf8) + [0x9C])) == [.probe(reply: Data("\u{1B}]7501;?\u{1B}\\".utf8))])
        // An overlong string is skipped, and what follows is still read.
        #expect(scanAll("\u{1B}]7501;state=working:x=" + String(repeating: "y", count: 9000) + "\u{07}\u{1B}]7501;state=idle\u{07}", split: 700) == [.report(["state": "idle"])])
    }

    @Test("A turn is counted each time a busy program stops being busy")
    func countsTurns() {
        var report: ProgramReport? = nil
        for state in ["idle", "working", "blocked", "working", "idle", "working", "done", "bogus", "idle"] {
            report = ProgramReport.next(after: report, fields: ["state": state, "app": "claude"])
        }
        #expect(report?.turns == 2 && report?.state == .idle && report?.app == "claude")
        #expect(ProgramReport.next(after: report, fields: ["state": "clear"]) == nil)
        #expect(ProgramReport.next(after: report, fields: ["kind": "x"]) == report)
    }
}

@Suite("Agents' text: tags, notes, names, keys")
struct AgentTextTests {
    @Test("Messages and notes are tagged with who they are from")
    func tags() {
        #expect(AgentText.tagged("done: 3 issues", from: "t4 review") == #"<paw from="t4 review">done: 3 issues</paw>"#)
        #expect(AgentText.tagged("hi", from: nil) == #"<paw from="outside">hi</paw>"#)
        let note = AgentText.Note.blocked(kind: "permission")
        #expect(AgentText.tagged(note.text(label: "t4 review", address: "t4"), from: "t4 review", note: note.word)
            == #"<paw from="t4 review" note="blocked">t4 review is waiting for an answer (permission). Look with: paw read t4</paw>"#)
        #expect(AgentText.Note.exited(code: 0).text(label: "t4", address: "t4") == "t4 has ended (exit code 0).")
        #expect(AgentText.Note.error.word == "error")
    }

    @Test("Names are typeable and never look like addresses")
    func names() {
        for good in ["review", "a", "fix-cart_2", String(repeating: "a", count: 32), "tests"] { #expect(AgentText.isValidName(good), "\(good)") }
        for bad in ["", "Review", "2nd", "t4", "t12", "-x", "a b", "naïve", String(repeating: "a", count: 33)] { #expect(!AgentText.isValidName(bad), "\(bad)") }
        #expect(AgentText.isAddressShaped("t4") && !AgentText.isAddressShaped("t") && !AgentText.isAddressShaped("tests"))
    }

    @Test("Keys by name, the cursor keys in the program's chosen form, and nothing for an unknown name")
    func keys() {
        #expect(TerminalKeys.encode(["enter", "esc", "ctrl+c", "tab", "y", "1"]) == Data("\r\u{1B}\u{03}\ty1".utf8))
        #expect(TerminalKeys.encode(["up", "left"]) == Data("\u{1B}[A\u{1B}[D".utf8))
        #expect(TerminalKeys.encode(["up", "left"], applicationCursor: true) == Data("\u{1B}OA\u{1B}OD".utf8))
        #expect(TerminalKeys.encode(["shift+tab", "alt+b", "ctrl+[", "f5", "pagedown"]) == Data("\u{1B}[Z\u{1B}b\u{1B}\u{1B}[15~\u{1B}[6~".utf8))
        #expect(TerminalKeys.encode(["enter", "teleport"]) == nil)
        #expect(TerminalKeys.encode(["ctrl+1"]) == nil)
    }
}
