import Foundation
import Testing
@testable import Paw
import WhiskrKit

/// `paw merge-settings`, as the `claude` shim runs it, through `Paw.run` with the real merge.
@Suite("paw: your --settings with the pane's hooks added")
struct PawMergeSettingsTests {
    let folder: URL
    let hooks: URL

    init() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("whiskr-paw-merge-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        hooks = folder.appendingPathComponent("settings.json")
        try HookSettings.document(addressFolder: folder.path, note: nil).write(to: hooks)
    }

    /// The exit code and what `paw` printed on each stream.
    func merge(_ arguments: [String]) -> (code: Int32, out: [String], err: [String]) {
        let out = Lines(), err = Lines()
        let paw = Paw(environment: [:], currentFolder: folder.path, io: PawIO(out: { out.add($0) }, err: { err.add($0) }, input: { "" }))
        let code = paw.run(["merge-settings"] + arguments)
        return (code, out.all, err.all)
    }

    @Test("it prints the path of a private file holding yours with the pane's hooks after your own")
    func writesAFile() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let mine = #"{"env":{"TOKEN":"secret"},"hooks":{"Stop":[{"hooks":[{"type":"command","command":"mine"}]}]}}"#
        let result = merge([hooks.path, mine])
        #expect(result.code == PawExit.ok.rawValue)
        #expect(result.err.isEmpty)
        let path = try #require(result.out.count == 1 ? result.out[0] : nil)
        #expect(URL(fileURLWithPath: path).deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL)
        let permissions = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)
        let settings = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as? [String: Any])
        #expect((settings["env"] as? [String: String]) == ["TOKEN": "secret"])
        let stop = try #require((settings["hooks"] as? [String: [[String: Any]]])?["Stop"])
        #expect(stop.count == 2)
        #expect(((stop.first?["hooks"] as? [[String: Any]])?.first?["command"] as? String) == "mine")

        // The same settings again: the same file. Other settings: another, the first left as it was.
        #expect(merge([hooks.path, mine]).out == [path])
        let other = merge([hooks.path, #"{"model":"haiku"}"#])
        #expect(other.code == PawExit.ok.rawValue && other.out != [path])
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)).count > 0)
        // Nothing half-written is left behind.
        let left = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasPrefix(".") }
        #expect(left.isEmpty)
    }

    @Test("a settings file of yours is read from its path")
    func fromAFile() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let mine = folder.appendingPathComponent("mine.json")
        try Data(#"{"model":"haiku"}"#.utf8).write(to: mine)
        let result = merge([hooks.path, mine.path])
        #expect(result.code == PawExit.ok.rawValue)
        let path = try #require(result.out.first)
        let settings = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as? [String: Any])
        #expect(settings["model"] as? String == "haiku")
        #expect((settings["hooks"] as? [String: Any])?["UserPromptSubmit"] != nil)
    }

    @Test("when it cannot be done, one line says why, nothing is printed for the shim, and it ends with 1")
    func failures() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let list = folder.appendingPathComponent("list.json")
        try Data("[1]".utf8).write(to: list)
        let cases: [([String], String)] = [
            ([folder.appendingPathComponent("gone.json").path, "{}"], "hooks file cannot be read"),
            ([hooks.path, "/no/such/settings.json"], "/no/such/settings.json cannot be read"),
            ([hooks.path, list.path], "not a JSON object"),
            ([hooks.path, "{not json"], "not a JSON object"),
        ]
        for (arguments, reason) in cases {
            let result = merge(arguments)
            #expect(result.code == PawExit.failed.rawValue, "\(arguments)")
            #expect(result.out.isEmpty, "\(arguments)")
            #expect(result.err.count == 1 && result.err[0].contains(reason) && result.err[0].contains("hooks were not added"), "\(result.err)")
        }
    }

    @Test("it takes exactly the hooks file and yours, or ends with 2")
    func argumentCount() {
        defer { try? FileManager.default.removeItem(at: folder) }
        for arguments in [[], [hooks.path], [hooks.path, "{}", "extra"]] {
            let result = merge(arguments)
            #expect(result.code == PawExit.usage.rawValue, "\(arguments)")
            #expect(result.out.isEmpty && result.err.count == 1, "\(arguments)")
        }
    }
}
