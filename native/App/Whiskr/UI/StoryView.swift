import SwiftUI
import WhiskrKit

/// A helper's story, in the place of its boss's terminal while you look at it (docs/DESIGN.md, the story
/// view): the task, what it said, its steps folded between messages (a failure never folded), its report
/// last, and a live line while it works. Read-only; Esc or a click on the boss goes back to the terminal.
struct StoryView: View {
    let workbench: Workbench
    let pane: Pane
    let sessionID: String
    let agentID: String
    @FocusState private var focused: Bool

    var body: some View {
        let helper = workbench.session(of: pane)?.agents.first { $0.id == agentID }
        let working = helper.map { $0.status == .working || $0.status == .blocked } ?? false
        let story = workbench.monitor.details[sessionID].map { Story(detail: $0, agentID: agentID, live: working ? helper?.line : nil) }
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(helper?.kind ?? String(localized: "Helper"))
                    .font(.headline)
                Text(String(localized: "Helper", comment: "Story view: what this is"))
                    .font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                Button(String(localized: "Back to Terminal")) { back() }
                    .controlSize(.small)
                    .help(String(localized: "Esc"))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            Divider()
            ScrollViewReader { reader in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if let story {
                            content(story)
                        } else {
                            Text(String(localized: "Nothing yet.", comment: "Story view before anything is known")).foregroundStyle(.secondary)
                        }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .padding(16)
                    .frame(maxWidth: 760, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: story?.items.count) { _, _ in withAnimation(.easeOut(duration: 0.2)) { reader.scrollTo("end", anchor: .bottom) } }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .focusable()
        .focused($focused)
        // Esc is ours only here, where no terminal has the keyboard.
        .onExitCommand { back() }
        .onAppear { focused = true }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Story of helper \(helper?.kind ?? "")", comment: "Accessibility label of a helper's story"))
    }

    @ViewBuilder private func content(_ story: Story) -> some View {
        if let task = story.task {
            VStack(alignment: .leading, spacing: 4) {
                Text(String(localized: "Task", comment: "Story view: the task the helper was given")).font(.caption).foregroundStyle(.secondary)
                Text(task).textSelection(.enabled)
            }
        }
        ForEach(story.items) { item in
            switch item {
            case .said(let entry):
                Text(entry.text).textSelection(.enabled).foregroundStyle(entry.kind == .error ? Color.red : Color.primary)
            case .steps(_, let events):
                StepsLine(events: events)
            case .failed(let event):
                StepRow(event: event, open: true)
            }
        }
        if let report = story.report {
            VStack(alignment: .leading, spacing: 6) {
                Text(String(localized: "Report", comment: "Story view: the helper's final report")).font(.caption).foregroundStyle(.secondary)
                Text(report).textSelection(.enabled)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor)))
        }
        if let live = story.live, !live.isEmpty {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(live).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

    private func back() {
        workbench.focusedAgent = nil
        workbench.focus(pane: pane.id)
    }
}

/// Steps between two messages, folded into one quiet line that opens to them.
private struct StepsLine: View {
    let events: [TimelineEvent]
    @State private var open = false

    var body: some View {
        let summary = Story.summary(of: events)
        let words = summary.counts.map { String(localized: "\($0.tool) ×\($0.count)", comment: "Story view: a tool and how many times it was used") }
            .joined(separator: " · ")
        DisclosureGroup(isExpanded: $open) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(events) { StepRow(event: $0, open: false) }
            }
            .padding(.top, 4)
        } label: {
            Text(summary.seconds > 0 ? "\(words) · \(Duration.seconds(summary.seconds).formatted(.units(width: .narrow)))" : words)
                .font(.callout).foregroundStyle(.secondary)
        }
    }
}

/// One step, opening to its command or output.
private struct StepRow: View {
    let event: TimelineEvent
    @State var open: Bool

    var body: some View {
        DisclosureGroup(isExpanded: $open) {
            VStack(alignment: .leading, spacing: 4) {
                if !event.detail.isEmpty { Text(event.detail).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
                if !event.output.isEmpty {
                    Text(event.output).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                        .lineLimit(12)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor)))
        } label: {
            HStack(spacing: 6) {
                if event.state == .failed {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(StateMark.vermillion).accessibilityLabel(String(localized: "Failed"))
                }
                Text(event.title).font(.callout)
            }
        }
    }
}
