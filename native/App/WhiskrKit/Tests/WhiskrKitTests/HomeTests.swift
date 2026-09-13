import Foundation
import Testing
@testable import WhiskrKit

@Suite("Home")
struct HomeTests {
    private func workspace(_ name: String, _ claudes: [(status: AgentStatus, failed: Bool)] = [], branch: String? = nil) -> HomeList.Workspace {
        HomeList.Workspace(id: UUID(), name: name, folder: "/code/\(name)", branch: branch, colorIndex: 0, claudes: claudes)
    }

    @Test("Open lists the workspaces in the meadow's order, numbered as ⌥⌘1…9, whatever their Claudes do")
    func order() {
        let names = (1...11).map { "w\($0)" }
        var workspaces = names.map { workspace($0) }
        workspaces[5].claudes = [(.blocked, false)]
        let rows = HomeList.open(workspaces)
        #expect(rows.map(\.name) == names)
        #expect(rows.map(\.number) == (1...9).map { Optional($0) } + [nil, nil])
        #expect(rows[5].state == .needsYou(failed: false))
    }

    @Test("a workspace's state is its most urgent Claude's, with its Claude count")
    func state() {
        let rows = HomeList.open([
            workspace("request", [(.idle, false), (.blocked, false), (.done, false)]),
            workspace("error", [(.blocked, true), (.working, false)]),
            workspace("both", [(.blocked, true), (.blocked, false)]),
            workspace("finished", [(.done, false), (.working, false)]),
            workspace("working", [(.working, false), (.idle, false)]),
            workspace("idle", [(.idle, false), (.unknown, false)]),
            workspace("shells"),
        ])
        #expect(rows.map(\.state) == [.needsYou(failed: false), .needsYou(failed: true), .needsYou(failed: false), .finished, .working, .idle, .idle])
        #expect(rows.map(\.claudes) == [3, 2, 2, 2, 2, 2, 0])
    }

    @Test("Recent leaves out the folders already under Open, keeping its order")
    func recents() {
        let now = Date()
        let recents = ["/code/a", "/code/b", "/code/c"].map { RecentFolder(path: $0, lastUsed: now) }
        #expect(HomeList.recents(recents, open: ["/code/b", "/elsewhere"]).map(\.path) == ["/code/a", "/code/c"])
    }

    @Test("letters jump to the first row named so, from the highlighted one on, wrapping")
    func typeSelect() {
        let names = ["Open Folder…", "New Terminal", "shop-web", "api", "Shop admin"]
        #expect(HomeList.typeSelect("s", in: names) == 2)
        #expect(HomeList.typeSelect("s", in: names, from: 3) == 4)
        #expect(HomeList.typeSelect("s", in: names, from: 5) == 4)
        #expect(HomeList.typeSelect("SHOP-", in: names) == 2)
        #expect(HomeList.typeSelect("z", in: names) == nil)
        #expect(HomeList.typeSelect("", in: names) == nil)
        #expect(HomeList.typeSelect("a", in: []) == nil)
    }

    @Test("closing the workspace on screen returns Home; closing another leaves you where you are")
    func closing() {
        let shown = UUID(), other = UUID()
        #expect(HomeRules.selection(afterClosing: shown, selected: shown) == nil)
        #expect(HomeRules.selection(afterClosing: other, selected: shown) == shown)
        #expect(HomeRules.selection(afterClosing: other, selected: nil) == nil)
    }

    @Test("a launch types nothing, except to resume a Claude whose terminal is gone, and never beside another host")
    func resume() {
        // The host still holds the terminal: shown as it was, whatever ran in it.
        for claude in [true, false] {
            #expect(ResumePlan.action(held: true, claudeSession: claude, resumeEnabled: true, otherHosts: false) == .attach)
            #expect(ResumePlan.action(held: true, claudeSession: claude, resumeEnabled: true, otherHosts: true) == .attach)
        }
        // After a restart.
        #expect(ResumePlan.action(held: false, claudeSession: true, resumeEnabled: true, otherHosts: false) == .resume)
        #expect(ResumePlan.action(held: false, claudeSession: false, resumeEnabled: true, otherHosts: false) == .freshShell)
        #expect(ResumePlan.action(held: false, claudeSession: true, resumeEnabled: false, otherHosts: false) == .freshShell)
        // The earlier-named app's (or another version's) host still runs: its Claudes may be these.
        #expect(ResumePlan.action(held: false, claudeSession: true, resumeEnabled: true, otherHosts: true) == .freshShell)
    }

    @Test("a layout saved with a selected workspace still reads; none is kept now")
    func oldLayout() throws {
        let id = UUID()
        let json = #"{"version":1,"selectedWorkspace":"\#(id)","workspaces":[{"id":"\#(id)","folder":"/a","tabs":[]}]}"#
        let layout = try JSONDecoder().decode(LayoutSnapshot.self, from: Data(json.utf8))
        #expect(layout.workspaces.map(\.id) == [id])
        let written = String(decoding: try JSONEncoder().encode(layout), as: UTF8.self)
        #expect(!written.contains("selectedWorkspace"))
    }

    @Test("a folder in the status bar: home as ~, deep ones as their last two folders")
    func shortFolder() {
        let home = "/Users/me"
        #expect(Places.short("/Users/me", home: home) == "~")
        #expect(Places.short("/Users/me/code", home: home) == "~/code")
        #expect(Places.short("/Users/me/code/shop", home: home) == "~/code/shop")
        #expect(Places.short("/Users/me/Library/Developer/shop", home: home) == "~/…/Developer/shop")
        #expect(Places.short("/opt/local", home: home) == "/opt/local")
        #expect(Places.short("/Volumes/Work/code/shop", home: home) == "/…/code/shop")
        #expect(Places.short("/", home: home) == "/")
    }
}
