import AppKit
import SwiftUI
import WhiskrKit

/// Home (docs/DESIGN.md), as Cursor's and Xcode's welcome: the app's cat, then the ways in. Open a
/// folder, a terminal in your home folder, a workspace open now (exactly where you left it), or a folder
/// used lately. One click, or Return, and you are there; ↑ and ↓ move between the rows, and letters jump
/// to the first row named so. Nothing to fill in. It fills the work area while no workspace is selected,
/// in the terminal's colours, beside the meadow.
struct HomePage: View {
    let workbench: Workbench

    @State private var highlighted = 1
    @State private var typed = ""
    @State private var typedAt = Date.distantPast
    @FocusState private var focused: Bool

    private enum Row: Hashable {
        case openFolder, newTerminal, workspace(UUID), recent(String)
    }

    /// Height of a row, for how many recent folders fit beside the open workspaces.
    private static let rowHeight: CGFloat = 34

    var body: some View {
        GeometryReader { area in
            let open = workbench.homeRows
            // A short window offers fewer recent folders rather than scrolling them; the open workspaces are
            // always all there (the page scrolls when they alone overflow).
            let room = Int((area.size.height - min(max(area.size.height * 0.14, 24), 120) - 300 - CGFloat(open.count) * Self.rowHeight - (open.isEmpty ? 0 : 40)) / Self.rowHeight)
            let recents = Array(workbench.homeRecents.prefix(max(0, min(8, room))))
            let rows: [Row] = [.openFolder, .newTerminal] + open.map { .workspace($0.id) } + recents.map { .recent($0.path) }
            ScrollViewReader { scroller in
                ScrollView(.vertical) {
                    // Hung from a fixed point in the upper part, not centred: a workspace coming or going adds or
                    // takes a row below and never moves what is above it.
                    page(open: open, recents: recents, rows: rows)
                        .padding(.horizontal, 32)
                        .padding(.top, min(max(area.size.height * 0.14, 24), 120))
                        .padding(.bottom, 24)
                        .frame(width: area.size.width, alignment: .top)
                }
                .scrollIndicators(.automatic)
                .onChange(of: highlighted) { _, index in
                    if rows.indices.contains(index) { scroller.scrollTo(rows[index]) }
                }
            }
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
            .onKeyPress(characters: .alphanumerics, phases: .down) { press in
                typeSelect(press.characters, in: rows, open: open)
            }
            .onChange(of: rows.count) { _, count in highlighted = min(highlighted, count - 1) }
        }
        .background(Color(nsColor: Colors.terminalBackground))
        .onAppear { focused = true }
        // Each time Home is entered (⌘N, Go › Home, a workspace closing) it starts again on New Terminal.
        .onChange(of: workbench.homeVisits) { _, _ in
            highlighted = 1
            focused = true
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Home", comment: "Accessibility label of the Home page"))
    }

    private func page(open: [HomeList.Row], recents: [RecentFolder], rows: [Row]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.bottom, 28)
            HomeSection(title: String(localized: "Start", comment: "Home: heading over Open Folder and New Terminal")) {
                HomeRow(highlighted: highlighted == 0, help: String(localized: "Open Folder…"), action: { choose(.openFolder) }) {
                    RowLabel(symbol: "folder", title: String(localized: "Open Folder…"), detail: nil, key: "⌘O")
                }
                .id(Row.openFolder)
                HomeRow(highlighted: highlighted == 1, help: String(localized: "New Terminal"), action: { choose(.newTerminal) }) {
                    RowLabel(symbol: "apple.terminal", title: String(localized: "New Terminal"), detail: String(localized: "in your home folder"), key: "↩")
                }
                .id(Row.newTerminal)
            }
            if !open.isEmpty {
                HomeSection(title: String(localized: "Home.Open", defaultValue: "Open", comment: "Home: heading over the workspaces open now (not the verb)")) {
                    ForEach(Array(open.enumerated()), id: \.element.id) { offset, row in
                        HomeRow(highlighted: highlighted == offset + 2, help: Self.help(row), action: { choose(.workspace(row.id)) }) {
                            OpenWorkspaceLabel(row: row)
                        }
                        .id(Row.workspace(row.id))
                        .accessibilityLabel(Self.sentence(row))
                    }
                }
                .padding(.top, 16)
            }
            if !recents.isEmpty {
                HomeSection(title: String(localized: "Recent", comment: "Home: heading over the recent folders")) {
                    ForEach(Array(recents.enumerated()), id: \.element.id) { offset, folder in
                        let repository = RepositoryLookup.repository(of: folder.path)
                        let detail = Places.abbreviate(folder.path, home: Self.home)
                        let title = Places.name(folder.path, home: Self.home)
                        HomeRow(highlighted: highlighted == offset + 2 + open.count, help: "\(title) — \(detail)",
                                worktrees: repository.map { repository in { mode in worktree(mode, repository: repository) } },
                                action: { choose(.recent(folder.path)) }) {
                            RowLabel(symbol: "folder", title: title, detail: detail, key: nil)
                        }
                        .id(Row.recent(folder.path))
                    }
                }
                .padding(.top, 16)
            }
            Text(String(localized: "Or drop a folder here.", comment: "Home: the last line"))
                .font(.system(size: 11))
                .foregroundStyle(Color.ink3)
                .padding(.top, 16)
                .padding(.leading, 8)
        }
        .frame(maxWidth: 480, alignment: .leading)
    }

    private var header: some View {
        HStack(spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 64, height: 64)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(String(localized: "Whiskr", comment: "The app's name on the Home page"))
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Color.ink)
                Text(AttributedString(localized: "Open a terminal and type `claude`: a cat sits down in the meadow.", comment: "Home: how cats come (Markdown: `claude` is the command)"))
                    .font(.system(size: 13))
                    .foregroundStyle(Color.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.leading, 8)
    }

    private static var home: String { FileManager.default.homeDirectoryForCurrentUser.path }

    /// "shop-web, branch fix-cart. Needs you. 2 Claudes."
    private static func sentence(_ row: HomeList.Row) -> String {
        var parts = [row.name]
        if let branch = row.branch { parts[0] += ", " + String(localized: "branch \(branch)", comment: "VoiceOver: a workspace's git branch") }
        parts.append(OpenWorkspaceLabel.word(row.state))
        if row.claudes > 0 { parts.append(String(localized: "\(row.claudes) Claudes", comment: "Home: how many Claudes run in a workspace")) }
        return parts.joined(separator: ". ")
    }

    private static func help(_ row: HomeList.Row) -> String {
        String(localized: "Back to \(row.name), where you left it — \(Places.abbreviate(row.folder, home: home))", comment: "Home: an open workspace's tooltip")
    }

    private func move(_ step: Int, in rows: [Row]) {
        highlighted = min(max(highlighted + step, 0), rows.count - 1)
    }

    /// Letters typed within a second of each other build up a name, as in Finder.
    private func typeSelect(_ characters: String, in rows: [Row], open: [HomeList.Row]) -> KeyPress.Result {
        let now = Date()
        typed = now.timeIntervalSince(typedAt) < 1 ? typed + characters : characters
        typedAt = now
        let names = rows.map { row -> String in
            switch row {
            case .openFolder: String(localized: "Open Folder…")
            case .newTerminal: String(localized: "New Terminal")
            case .workspace(let id): open.first { $0.id == id }?.name ?? ""
            case .recent(let path): Places.name(path, home: Self.home)
            }
        }
        // A new word looks from the row after the highlighted one; a longer one from the highlighted one.
        guard let index = HomeList.typeSelect(typed, in: names, from: typed.count == 1 ? highlighted + 1 : highlighted) else { return .ignored }
        highlighted = index
        return .handled
    }

    /// A recent repository's New Worktree… or Open Worktree…: the worktree opens as a workspace.
    private func worktree(_ mode: WorktreeController.Mode, repository: String) {
        guard let window = NSApp.windows.first(where: { $0.windowController is MainWindowController }) else { return }
        WorktreeController.shared.show(mode, repository: repository, over: window, workbench: workbench)
    }

    private func choose(_ row: Row) {
        switch row {
        case .openFolder:
            NSApp.sendAction(#selector(MainWindowController.openFolder(_:)), to: nil, from: nil)
        case .newTerminal:
            workbench.newWorkspace()
        case .workspace(let id):
            workbench.selectBlanket(id)
        case .recent(let path):
            // A recent folder may have gone since: it is checked when chosen, and dropped if so.
            guard (try? Discovery.validateFolder(path, home: URL(fileURLWithPath: Self.home)).get()) != nil else {
                workbench.forget(folder: path)
                NSSound.beep()
                return
            }
            workbench.open(folder: path)
        }
    }
}

/// A heading and its rows.
private struct HomeSection<Content: View>: View {
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

/// One choice: a 32 pt row, highlighted by the keyboard or the pointer.
private struct HomeRow<Label: View>: View {
    let highlighted: Bool
    let help: String
    /// For a repository: its New Worktree… and Open Worktree…, from a small button on the row and its menu.
    var worktrees: ((WorktreeController.Mode) -> Void)? = nil
    let action: () -> Void
    @ViewBuilder let label: Label
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                label
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
            }
            .padding(.horizontal, 8)
            .frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(highlighted ? 0.08 : hovering ? 0.05 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .contextMenu {
            if let worktrees {
                Button(String(localized: "New Worktree…")) { worktrees(.create) }
                Button(String(localized: "Open Worktree…")) { worktrees(.open) }
            }
        }
    }
}

/// An icon, a name (and where, for a folder), and its key on the right.
private struct RowLabel: View {
    let symbol: String
    let title: String
    let detail: String?
    let key: String?

    var body: some View {
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
        if let key {
            Text(key)
                .font(.system(size: 12))
                .foregroundStyle(Color.ink3)
        }
    }
}

/// An open workspace: its blanket's colour, its name and branch, how it stands, how many Claudes, and
/// its ⌥⌘ number.
private struct OpenWorkspaceLabel: View {
    let row: HomeList.Row

    var body: some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(Colors.accountColor(index: row.colorIndex))
            .frame(width: 10, height: 10)
            .frame(width: 20)
        Text(row.name)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Color.ink)
            .lineLimit(1)
            .layoutPriority(1)
        if let branch = row.branch {
            HStack(spacing: 3) {
                Image(systemName: "arrow.triangle.branch").font(.system(size: 10))
                Text(branch).lineLimit(1).truncationMode(.middle)
            }
            .font(.system(size: 12))
            .foregroundStyle(Color.ink3)
        }
        Spacer(minLength: 8)
        HStack(spacing: 5) {
            switch row.state {
            case .needsYou(let failed): StateMark(status: .blocked, failed: failed)
            case .finished: StateMark(status: .done)
            case .working, .idle: EmptyView()
            }
            Text(Self.word(row.state))
                .foregroundStyle(row.state.needsYou ? StateMark.vermillion : Color.ink2)
            if row.claudes > 0 {
                Text(verbatim: "·").foregroundStyle(Color.ink3)
                Text(String(localized: "\(row.claudes) Claudes", comment: "Home: how many Claudes run in a workspace"))
                    .foregroundStyle(Color.ink3)
            }
        }
        .font(.system(size: 12))
        .fixedSize()
        Text(verbatim: row.number.map { "⌥⌘\($0)" } ?? "")
            .font(.system(size: 12).monospacedDigit())
            .foregroundStyle(Color.ink3)
            .frame(minWidth: 30, alignment: .trailing)
    }

    /// How a workspace stands, in the app's words.
    static func word(_ state: HomeList.State) -> String {
        switch state {
        case .needsYou: String(localized: "Needs you", comment: "Home: a workspace with a request or an error")
        case .finished: String(localized: "Finished", comment: "State: Claude finished a turn you have not seen")
        case .working: String(localized: "Working", comment: "State")
        case .idle: String(localized: "Idle", comment: "State")
        }
    }
}

private extension HomeList.State {
    var needsYou: Bool {
        if case .needsYou = self { return true }
        return false
    }
}

/// Which recent folders are git repositories, and whose: read from the folders' own files once and
/// remembered for the session (Home asks as it draws).
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
