import SwiftUI
import WhiskrKit

/// The sidebar as a list (View › Show Workspaces as List; docs/DESIGN.md): one row per workspace
/// in the same stable order as the meadow, with its colour, name and folder, and one mark per Claude
/// in it. For many workspaces, VoiceOver, or anyone who wants no scene. A standard sidebar list, so the
/// keyboard and VoiceOver work as everywhere else on the Mac.
struct NavigatorList: View {
    let workbench: Workbench

    var body: some View {
        ScrollViewReader { proxy in
            list
                // What you choose on the right is scrolled into sight, as the meadow brings its blanket in.
                .onChange(of: workbench.choices) {
                    if let id = workbench.selectedWorkspace?.id { proxy.scrollTo(id) }
                }
        }
    }

    private var list: some View {
        List(selection: Binding(
            get: { workbench.selectedWorkspace?.id },
            set: { id in
                if let id, let workspace = workbench.workspaces.first(where: { $0.id == id }) { workbench.select(workspace: workspace) }
            })) {
            Section(String(localized: "Workspaces", comment: "Sidebar list heading")) {
                ForEach(Array(workbench.workspaces.enumerated()), id: \.element.id) { index, workspace in
                    WorkspaceRow(workbench: workbench, workspace: workspace, number: index + 1)
                        .tag(workspace.id)
                        .id(workspace.id)
                }
            }
        }
        .listStyle(.sidebar)
        // Solid, in the theme's chrome as the side panel is: a sidebar list's own vibrant material and
        // label colours ignore the theme, and drew the names fainter than the folders under them.
        .scrollContentBackground(.hidden)
        .background(Color.chrome)
    }
}

private struct WorkspaceRow: View {
    let workbench: Workbench
    let workspace: Workspace
    let number: Int

    var body: some View {
        let claudes = workspace.tabs.flatMap(\.tree.panes).compactMap { workbench.panes[$0] }.compactMap { pane -> (AgentStatus, Int, Bool)? in
            guard let status = workbench.status(of: pane) else { return nil }
            let session = workbench.session(of: pane)
            return (status, session.map { $0.agents.count - 1 } ?? 0, session?.failed ?? false)
        }
        // Helpers include the terminals its Claudes started (`paw`), tab or no tab.
        let helpers = claudes.reduce(0) { $0 + $1.1 } + workbench.looseHelpers(in: workspace).filter(\.agentRunning).count
        // A worktree sits under its repository.
        let nested = workbench.repositoryWorkspace(of: workspace) != nil
        HStack(spacing: 8) {
            if nested {
                Image(systemName: "arrow.turn.down.right")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            RoundedRectangle(cornerRadius: 3)
                .fill(Colors.accountColor(index: workspace.colorIndex))
                .frame(width: 10, height: 10)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(workspace.name).font(.body).foregroundStyle(Color.ink).lineLimit(1)
                Text(workspace.displayPath).font(.caption).foregroundStyle(Color.ink2).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 4)
            if helpers > 0 {
                Text(String(localized: "+\(helpers) helpers", comment: "Sidebar list: how many helpers are working")).font(.caption).foregroundStyle(Color.ink2)
            }
            ForEach(Array(claudes.enumerated()), id: \.offset) { _, claude in
                // An error is "×", as in the meadow and the tabs.
                StateMark(status: claude.0, failed: claude.2)
            }
        }
        .padding(.leading, nested ? 8 : 0)
        .frame(minHeight: 36)
        .help(workspace.displayPath)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibility(claudes.map(\.0), helpers: helpers))
        .contextMenu {
            Button(String(localized: "New Tab")) {
                workbench.select(workspace: workspace)
                workbench.newTab()
            }
            Divider()
            Button(String(localized: "Close Workspace")) {
                workbench.select(workspace: workspace)
                NSApp.sendAction(#selector(MainWindowController.closeWorkspace(_:)), to: nil, from: nil)
            }
        }
    }

    /// "shop-web. Claude: needs you. 2 helpers." (§12)
    private func accessibility(_ states: [AgentStatus], helpers: Int) -> String {
        var parts = [workspace.name]
        if let repository = workbench.repositoryWorkspace(of: workspace) {
            parts[0] += ", " + String(localized: "worktree of \(repository.name)", comment: "Accessibility: a workspace that is a git worktree of another")
        }
        parts += states.map { String(localized: "Claude: \($0.label)", comment: "Accessibility: one Claude in a workspace and its state") }
        if helpers > 0 { parts.append(String(localized: "\(helpers) helpers working", comment: "Accessibility: helpers in a workspace")) }
        return parts.joined(separator: ". ")
    }
}
