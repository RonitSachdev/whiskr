import AppKit
import SwiftUI
import WhiskrKit

/// Where a new workspace begins (File › New Workspace, ⌘N), as Cursor's and Xcode's welcome: the app's
/// cat, then three ways in: open a folder, a terminal right here, or a folder used lately. One click,
/// or Return, and you are in a terminal; ↑ and ↓ move between the rows. Nothing to fill in.
///
/// The same page greets you over the meadow when nothing is open at all (`StartCard`).
struct StartPage: View {
    let workbench: Workbench
    /// The page's id in its tab; nil for the greeting over an empty meadow, where each choice opens a
    /// new workspace instead.
    let page: UUID?
    var compact = false
    /// How many recent folders fit.
    var recentLimit = 8

    @State private var highlighted = 1
    @FocusState private var focused: Bool

    private enum Row: Hashable {
        case openFolder, newTerminal, recent(String)
    }

    private var rows: [Row] {
        [.openFolder, .newTerminal] + workbench.recentFolders.prefix(recentLimit).map { .recent($0.path) }
    }

    var body: some View {
        let rows = rows
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.bottom, compact ? 20 : 28)
            StartSection(title: String(localized: "Start", comment: "Start page: heading over Open Folder and New Terminal")) {
                StartRow(symbol: "folder", title: String(localized: "Open Folder…"), detail: nil, key: "⌘O", highlighted: highlighted == 0) { choose(.openFolder) }
                StartRow(symbol: "apple.terminal", title: String(localized: "New Terminal"), detail: page == nil ? String(localized: "in your home folder") : nil,
                         key: "↩", highlighted: highlighted == 1) { choose(.newTerminal) }
            }
            let recents = Array(rows.dropFirst(2))
            if !recents.isEmpty {
                StartSection(title: String(localized: "Recent", comment: "Start page: heading over the recent folders")) {
                    ForEach(Array(recents.enumerated()), id: \.element) { offset, row in
                        if case .recent(let path) = row {
                            let repository = RepositoryLookup.repository(of: path)
                            StartRow(symbol: "folder", title: Places.name(path, home: Self.home),
                                     detail: Places.abbreviate(path, home: Self.home), key: nil,
                                     highlighted: highlighted == offset + 2, worktrees: repository.map { repository in { mode in worktree(mode, repository: repository) } }) { choose(row) }
                        }
                    }
                }
                .padding(.top, 16)
            }
            Text(String(localized: "Or drop a folder here.", comment: "Start page: the last line"))
                .font(.system(size: 11))
                .foregroundStyle(Color.ink3)
                .padding(.top, 16)
                .padding(.leading, 8)
        }
        .frame(maxWidth: 400, alignment: .leading)
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(.upArrow) { move(-1, in: rows); return .handled }
        .onKeyPress(.downArrow) { move(1, in: rows); return .handled }
        .onKeyPress(.return) {
            guard rows.indices.contains(highlighted) else { return .ignored }
            choose(rows[highlighted])
            return .handled
        }
        .onAppear { focused = true }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Start", comment: "Accessibility label of the Start page"))
    }

    private var header: some View {
        HStack(spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: compact ? 56 : 64, height: compact ? 56 : 64)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(String(localized: "Whiskr", comment: "The app's name on the Start page"))
                    .font(.system(size: compact ? 20 : 22, weight: .semibold))
                    .foregroundStyle(Color.ink)
                Text(AttributedString(localized: "Open a terminal and type `claude`: a cat sits down in the meadow.", comment: "Start page: how cats come (Markdown: `claude` is the command)"))
                    .font(.system(size: 13))
                    .foregroundStyle(Color.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.leading, 8)
    }

    private static var home: String { FileManager.default.homeDirectoryForCurrentUser.path }

    private func move(_ step: Int, in rows: [Row]) {
        highlighted = min(max(highlighted + step, 0), rows.count - 1)
    }

    /// A recent repository's New Worktree… or Open Worktree…: the worktree opens as a workspace, and an
    /// unused Start page it was chosen from goes.
    private func worktree(_ mode: WorktreeController.Mode, repository: String) {
        guard let window = NSApp.windows.first(where: { $0.windowController is MainWindowController }) else { return }
        WorktreeController.shared.show(mode, repository: repository, over: window, workbench: workbench) { [page] in
            guard let page, let (workspace, _) = workbench.workspace(of: page), workbench.isUnusedStart(workspace) else { return }
            workbench.pages[page] = nil
            workbench.removeEmpty(workspace)
        }
    }

    private func choose(_ row: Row) {
        switch row {
        case .openFolder:
            NSApp.sendAction(#selector(MainWindowController.openFolder(_:)), to: nil, from: nil)
        case .newTerminal:
            if let page { workbench.startTerminal(from: page) } else { workbench.newWorkspace() }
        case .recent(let path):
            // A recent folder may have gone since: it is checked when chosen, and dropped if so.
            guard (try? Discovery.validateFolder(path, home: URL(fileURLWithPath: Self.home)).get()) != nil else {
                workbench.forget(folder: path)
                NSSound.beep()
                return
            }
            if let page { workbench.start(from: page, folder: path) } else { workbench.open(folder: path) }
        }
    }
}

/// A heading and its rows.
private struct StartSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.ink3)
                .padding(.leading, 8)
                .padding(.bottom, 4)
                .accessibilityAddTraits(.isHeader)
            content
        }
    }
}

/// One choice: an icon, its name (and where, for a folder), and its key on the right.
private struct StartRow: View {
    let symbol: String
    let title: String
    let detail: String?
    let key: String?
    let highlighted: Bool
    /// For a repository: its New Worktree… and Open Worktree…, from a small button on the row and its menu.
    var worktrees: ((WorktreeController.Mode) -> Void)? = nil
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 14))
                    .foregroundStyle(Color.ink2)
                    .frame(width: 20)
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.ink)
                    .lineLimit(1)
                    // The name stays whole; where it is gives way first.
                    .layoutPriority(1)
                if let detail {
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.ink3)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                if let worktrees, hovering || highlighted {
                    Menu {
                        Button(String(localized: "New Worktree…")) { worktrees(.create) }
                        Button(String(localized: "Open Worktree…")) { worktrees(.open) }
                    } label: {
                        Image(systemName: "arrow.triangle.branch")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.ink2)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help(String(localized: "Worktrees of this repository"))
                }
                if let key {
                    Text(key)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.ink3)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(highlighted ? 0.08 : hovering ? 0.05 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(detail.map { "\(title) — \($0)" } ?? title)
        .contextMenu {
            if let worktrees {
                Button(String(localized: "New Worktree…")) { worktrees(.create) }
                Button(String(localized: "Open Worktree…")) { worktrees(.open) }
            }
        }
    }
}

/// With nothing open, the Start page greets you on a card over the meadow, which keeps the window.
struct StartCard: View {
    let workbench: Workbench

    var body: some View {
        StartPage(workbench: workbench, page: nil, compact: true, recentLimit: 5)
            .padding(24)
            .frame(width: 440)
            .background(RoundedRectangle(cornerRadius: 16).fill(Color.surface))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.line))
            .shadow(color: .black.opacity(0.16), radius: 24, y: 8)
    }
}

/// Which recent folders are git repositories, and whose: read from the folders' own files once and
/// remembered for the session (the Start page asks as it draws).
@MainActor
enum RepositoryLookup {
    private static var known: [String: String?] = [:]

    /// The repository's main checkout `folder` is in; nil outside one.
    static func repository(of folder: String) -> String? {
        if let found = known[folder] { return found }
        let head = GitHead.find(from: folder)
        let repository = head.map { $0.repository ?? $0.root }
        known[folder] = repository
        return repository
    }
}
