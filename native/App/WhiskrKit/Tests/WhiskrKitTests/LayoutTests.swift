import Foundation
import Testing
@testable import WhiskrKit

@Suite("Splits and focus movement")
struct PaneTreeTests {
    let a = UUID(), b = UUID(), c = UUID(), d = UUID()

    /// a | (b over c), then d split down from a: (a over d) | (b over c).
    var grid: PaneTree {
        PaneTree.pane(a)
            .splitting(a, axis: .horizontal, new: b)
            .splitting(b, axis: .vertical, new: c)
            .splitting(a, axis: .vertical, new: d)
    }

    @Test("splitting puts the new pane right of or below the one split")
    func split() {
        #expect(grid.panes == [a, d, b, c])
        let frames = grid.frames(in: CGRect(x: 0, y: 0, width: 200, height: 100))
        #expect(frames[a] == CGRect(x: 0, y: 0, width: 100, height: 50))
        #expect(frames[d] == CGRect(x: 0, y: 50, width: 100, height: 50))
        #expect(frames[b] == CGRect(x: 100, y: 0, width: 100, height: 50))
        #expect(frames[c] == CGRect(x: 100, y: 50, width: 100, height: 50))
    }

    @Test("closing a pane gives its space to its neighbour")
    func remove() {
        #expect(grid.removing(b)?.panes == [a, d, c])
        #expect(grid.removing(b)?.removing(c)?.panes == [a, d])
        #expect(PaneTree.pane(a).removing(a) == nil)
        #expect(grid.removing(UUID()) == grid)
    }

    @Test("replacing gives one pane's place to another and keeps the rest")
    func replace() {
        let e = UUID()
        #expect(grid.replacing(d, with: e).panes == [a, e, b, c])
        #expect(grid.replacing(e, with: a) == grid)
    }

    @Test("dragging a divider changes only that split's ratio, kept within bounds")
    func ratios() {
        let tree = grid.settingRatio(0.25, at: []).settingRatio(0.8, at: [1])
        let frames = tree.frames(in: CGRect(x: 0, y: 0, width: 200, height: 100))
        #expect(frames[a]?.width == 50)
        #expect(frames[b]?.height == 80)
        #expect(frames[a]?.height == 50)
        let squeezed = grid.settingRatio(0, at: []).frames(in: CGRect(x: 0, y: 0, width: 100, height: 100))
        #expect(squeezed[a]?.width == 5)
        #expect(grid.settingRatio(.nan, at: []) == grid)
    }

    @Test("focus moves to the nearest pane in that direction")
    func neighbours() {
        #expect(grid.neighbor(of: a, toward: .right) == b)
        #expect(grid.neighbor(of: a, toward: .down) == d)
        #expect(grid.neighbor(of: d, toward: .right) == c)
        #expect(grid.neighbor(of: c, toward: .up) == b)
        #expect(grid.neighbor(of: c, toward: .left) == d)
        #expect(grid.neighbor(of: a, toward: .left) == nil)
        #expect(grid.neighbor(of: a, toward: .up) == nil)
    }

    @Test("swapping trades two panes' places and nothing else")
    func swap() {
        let swapped = grid.swapping(a, c)
        #expect(swapped.panes == [c, d, b, a])
        #expect(swapped.frames(in: CGRect(x: 0, y: 0, width: 2, height: 2))[c] == grid.frames(in: CGRect(x: 0, y: 0, width: 2, height: 2))[a])
    }

    @Test("the room a layout needs adds up side by side and stacks up and down")
    func minimumSize() {
        let size = grid.minimumSize(pane: CGSize(width: 200, height: 100), gap: 8)
        #expect(size == CGSize(width: 408, height: 208))
        #expect(PaneTree.pane(a).minimumSize(pane: CGSize(width: 200, height: 100), gap: 8) == CGSize(width: 200, height: 100))
    }

    @Test("among equally near panes, the one used last wins, else the top-most")
    func recency() {
        // a | (b over c): from a, both b and c are to the right.
        let tree = PaneTree.pane(a).splitting(a, axis: .horizontal, new: b).splitting(b, axis: .vertical, new: c)
        #expect(tree.neighbor(of: a, toward: .right) == b)
        #expect(tree.neighbor(of: a, toward: .right, recency: [b, c, a]) == c)
        #expect(tree.neighbor(of: a, toward: .right, recency: [c, b, a]) == b)
    }
}

@Suite("Layout saved and restored")
struct LayoutSnapshotTests {
    func sample() -> LayoutSnapshot {
        let (p1, p2, p3) = (UUID(), UUID(), UUID())
        let tree = PaneTree.pane(p1).splitting(p1, axis: .horizontal, new: p2).settingRatio(0.3, at: [])
        let tab1 = LayoutSnapshot.Tab(id: UUID(), name: "agents", tree: tree, panes: [
            .init(id: p1, folder: "/code/shop", isClaude: true, accountConfigDir: "/Users/me/.claude-work", claudeSessionID: "2b1c-session", claudeSessionTitle: "Fix the cart"),
            .init(id: p2, folder: "/code/shop/src", isClaude: false, accountConfigDir: nil, claudeSessionID: nil, claudeSessionTitle: nil),
        ], focusedPane: p2, zoomedPane: nil)
        let tab2 = LayoutSnapshot.Tab(id: UUID(), name: nil, tree: .pane(p3), panes: [
            .init(id: p3, folder: "/code/blog", isClaude: false, accountConfigDir: nil, claudeSessionID: nil, claudeSessionTitle: nil),
        ], focusedPane: p3, zoomedPane: p3)
        let shop = LayoutSnapshot.Workspace(id: UUID(), folder: "/code/shop", tabs: [tab1, tab2], selectedTab: tab2.id)
        return LayoutSnapshot(workspaces: [shop], selectedWorkspace: shop.id)
    }

    private func temporaryFile() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("whiskr-layout-\(UUID().uuidString)/layout.json")
    }

    @Test("a layout written and read back is the same layout")
    func roundTrip() throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let layout = sample()
        try layout.write(to: url)
        #expect(LayoutSnapshot.read(from: url) == layout)
    }

    @Test("a missing, damaged or newer file gives no layout rather than an error")
    func unusable() throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        #expect(LayoutSnapshot.read(from: url) == nil)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: url)
        #expect(LayoutSnapshot.read(from: url) == nil)
        var newer = sample()
        newer.version = 99
        try newer.write(to: url)
        #expect(LayoutSnapshot.read(from: url) == nil)
    }

    @Test("inconsistent parts are dropped, the rest kept")
    func repair() {
        var layout = sample()
        let good = layout.workspaces[0].tabs[0]
        var broken = good
        broken.panes.removeLast()
        var reused = layout.workspaces[0].tabs[1]
        reused.tree = .pane(good.panes[0].id)
        reused.panes = [good.panes[0]]
        layout.workspaces[0].tabs = [good, broken, reused]
        layout.workspaces[0].selectedTab = UUID()
        layout.workspaces.append(.init(id: UUID(), folder: "/empty", tabs: [], selectedTab: nil))

        let repaired = layout.repaired
        #expect(repaired.workspaces.count == 1)
        #expect(repaired.workspaces[0].tabs == [good])
        #expect(repaired.workspaces[0].selectedTab == nil)
        #expect(repaired.selectedWorkspace == layout.selectedWorkspace)
    }
}

@Suite("Launching terminals")
struct LaunchTests {
    @Test("a shell starts as a login shell, as Terminal opens it")
    func shell() {
        let shell = Launch.shell("/bin/bash", directory: "/code", environment: [:])
        #expect(shell.executable == "/bin/bash")
        #expect(shell.argv0 == "-bash")
        #expect(shell.arguments.isEmpty)
        #expect(shell.directory == "/code")
    }

    @Test("the environment drops what the app inherited and sets what a terminal sets")
    func environment() {
        let base = ["PATH": "/usr/bin", "HOME": "/Users/me", "CLAUDECODE": "1", "CLAUDE_CODE_SESSION_ID": "x", "CLAUDE_CONFIG_DIR": "/Users/me/.claude-other",
                    "TERM_PROGRAM": "iTerm.app", "ITERM_SESSION_ID": "w0", "PWD": "/tmp", "SHLVL": "3"]
        let env = Launch.environment(base: base, shell: "/bin/zsh", appVersion: "0.1",
                                     localeIdentifier: "ja_JP", localeExists: { $0 == "ja_JP.UTF-8" })
        #expect(env["PATH"] == "/usr/bin")
        // The account is the user's own shell setup's to choose; an inherited one is dropped.
        #expect(env["CLAUDE_CONFIG_DIR"] == nil)
        #expect(env["TERM"] == "xterm-256color")
        #expect(env["COLORTERM"] == "truecolor")
        #expect(env["TERM_PROGRAM"] == "Whiskr")
        #expect(env["LANG"] == "ja_JP.UTF-8")
        for gone in ["CLAUDECODE", "CLAUDE_CODE_SESSION_ID", "ITERM_SESSION_ID", "PWD", "SHLVL"] { #expect(env[gone] == nil) }

        let british = Launch.environment(base: base.merging(["LANG": "en_GB.UTF-8"]) { $1 }, shell: "/bin/zsh", appVersion: "0.1",
                                         localeIdentifier: "en_GB", localeExists: { _ in false })
        #expect(british["LANG"] == "en_GB.UTF-8")
        let unknownLocale = Launch.environment(base: ["LC_CTYPE": "C"], shell: "/bin/zsh", appVersion: "0.1",
                                               localeIdentifier: "xx_YY", localeExists: { _ in false })
        #expect(unknownLocale["LANG"] == "en_US.UTF-8")
        #expect(unknownLocale["LC_CTYPE"] == nil)
    }
}

@Suite("Workspace colours")
struct WorkspaceColourTests {
    @Test("the six colours go round in turn, the least used first, and each is saved with its workspace")
    func inTurn() throws {
        var taken: [Int] = []
        for _ in 0..<8 { taken.append(LayoutSnapshot.Workspace.nextColor(after: taken)) }
        #expect(taken == [0, 1, 2, 3, 4, 5, 0, 1])
        // A workspace closed in the middle: its colour is the next one used.
        #expect(LayoutSnapshot.Workspace.nextColor(after: [0, 1, 3, 4, 5]) == 2)
        let saved = LayoutSnapshot(workspaces: [.init(id: UUID(), folder: "/a", tabs: [], selectedTab: nil, color: 4)], selectedWorkspace: nil)
        let data = try JSONEncoder().encode(saved)
        #expect(try JSONDecoder().decode(LayoutSnapshot.self, from: data).workspaces[0].color == 4)
        // Layouts saved before colours read with none.
        let old = #"{"version":1,"workspaces":[{"id":"6B2E9A3C-1F5D-4A7B-9C8E-0D1F2A3B4C5D","folder":"/a","tabs":[]}]}"#
        #expect(try JSONDecoder().decode(LayoutSnapshot.self, from: Data(old.utf8)).workspaces[0].color == nil)
    }
}
