import Foundation
import Testing
@testable import WhiskrKit

@Suite("Claude in a pane: when the cat comes and goes")
struct AgentPresenceTests {
    @Test("Claude Code is known however it is installed", arguments: [
        ForegroundProcess(pid: 1, name: "claude"),
        ForegroundProcess(pid: 1, name: "claude.exe", executable: "/opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/bin/claude.exe"),
        ForegroundProcess(pid: 1, name: "2.1.305", executable: "/Users/me/.local/share/claude/versions/2.1.305", arguments: ["claude", "--resume"]),
        ForegroundProcess(pid: 1, name: "node", executable: "/opt/homebrew/bin/node", arguments: ["node", "/opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/cli.js"]),
    ])
    func claudeIsKnown(_ process: ForegroundProcess) {
        #expect(process.isClaude)
    }

    @Test("other programs are not Claude", arguments: [
        ForegroundProcess(pid: 1, name: "vim", arguments: ["vim", "claude.md"]),
        ForegroundProcess(pid: 1, name: "node", executable: "/opt/homebrew/bin/node", arguments: ["node", "server.js"]),
        ForegroundProcess(pid: 1, name: "npm", arguments: ["npm", "run", "dev"]),
        ForegroundProcess(pid: 1, name: "claude-monitor"),
    ])
    func othersAreNot(_ process: ForegroundProcess) {
        #expect(!process.isClaude)
    }

    @Test("typed by hand: the cat appears the moment claude is in front, before any hook event, and leaves at the prompt")
    func typedByHand() {
        var presence = AgentPresence()
        let c1 = presence.observe(foreground: nil, liveSession: false)
        #expect(!c1)
        let c2 = presence.observe(foreground: ForegroundProcess(pid: 9, name: "claude.exe"), liveSession: false)
        #expect(c2)
        #expect(presence.present)
        // Still there while it runs (no change reported).
        let c3 = presence.observe(foreground: ForegroundProcess(pid: 9, name: "claude.exe"), liveSession: true)
        #expect(!c3)
        // Exited: the shell is back in front, even if no SessionEnd ever came.
        let c4 = presence.observe(foreground: nil, liveSession: true)
        #expect(c4)
        #expect(!presence.present)
    }

    @Test("a dev server or any other command is a lantern, not a cat")
    func plainCommand() {
        var presence = AgentPresence()
        presence.observe(foreground: ForegroundProcess(pid: 4, name: "node", arguments: ["node", "vite"]), liveSession: false)
        #expect(!presence.present)
    }

    @Test("started some other way (a script, a wrapper): its hook events bring the cat, and the prompt ends it")
    func throughAWrapper() {
        var presence = AgentPresence()
        let wrapper = ForegroundProcess(pid: 5, name: "bash", arguments: ["bash", "./start-agent.sh"])
        presence.observe(foreground: wrapper, liveSession: false)
        #expect(!presence.present)
        let c5 = presence.heard()
        #expect(c5)
        #expect(presence.present)
        // The wrapper stays in front while the session is live: still a cat.
        let c6 = presence.observe(foreground: wrapper, liveSession: true)
        #expect(!c6)
        #expect(presence.present)
        presence.observe(foreground: nil, liveSession: true)
        #expect(!presence.present)
    }
}
