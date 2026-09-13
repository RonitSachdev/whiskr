import Foundation
import Testing
@testable import WhiskrKit

@Suite("A helper's story")
struct StoryTests {
    let start = Date(timeIntervalSince1970: 1_800_000_000)

    func at(_ seconds: Double) -> Date { start.addingTimeInterval(seconds) }

    func step(_ id: String, _ tool: String, _ seconds: Double, state: EventState = .ok, agent: String = "h1") -> TimelineEvent {
        TimelineEvent(id: id, at: at(seconds), agentID: agent, kind: .tool, tool: tool, title: "\(tool) something", detail: "", output: "",
                      state: state, duration: 2)
    }

    func said(_ id: String, _ kind: ChatKind, _ text: String, _ seconds: Double, agent: String = "h1") -> ChatEntry {
        ChatEntry(id: id, at: at(seconds), kind: kind, agentID: agent, text: text, streaming: false, clipped: false)
    }

    @Test("task first, words in time order, the steps between them folded, a failure never folded, the report last")
    func order() {
        let detail = SessionDetail(
            id: "s", facts: SessionFacts(firstSeenAt: start, cwd: "/code"),
            agents: [AgentRecord(id: "h1", kind: "Explore", title: "Map the auth code", parentID: "main", startedAt: start, endedAt: nil)],
            chat: [said("t", .task, "Map the old auth code", 0), said("a", .reply, "Looking at the session code.", 5),
                   said("r", .report, "Found 3 places.", 30), said("x", .reply, "Not mine", 6, agent: "main")],
            tasks: [],
            timeline: [step("1", "Read", 1), step("2", "Read", 2), step("3", "Grep", 3), step("4", "Bash", 10, state: .failed),
                       step("5", "Read", 12), step("6", "Read", 1, agent: "main")],
            asks: [])
        let story = Story(detail: detail, agentID: "h1", live: "Reading auth.ts")
        #expect(story.task == "Map the old auth code")
        #expect(story.report == "Found 3 places.")
        #expect(story.live == "Reading auth.ts")
        let shape = story.items.map { item -> String in
            switch item {
            case .said(let entry): "said:\(entry.id)"
            case .steps(_, let events): "steps:\(events.map(\.id).joined())"
            case .failed(let event): "failed:\(event.id)"
            }
        }
        #expect(shape == ["steps:123", "said:a", "failed:4", "steps:5"])
        let summary = Story.summary(of: [step("1", "Read", 1), step("2", "Read", 2), step("3", "Grep", 3)])
        #expect(summary.counts.map(\.tool) == ["Read", "Grep"])
        #expect(summary.counts.map(\.count) == [2, 1])
        #expect(summary.seconds == 6)
    }

    @Test("without a task message the task comes from how it was launched")
    func taskFromLaunch() {
        let detail = SessionDetail(id: "s", facts: SessionFacts(firstSeenAt: start, cwd: "/"),
                                   agents: [AgentRecord(id: "h1", kind: "Explore", title: "Check the totals", parentID: "main", startedAt: start, endedAt: nil)],
                                   chat: [], tasks: [], timeline: [], asks: [])
        let story = Story(detail: detail, agentID: "h1", live: nil)
        #expect(story.task == "Check the totals")
        #expect(story.items.isEmpty)
        #expect(story.report == nil)
    }
}
