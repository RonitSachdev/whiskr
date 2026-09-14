import AppKit
import SwiftUI
import WhiskrKit

/// The answer card (docs/DESIGN.md): a request whose terminal is not on screen, answered from the
/// meadow without going there. It opens beside the asking cat, over the terminals, never over the
/// meadow. It shows where and what is asked, then Allow and Deny (1 and 2, Claude Code's own order),
/// or only Go to Terminal for what has to be answered there. An answer is sent only if the request is
/// still the one shown, unchanged, and the card has been up for 400 ms (so a click aimed elsewhere
/// cannot land on it). Esc closes it with no answer; the keyboard goes back where it was.
@MainActor
final class AnswerCardController: NSObject, NSPopoverDelegate {
    private let workbench: Workbench
    private var popover: NSPopover?
    private weak var returnFocus: NSResponder?

    init(workbench: Workbench) {
        self.workbench = workbench
    }

    /// Opens the card for `request`, pointing at `rect` in `view`.
    func show(_ request: OpenRequest, relativeTo rect: NSRect, of view: NSView) {
        popover?.close()
        returnFocus = view.window?.firstResponder
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        popover.delegate = self
        let card = AnswerCard(workbench: workbench, request: request, opened: Date(),
                              done: { [weak self] in self?.close() },
                              goToTerminal: { [weak self] in
                                  self?.close(restoringFocus: false)
                                  self?.workbench.focus(pane: request.paneID)
                              })
        let host = NSHostingController(rootView: card)
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
        popover.show(relativeTo: rect, of: view, preferredEdge: .maxX)
        self.popover = popover
    }

    var isShown: Bool { popover?.isShown ?? false }

    func close(restoringFocus: Bool = true) {
        let focus = returnFocus
        popover?.close()
        popover = nil
        if restoringFocus, let focus, let window = (focus as? NSView)?.window { window.makeFirstResponder(focus) }
    }

    func popoverDidClose(_ notification: Notification) {
        popover = nil
    }

    /// Debug: the card's window, for a snapshot.
    var cardWindow: NSWindow? { popover?.contentViewController?.view.window }
}

struct AnswerCard: View {
    let workbench: Workbench
    let request: OpenRequest
    let opened: Date
    let done: () -> Void
    let goToTerminal: () -> Void

    @State private var armed = false
    @State private var changed = false
    @State private var showAll = false
    @FocusState private var focused: Bool

    var body: some View {
        let answers = request.answers
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(place)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(headline)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.ink2)
            }
            if !detail.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(detail)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Color.ink)
                        .lineLimit(showAll ? nil : 6)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if detail.split(separator: "\n").count > 6 && !showAll {
                        Button(String(localized: "Show All")) { showAll = true }
                            .buttonStyle(.link)
                            .font(.system(size: 11))
                    }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.well))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.line))
            }
            if changed {
                Label(String(localized: "This request changed. Look in the terminal.", comment: "Answer card: the request is no longer the one shown"),
                      systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.ink2)
            }
            HStack(spacing: 8) {
                if !changed {
                    ForEach(Array(answers.enumerated()), id: \.element.id) { number, option in
                        Button {
                            send(option)
                        } label: {
                            // Its number is its key, as in Claude Code's own menu.
                            Text(verbatim: "\(number + 1)  \(option.role == .allow ? String(localized: "Allow") : String(localized: "Deny"))")
                        }
                        .disabled(!armed)
                    }
                }
                Spacer(minLength: 8)
                Button(String(localized: "Go to Terminal"), action: goToTerminal)
                    // Only while the card has the keyboard (the Commit button's ⌘↩ is the message's).
                    .keyboardShortcut(focused ? KeyboardShortcut(.return, modifiers: .command) : nil)
            }
            .controlSize(.large)
            TimelineView(.periodic(from: .now, by: 30)) { context in
                Text(footer(now: context.date))
                    .font(.system(size: 11))
                    .foregroundStyle(Color.ink3)
            }
        }
        .padding(16)
        .frame(width: 380)
        .background(Color.surface)
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(characters: .init(charactersIn: "12")) { press in
            guard armed, !changed, let number = Int(press.characters), answers.indices.contains(number - 1) else { return .ignored }
            send(answers[number - 1])
            return .handled
        }
        .onExitCommand(perform: done)
        .task {
            focused = true
            try? await Task.sleep(for: .milliseconds(400))
            armed = true
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Request from Claude in \(place)", comment: "Accessibility label of the answer card"))
    }

    private func send(_ option: AnswerPlan.Option) {
        guard armed else { return }
        if workbench.answer(request, with: option) {
            done()
        } else {
            changed = true
        }
    }

    private var place: String {
        guard let (workspace, tab) = workbench.workspace(of: request.paneID) else { return "" }
        return "\(workspace.name) · \(workbench.title(of: tab))"
    }

    /// What is asked, in a line, as Claude Code's own dialog words it.
    private var headline: String {
        switch request.ask.kind {
        case .permission:
            switch request.ask.tool {
            case "Bash", "PowerShell": return String(localized: "Claude wants to run a command", comment: "Answer card")
            case "Edit", "MultiEdit", "Write", "NotebookEdit": return String(localized: "Claude wants to edit a file", comment: "Answer card")
            case "WebFetch": return String(localized: "Claude wants to fetch a web page", comment: "Answer card")
            default: return String(localized: "Claude wants to use \(request.ask.tool)", comment: "Answer card: another tool")
            }
        case .question: return String(localized: "Claude asks:", comment: "Answer card: a question")
        case .plan: return String(localized: "Claude has a plan for you to approve", comment: "Answer card")
        case .form: return String(localized: "A tool needs your input", comment: "Answer card: an MCP form")
        }
    }

    private var detail: String {
        switch request.ask.kind {
        case .question: request.ask.summary
        default: request.ask.target.isEmpty ? request.ask.summary : request.ask.target
        }
    }

    private func footer(now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(request.ask.at))
        let waited = seconds < 60
            ? String(localized: "Waiting since just now", comment: "Answer card footer: asked less than a minute ago")
            : String(localized: "Waiting \(Duration.seconds(seconds).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated)))",
                     comment: "Answer card footer: how long the request has waited")
        return request.answers.isEmpty
            ? String(localized: "\(waited) · answer it in the terminal (⌘↩)", comment: "Answer card footer when it cannot be answered here")
            : String(localized: "\(waited) · ⌘↩ Go to Terminal", comment: "Answer card footer")
    }
}
