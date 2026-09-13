import Foundation
import Testing
@testable import WhiskrKit

@Suite("Hook listener request checks")
struct HookRequestTests {
    let gate = HookGate(port: 52_000, token: "secret-token")
    let pane = "6F9619FF-8B86-D011-B42D-00C04FC964FF"

    private func head(_ text: String) -> HTTPRequestHead? {
        HTTPRequestHead.parse(Data(text.replacingOccurrences(of: "\n", with: "\r\n").utf8))
    }

    private func post(path: String? = nil, host: String = "127.0.0.1:52000", method: String = "POST", extra: String = "Content-Length: 2") -> HTTPRequestHead? {
        head("\(method) \(path ?? "/hook/\(pane)?token=secret-token") HTTP/1.1\nHost: \(host)\nContent-Type: application/json\n\(extra)")
    }

    @Test("a well-formed post from a pane is accepted with its body length")
    func accepted() throws {
        let request = try #require(post())
        #expect(gate.check(request) == .success(HookRoute(paneID: pane, framing: .length(2))))
        #expect(try #require(post(host: "localhost:52000")).method == "POST")
        #expect(gate.check(try #require(post(host: "localhost:52000"))) == .success(HookRoute(paneID: pane, framing: .length(2))))
    }

    @Test("the URL handed to Claude passes the gate")
    func ownURL() throws {
        let url = gate.url(paneID: pane)
        #expect(url.absoluteString == "http://127.0.0.1:52000/hook/\(pane)?token=secret-token")
        let request = try #require(post(path: "\(url.path)?\(url.query ?? "")"))
        #expect(gate.check(request) == .success(HookRoute(paneID: pane, framing: .length(2))))
    }

    @Test("another Host is refused, so a web page cannot reach the listener by DNS rebinding")
    func wrongHost() throws {
        for host in ["evil.example:52000", "127.0.0.1:4317", "127.0.0.1", "", "localhost.evil.example:52000"] {
            #expect(gate.check(try #require(post(host: host))) == .failure(.wrongHost), "\(host)")
        }
        #expect(gate.check(try #require(head("POST /hook/\(pane)?token=secret-token HTTP/1.1\nContent-Length: 2"))) == .failure(.wrongHost))
    }

    @Test("a wrong or missing token is refused")
    func wrongToken() throws {
        for query in ["?token=secret-tokeN", "?token=secret", "", "?token=", "?other=secret-token"] {
            #expect(gate.check(try #require(post(path: "/hook/\(pane)\(query)"))) == .failure(.wrongToken), "\(query)")
        }
    }

    @Test("anything but a post to a pane's hook path is refused")
    func wrongPathOrMethod() throws {
        #expect(gate.check(try #require(post(path: "/?token=secret-token"))) == .failure(.notFound))
        #expect(gate.check(try #require(post(path: "/hook/not-a-pane?token=secret-token"))) == .failure(.notFound))
        #expect(gate.check(try #require(post(path: "/hook/../\(pane)?token=secret-token"))) == .failure(.notFound))
        #expect(gate.check(try #require(post(method: "GET"))) == .failure(.wrongMethod))
    }

    @Test("bodies are bounded, and chunked bodies are accepted")
    func bodies() throws {
        #expect(gate.check(try #require(post(extra: "Content-Length: \(HookGate.maxBody + 1)"))) == .failure(.tooLarge))
        #expect(gate.check(try #require(post(extra: "Content-Length: -4"))) == .failure(.malformed))
        #expect(gate.check(try #require(post(extra: "Content-Length: lots"))) == .failure(.malformed))
        #expect(gate.check(try #require(post(extra: "Transfer-Encoding: chunked"))) == .success(HookRoute(paneID: pane, framing: .chunked)))
    }

    @Test("malformed heads are not parsed")
    func malformedHeads() {
        #expect(head("POST /hook HTTP/2\nHost: x") == nil)
        #expect(head("POST /hook") == nil)
        #expect(head("POST http://evil/hook HTTP/1.1\nHost: x") == nil)
        #expect(head("POST /hook HTTP/1.1\nno colon here") == nil)
        #expect(HTTPRequestHead.parse(Data(repeating: 65, count: HTTPRequestHead.maxSize + 1)) == nil)
    }

    @Test("a chunked body is reassembled however it is split up")
    func chunked() throws {
        let wire = Data("7\r\n{\"a\":1}\r\n4\r\n,\"b\"\r\n0\r\n\r\n".utf8)
        for split in 1..<wire.count {
            var decoder = ChunkedDecoder()
            let first = try decoder.feed(wire.prefix(split))
            let done = try decoder.feed(wire.dropFirst(split))
            #expect(!first || split == wire.count)
            #expect(done)
            #expect(String(decoding: decoder.body, as: UTF8.self) == "{\"a\":1},\"b\"")
        }
        var bad = ChunkedDecoder()
        #expect(throws: ChunkedDecoder.Failure.self) { try bad.feed(Data("zz\r\n".utf8)) }
        var huge = ChunkedDecoder()
        #expect(throws: ChunkedDecoder.Failure.self) { try huge.feed(Data("7fffffff\r\n".utf8)) }
    }

    @Test("tokens compare equal only when identical")
    func tokens() {
        #expect(HookGate.constantTimeEqual("abc", "abc"))
        #expect(!HookGate.constantTimeEqual("abc", "abd"))
        #expect(!HookGate.constantTimeEqual("abc", "abcd"))
        let token = HookGate.makeToken()
        #expect(token.count == 64)
        #expect(token != HookGate.makeToken())
    }

    @Test("the settings register every event (SessionStart too) as command hooks posting to the app's address, and tell Claude about paw")
    func settingsDocument() throws {
        let json = try JSONDecoder().decode(JSONValue.self, from: HookSettings.document(addressFolder: "/tmp/Application Support/Whiskr/hooks"))
        let hooks = json["hooks"].fields
        #expect(Set(hooks.keys) == Set(HookSettings.events))
        #expect(HookSettings.events.count == 28)
        #expect(hooks["SessionStart"] != nil)
        for excluded in ["Setup", "PreModelSwitch", "WorktreeCreate", "WorktreeRemove", "FileChanged"] {
            #expect(hooks[excluded] == nil)
        }
        let hook = hooks["Stop"].items.first["hooks"].items.first
        #expect(hook["type"].text == "command")
        #expect(hook["command"].text.hasSuffix(" sh '/tmp/Application Support/Whiskr/hooks'"))
        #expect(hook["command"].text.contains("$1/$WHISKR_PANE.url"))
        #expect(hook["command"].text.contains("-o /dev/null"))
        // At session start a second hook prints the one line about paw (its output is what Claude reads).
        let starts = hooks["SessionStart"].items
        #expect(starts.count == 2)
        #expect(starts.last["hooks"].items.first["command"].text == HookSettings.noteCommand(HookSettings.pawNote))
        let quiet = try JSONDecoder().decode(JSONValue.self, from: HookSettings.document(addressFolder: "/x", note: nil))
        #expect(quiet["hooks"]["SessionStart"].items.count == 1)
    }

    @Test("the note is printed only where paw can be run")
    func noteNeedsPaw() throws {
        func run(path: String) throws -> String {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", HookSettings.noteCommand("Use `paw`; it's \"here\".")]
            process.environment = ["PATH": path]
            let out = Pipe()
            process.standardOutput = out
            try process.run()
            process.waitUntilExit()
            #expect(process.terminationStatus == 0)
            return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        }
        let bin = FileManager.default.temporaryDirectory.appendingPathComponent("whiskr-paw-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: bin) }
        #expect(try run(path: "/usr/bin:/bin").isEmpty)
        try Data("#!/bin/sh\n".utf8).write(to: bin.appendingPathComponent("paw"))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.appendingPathComponent("paw").path)
        #expect(try run(path: "\(bin.path):/usr/bin:/bin") == "Use `paw`; it's \"here\".\n")
    }

    /// Runs the hook command as Claude Code does (through a shell, the event on standard input) with a
    /// stand-in for the listener's address; returns its exit code.
    func runHook(addressFile: URL, shell: String = "/bin/sh") throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-c", HookSettings.command(addressFolder: addressFile.deletingLastPathComponent().path)]
        // The pane the hook fires in, as its terminal was started with.
        process.environment = ["WHISKR_PANE": addressFile.deletingPathExtension().lastPathComponent]
        let input = Pipe()
        process.standardInput = input
        process.standardError = FileHandle.nullDevice
        try process.run()
        input.fileHandleForWriting.write(Data(#"{"hook_event_name":"Stop"}"#.utf8))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        return process.terminationStatus
    }

    @Test("the hook reads the app's address when it fires, so a session that outlives the app reports to the next one; with no app it does nothing and never fails")
    func hookFollowsTheAddressFile() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("whiskr hook's \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let address = folder.appendingPathComponent("pane.url")
        // No app: no address file.
        #expect(try runHook(addressFile: address) == 0)
        // An address nobody listens at (the app crashed): still no failure.
        try Data("http://127.0.0.1:9/hook/x?token=y".utf8).write(to: address)
        #expect(try runHook(addressFile: address) == 0)
        // An address that takes the post, from whichever shell runs the hook.
        let listener = try OneShotListener()
        try Data("http://127.0.0.1:\(listener.port)/hook/pane?token=secret".utf8).write(to: address)
        for shell in ["/bin/sh", "/bin/zsh", "/bin/bash"] {
            let heard = listener.listen()
            #expect(try runHook(addressFile: address, shell: shell) == 0)
            let request = heard()
            #expect(request.hasPrefix("POST /hook/pane?token=secret HTTP/1.1"), "\(shell)")
            #expect(request.hasSuffix(#"{"hook_event_name":"Stop"}"#), "\(shell)")
        }
    }
}

/// A stand-in for the app's listener: takes one request at a time on a local port and answers `{}`.
final class OneShotListener: @unchecked Sendable {
    let port: UInt16
    private let fd: Int32

    init() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        self.fd = fd
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, length) == 0 && getsockname(fd, $0, &length) == 0 }
        }
        guard bound, Darwin.listen(fd, 4) == 0 else { throw CocoaError(.fileNoSuchFile) }
        port = UInt16(bigEndian: address.sin_port)
    }

    deinit { close(fd) }

    /// Starts waiting for a request; the function returned gives it once it has come.
    func listen() -> () -> String {
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var request = ""
        Thread.detachNewThread { [self] in
            request = next()
            done.signal()
        }
        return {
            done.wait()
            return request
        }
    }

    /// The next request, head and body, as text.
    private func next() -> String {
        let client = accept(fd, nil, nil)
        defer { close(client) }
        var request = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while !String(decoding: request, as: UTF8.self).hasSuffix("}") {
            let count = read(client, &chunk, chunk.count)
            guard count > 0 else { break }
            request.append(contentsOf: chunk[0..<count])
        }
        let answer = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}"
        _ = answer.withCString { write(client, $0, strlen($0)) }
        return String(decoding: request, as: UTF8.self)
    }
}
