import Foundation
import Testing
@testable import WhiskrKit

@Suite("Resuming a Claude conversation")
struct ClaudeResumeTests {
    @Test("the command names the account explicitly, quotes its folder, and takes only a session id")
    func command() {
        let id = "2b1c3d4e-0000-4000-8000-000000000001"
        let work = ClaudeAccount(name: "work", configDir: "/Users/me/.claude-work", email: nil)
        let spaced = ClaudeAccount(name: "odd", configDir: "/Users/me/it's here", email: nil)
        let main = ClaudeAccount(name: ClaudeAccount.defaultName, configDir: "/Users/me/.claude", email: nil)
        #expect(ClaudeResume.resumeCommand(sessionID: id, account: work) == "CLAUDE_CONFIG_DIR=/Users/me/.claude-work claude --resume \(id)")
        #expect(ClaudeResume.resumeCommand(sessionID: id, account: spaced) == #"CLAUDE_CONFIG_DIR='/Users/me/it'\''s here' claude --resume "# + id)
        #expect(ClaudeResume.resumeCommand(sessionID: id, account: main) == "env -u CLAUDE_CONFIG_DIR claude --resume \(id)")
        #expect(ClaudeResume.resumeCommand(sessionID: id, account: nil) == "claude --resume \(id)")
        #expect(ClaudeResume.resumeCommand(sessionID: "x; rm -rf ~", account: nil) == nil)
    }
}
