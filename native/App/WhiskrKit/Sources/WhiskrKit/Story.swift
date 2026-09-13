import Foundation

/// A helper's story, as its view shows it (docs/DESIGN.md, "The story view"): one column in
/// time order. The task it was given first; then what it said, as plain text; the steps between two
/// messages folded into one quiet line ("Read 3 files · ran 2 commands · 14 s") that opens to them, a
/// failed step never folded away; its report last, set apart; while it is still working, a live line.
public struct Story: Sendable, Equatable {
    public enum Item: Sendable, Equatable, Identifiable {
        case said(ChatEntry)
        /// Steps between two messages, folded into one line.
        case steps(id: String, events: [TimelineEvent])
        /// A step that failed: always shown on its own.
        case failed(TimelineEvent)

        public var id: String {
            switch self {
            case .said(let entry): "said/\(entry.id)"
            case .steps(let id, _): "steps/\(id)"
            case .failed(let event): "failed/\(event.id)"
            }
        }
    }

    public var task: String?
    public var items: [Item]
    public var report: String?
    /// What it is doing now, while it works; nil once it has stopped.
    public var live: String?

    public init(task: String?, items: [Item], report: String?, live: String?) {
        self.task = task
        self.items = items
        self.report = report
        self.live = live
    }

    /// The story of `agentID` in `detail`. `live` is its current line while it works.
    public init(detail: SessionDetail, agentID: String, live: String?) {
        let chat = detail.chat.filter { $0.agentID == agentID }.sorted { $0.at < $1.at }
        task = chat.first { $0.kind == .task }?.text ?? detail.agents.first { $0.id == agentID }.map(\.title).flatMap { $0.isEmpty ? nil : $0 }
        report = chat.last { $0.kind == .report }?.text
        let said = chat.filter { $0.kind == .reply || $0.kind == .error }
        let steps = detail.timeline.filter { $0.agentID == agentID && ($0.kind == .tool || $0.kind == .permission) }.sorted { $0.at < $1.at }
        var items: [Item] = []
        var pending: [TimelineEvent] = []
        func fold() {
            guard !pending.isEmpty else { return }
            items.append(.steps(id: pending[0].id, events: pending))
            pending = []
        }
        var stepIndex = 0
        for entry in said {
            while stepIndex < steps.count, steps[stepIndex].at <= entry.at {
                let step = steps[stepIndex]
                if step.state == .failed { fold(); items.append(.failed(step)) } else { pending.append(step) }
                stepIndex += 1
            }
            fold()
            items.append(.said(entry))
        }
        while stepIndex < steps.count {
            let step = steps[stepIndex]
            if step.state == .failed { fold(); items.append(.failed(step)) } else { pending.append(step) }
            stepIndex += 1
        }
        fold()
        self.items = items
        self.live = live
    }

    /// The folded line for some steps: "Read 3 files · ran 2 commands · 14 s".
    public static func summary(of events: [TimelineEvent]) -> (counts: [(tool: String, count: Int)], seconds: Int) {
        var order: [String] = []
        var counts: [String: Int] = [:]
        for event in events {
            let tool = event.tool.isEmpty ? event.kind.rawValue : event.tool
            if counts[tool] == nil { order.append(tool) }
            counts[tool, default: 0] += 1
        }
        let seconds = Int(events.compactMap(\.duration).reduce(0, +).rounded())
        return (order.map { ($0, counts[$0]!) }, seconds)
    }
}
