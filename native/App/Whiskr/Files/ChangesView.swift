import AppKit
import SwiftUI
import WhiskrKit

/// The workspace's git changes (herdr's Changes panel): the branch, then Staged, Changes and Untracked
/// with their counts, each folding away under its chevron (remembered); a click shows a file's diff,
/// hovering offers stage, unstage and discard (always confirmed); a message box and Commit at the bottom.
struct ChangesView: View {
    let workbench: Workbench
    @State private var messageFocused = false

    var body: some View {
        if let repository = workbench.selectedRepository {
            content(repository)
        } else {
            Color.clear
        }
    }

    @ViewBuilder private func content(_ repository: Repository) -> some View {
        if !repository.isGit {
            PanelNote(symbol: "arrow.triangle.branch", text: String(localized: "This folder isn’t a git repository."))
        } else if let status = repository.status {
            VStack(spacing: 0) {
                BranchLine(status: status)
                if status.changeCount == 0 {
                    PanelNote(symbol: "checkmark.circle", text: String(localized: "No changes"))
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            section("staged", String(localized: "Staged", comment: "Changes panel section"), status.staged, staged: true, repository: repository)
                            section("changes", String(localized: "Changes", comment: "Changes panel section: unstaged"), status.unstaged, staged: false, repository: repository)
                            section("untracked", String(localized: "Untracked", comment: "Changes panel section"), status.untracked, staged: false, repository: repository)
                        }
                        .padding(.bottom, 8)
                    }
                }
                CommitBox(repository: repository, status: status, focused: $messageFocused)
            }
        } else {
            PanelNote(symbol: "hourglass", text: String(localized: "Reading the repository…"))
        }
    }

    private func entry(untracked: GitStatusEntry) -> String { untracked.isUntracked ? "untracked" : "changed" }

    @ViewBuilder private func section(_ key: String, _ title: String, _ entries: [GitStatusEntry], staged: Bool, repository: Repository) -> some View {
        if !entries.isEmpty {
            let folded = FoldedSections.shared.keys.contains(key)
            SectionHeader(title: title, count: entries.count, staged: staged, folded: folded, toggle: { FoldedSections.shared.toggle(key) }) {
                if staged { repository.unstage(entries.map(\.path)) } else { repository.stage(entries.map(\.path)) }
            }
            // A file both staged and changed again is in two sections: each row is told apart by its section.
            if !folded { rows(entries, staged: staged, repository: repository) }
        }
    }

    @ViewBuilder private func rows(_ entries: [GitStatusEntry], staged: Bool, repository: Repository) -> some View {
        ForEach(entries.map { (key: "\(staged ? "staged" : entry(untracked: $0)):\($0.path)", entry: $0) }, id: \.key) { row in
            ChangeRow(entry: row.entry, staged: staged, repository: repository, workbench: workbench)
        }
    }
}

/// "⑂ main ↑1 ↓2": where the work is.
private struct BranchLine: View {
    let status: GitStatus

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.triangle.branch").font(.system(size: 11)).foregroundStyle(Color.ink3)
            Text(status.branch ?? status.commit.map { String(localized: "Detached at \($0)") } ?? String(localized: "No commits yet"))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.ink)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            if status.ahead > 0 {
                Text(verbatim: "↑\(status.ahead)").font(.system(size: 11).monospacedDigit()).foregroundStyle(Color.ink2)
                    .help(String(localized: "\(status.ahead) commits to push"))
            }
            if status.behind > 0 {
                Text(verbatim: "↓\(status.behind)").font(.system(size: 11).monospacedDigit()).foregroundStyle(Color.ink2)
                    .help(String(localized: "\(status.behind) commits to pull"))
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 30)
        .accessibilityElement(children: .combine)
    }
}

/// The sections of Changes folded away, kept for the next launch.
@MainActor @Observable
final class FoldedSections {
    static let shared = FoldedSections()
    private static let key = "foldedChangesSections"
    private(set) var keys: Set<String> = Set(AppPlaces.defaults.stringArray(forKey: key) ?? [])

    func toggle(_ section: String) {
        if keys.contains(section) { keys.remove(section) } else { keys.insert(section) }
        AppPlaces.defaults.set(keys.sorted(), forKey: Self.key)
    }
}

private struct SectionHeader: View {
    let title: String
    let count: Int
    let staged: Bool
    let folded: Bool
    let toggle: () -> Void
    let all: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Button(action: toggle) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(folded ? 0 : 90))
                        .frame(width: 10)
                    Text(title)
                        .font(.system(size: 11, weight: .semibold))
                    Text(verbatim: "\(count)")
                        .font(.system(size: 10, weight: .semibold).monospacedDigit())
                }
                .foregroundStyle(Color.ink3)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "\(title), \(count) files", comment: "Changes panel: a section's header, for VoiceOver"))
            .accessibilityValue(folded ? String(localized: "Collapsed") : String(localized: "Expanded"))
            .accessibilityHint(folded ? String(localized: "Shows the files") : String(localized: "Hides the files"))
            Spacer()
            RowAction(symbol: staged ? "minus" : "plus", help: staged ? String(localized: "Unstage All") : String(localized: "Stage All"), action: all)
                .opacity(hovering ? 1 : 0)
        }
        .padding(.leading, 6)
        .padding(.trailing, 8)
        .padding(.top, 10)
        .frame(height: 30)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isHeader)
    }
}

/// One changed file: its name and folder, its state's letter, and on hover what can be done with it.
private struct ChangeRow: View {
    let entry: GitStatusEntry
    let staged: Bool
    let repository: Repository
    let workbench: Workbench
    @State private var hovering = false

    private var state: GitFileState {
        if entry.isConflicted { return .conflicted }
        if entry.isUntracked { return .untracked }
        return staged ? entry.index : entry.worktree
    }

    private var url: URL { repository.root.appendingPathComponent(entry.path) }
    private var name: String { (entry.path as NSString).lastPathComponent }
    private var folder: String { (entry.path as NSString).deletingLastPathComponent }

    var body: some View {
        HStack(spacing: 7) {
            FileIconView(name: name, size: 11)
                .foregroundStyle(Color.ink2)
                .frame(width: 16)
            Text(name)
                .font(.system(size: 12.5))
                .foregroundStyle(Color.ink)
                .strikethrough(state == .deleted, color: Color.ink3)
                .lineLimit(1)
                .layoutPriority(1)
            if !folder.isEmpty {
                Text(folder)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.ink3)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 4)
            if hovering {
                HStack(spacing: 0) {
                    if !staged, state != .deleted {
                        RowAction(symbol: "doc.text", help: String(localized: "Open File")) { workbench.open(file: url.path, mode: .keep) }
                    }
                    if !staged {
                        RowAction(symbol: "arrow.uturn.backward", help: String(localized: "Discard Changes…")) { confirmDiscard() }
                    }
                    RowAction(symbol: staged ? "minus" : "plus", help: staged ? String(localized: "Unstage") : String(localized: "Stage")) {
                        if staged { repository.unstage([entry.path]) } else { repository.stage([entry.path]) }
                    }
                }
            }
            Text(state.letter)
                .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color(nsColor: GitColors.color(state)))
                .frame(width: 12)
        }
        .padding(.leading, 14)
        .padding(.trailing, 12)
        .frame(height: 26)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(hovering ? 0.06 : 0)).padding(.horizontal, 6))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { workbench.openChanges(path: url.path, staged: staged, mode: .preview) }
        .help(entry.originalPath.map { "\($0) → \(entry.path)" } ?? entry.path)
        .contextMenu { menu }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(entry.path), \(GitColors.name(state))")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { workbench.openChanges(path: url.path, staged: staged, mode: .preview) }
        .accessibilityAction(named: staged ? String(localized: "Unstage") : String(localized: "Stage")) {
            if staged { repository.unstage([entry.path]) } else { repository.stage([entry.path]) }
        }
    }

    @ViewBuilder private var menu: some View {
        Button(String(localized: "Open Changes")) { workbench.openChanges(path: url.path, staged: staged, mode: .keep) }
        if state != .deleted {
            Button(String(localized: "Open File")) { workbench.open(file: url.path, mode: .keep) }
        }
        Divider()
        if staged {
            Button(String(localized: "Unstage")) { repository.unstage([entry.path]) }
        } else {
            Button(String(localized: "Stage")) { repository.stage([entry.path]) }
            Button(String(localized: "Discard Changes…")) { confirmDiscard() }
        }
        Divider()
        if state != .deleted {
            Button(String(localized: "Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }
        Button(String(localized: "Copy Path")) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url.path, forType: .string)
        }
    }

    /// Discarding throws work away, so it always asks; an untracked file goes to the Trash instead.
    private func confirmDiscard() {
        guard let window = workbench.files.window else { return }
        let alert = NSAlert()
        if entry.isUntracked {
            alert.messageText = String(localized: "Move “\(name)” to the Trash?")
            alert.informativeText = String(localized: "It isn’t tracked by git, so this is the only copy. You can get it back from the Trash.")
            alert.addButton(withTitle: String(localized: "Move to Trash"))
        } else {
            alert.messageText = String(localized: "Discard the changes to “\(name)”?")
            alert.informativeText = String(localized: "The file goes back to its last staged or committed version. This can’t be undone.")
            alert.addButton(withTitle: String(localized: "Discard Changes"))
        }
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.buttons[0].hasDestructiveAction = true
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn { repository.discard([entry]) }
        }
    }
}

/// A small icon button in a row, shown on hover.
private struct RowAction: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.ink2)
                .frame(width: 22, height: 20)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(hovering ? 0.1 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

/// The message and Commit (⌘↩): enabled with something staged and a message written.
private struct CommitBox: View {
    @Bindable var repository: Repository
    let status: GitStatus
    @Binding var focused: Bool

    private var message: String { repository.commitMessage }

    private var canCommit: Bool {
        !status.staged.isEmpty && !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !repository.isCommitting
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topLeading) {
                if message.isEmpty {
                    Text(String(localized: "Message", comment: "Commit message placeholder"))
                        .font(.system(size: 12.5))
                        .foregroundStyle(Color.ink3)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .allowsHitTesting(false)
                }
                CommitMessageField(text: $repository.commitMessage, focused: $focused)
                    .accessibilityLabel(String(localized: "Commit message"))
            }
            .padding(6)
            .frame(minHeight: 58, maxHeight: 110)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color(nsColor: Colors.terminalBackground)))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(focused ? Color.accent.opacity(0.6) : Color.line))
            Button {
                repository.commit(message: message) { done in if done { repository.commitMessage = "" } }
            } label: {
                Text(commitTitle)
                    .font(.system(size: 12.5, weight: .medium))
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .disabled(!canCommit)
            // Only from the message: a window-wide ⌘↩ would commit from a terminal or the editor.
            .keyboardShortcut(focused ? KeyboardShortcut(.return, modifiers: .command) : nil)
            .help(status.staged.isEmpty ? String(localized: "Stage changes to commit them") : String(localized: "Commit the staged changes (⌘↩)"))
            if let error = repository.lastError {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.alert)
                    .lineLimit(5)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .overlay(alignment: .top) { Color.line.frame(height: 1) }
    }

    private var commitTitle: String {
        if repository.isCommitting { return String(localized: "Committing…") }
        let count = status.staged.count
        return count == 0 ? String(localized: "Commit") : String(localized: "Commit \(count) Files", comment: "Commit button with the number of staged files")
    }
}

/// The commit message: a plain text view with an undo of its own. SwiftUI's TextEditor put its typing on
/// the window's undo stack, where it outlived the message: once a commit had cleared the field, ⌘Z in a
/// terminal or a diff reached into the emptied text and crashed the app. Here the field's undo is its own,
/// and goes when the message is replaced from outside (a commit clearing it).
private struct CommitMessageField: NSViewRepresentable {
    @Binding var text: String
    @Binding var focused: Bool

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = MessageTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 40))
        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.font = .systemFont(ofSize: 12.5)
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 5
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.string = text
        textView.delegate = context.coordinator
        let focused = $focused
        textView.onFocus = { has in DispatchQueue.main.async { if focused.wrappedValue != has { focused.wrappedValue = has } } }
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = textView
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? NSTextView else { return }
        context.coordinator.text = $text
        textView.textColor = Colors.text
        textView.insertionPointColor = Colors.text
        if textView.string != text {
            textView.string = text
            context.coordinator.undo.removeAllActions()
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        let undo = UndoManager()

        init(text: Binding<String>) { self.text = text }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView, text.wrappedValue != textView.string else { return }
            text.wrappedValue = textView.string
        }

        func undoManager(for view: NSTextView) -> UndoManager? { undo }
    }
}

/// Says when it takes and gives up the keyboard (⌘↩ commits only while it has it).
private final class MessageTextView: NSTextView {
    var onFocus: ((Bool) -> Void)?

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { onFocus?(true) }
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { onFocus?(false) }
        return resigned
    }
}

/// A quiet line in the middle of the panel.
struct PanelNote: View {
    let symbol: String
    let text: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(Color.ink3)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(Color.ink2)
                .multilineTextAlignment(.center)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
