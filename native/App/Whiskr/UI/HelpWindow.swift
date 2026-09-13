import AppKit
import SwiftUI
import WhiskrKit

/// Help › Whiskr Help (⌘?): one page, "Reading the meadow" (docs/DESIGN.md), never shown
/// unless asked for. What each picture and mark means, where cats come from, and the keys that matter.
final class HelpWindowController: NSWindowController {
    static let shared = HelpWindowController()

    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 680), styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = String(localized: "Whiskr Help", comment: "The help window's title")
        window.minSize = NSSize(width: 460, height: 400)
        window.contentViewController = NSHostingController(rootView: HelpPage())
        window.setContentSize(NSSize(width: 600, height: 680))
        window.isReleasedWhenClosed = false
        if !AppPlaces.isIsolated { window.setFrameAutosaveName("Help") }
        super.init(window: window)
    }

    required init?(coder: NSCoder) {
        fatalError("HelpWindowController is created in code")
    }

    @objc func showHelp(_ sender: Any?) {
        if window?.isVisible != true { window?.center() }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}

private struct HelpPage: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 16) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 56, height: 56).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(String(localized: "Reading the meadow", comment: "Help page title")).font(.system(size: 22, weight: .semibold))
                        Text(String(localized: "Each workspace is a picnic blanket. Each Claude is a black cat on it; small cats beside it are its helpers.",
                                    comment: "Help page: the one-line explanation"))
                            .foregroundStyle(.secondary)
                    }
                }
                HelpSection(title: String(localized: "Where cats come from")) {
                    Text(AttributedString(localized: "Open a terminal (⌘T) and type `claude`. A cat walks onto that workspace's blanket and acts out what Claude is doing: reading, editing, running a command, thinking.", comment: "Help page (Markdown: `claude` is the command)"))
                    Text(String(localized: "Plain terminals are lanterns, lit after dark: warm while a command runs, red when one failed."))
                }
                HelpSection(title: String(localized: "What the marks mean")) {
                    HelpMark(mark: AnyView(StateMark(status: .blocked)), title: String(localized: "Request"),
                             text: String(localized: "The cat stands with a paw up. Claude asks for permission or has a question. Answer in its terminal, or click the cat to answer from here."))
                    HelpMark(mark: AnyView(StateMark(status: .blocked, failed: true)), title: String(localized: "Error"),
                             text: String(localized: "The cat sits with its ears back. Claude's turn stopped on an error."))
                    HelpMark(mark: AnyView(StateMark(status: .done)), title: String(localized: "Finished"),
                             text: String(localized: "The cat sits still, facing you. Claude finished while you were elsewhere; the mark clears once you have looked."))
                    HelpMark(mark: AnyView(EmptyView()), title: String(localized: "Working"),
                             text: String(localized: "Head down at a book, a laptop or a lever: no mark, nothing to do."))
                    HelpMark(mark: AnyView(EmptyView()), title: String(localized: "Idle"),
                             text: String(localized: "A loaf, then curled up asleep after ten minutes."))
                    HelpMark(mark: AnyView(EmptyView()), title: String(localized: "Helpers", comment: "Help page: what the small cats are"),
                             text: String(localized: "Small cats beside a Claude are its helpers. Click one to see its terminal or its story.", comment: "Help page: helpers"))
                }
                HelpSection(title: String(localized: "Sessions keep running", comment: "Help page heading")) {
                    Text(String(localized: "Quitting (⌘Q) leaves every terminal running, Claude included; the next launch puts them back as they were. To stop everything, hold Option and choose Quit and Stop All Terminals (⌥⌘Q).", comment: "Help page: what quitting does"))
                }
                HelpSection(title: String(localized: "Files and changes", comment: "Help page heading")) {
                    HelpKey(keys: "⇧⌘E", text: String(localized: "The workspace's files beside the terminals. Click a file to look at it; edit it, or double-click to keep its tab.", comment: "Help page: the Files panel"))
                    HelpKey(keys: "⇧⌘C", text: String(localized: "What changed in the repository: stage, unstage, look at the differences and commit.", comment: "Help page: the Changes panel"))
                    HelpKey(keys: "⇧⌘N", text: String(localized: "A new worktree of the repository, opened as a workspace of its own.", comment: "Help page: worktrees"))
                }
                HelpSection(title: String(localized: "Getting around")) {
                    HelpKey(keys: "⌘J", text: String(localized: "The next request, then the next finished turn, then back where you were."))
                    HelpKey(keys: "⌘P", text: String(localized: "Go to any workspace, tab or Claude by name, folder, branch or state."))
                    HelpKey(keys: "⇧⌘P", text: String(localized: "Every command, with its key."))
                    HelpKey(keys: "⌥⌘1…9", text: String(localized: "A workspace by its number. The workspace button at the start of the tab row lists them all, and Home."))
                    HelpKey(keys: "⌘1…9", text: String(localized: "A tab by its number."))
                    HelpKey(keys: "⌥⌘0", text: String(localized: "Move the keyboard into the meadow: arrows between blankets and cats, Return to open, Esc to go back."))
                    HelpKey(keys: "⇧⌘H", text: String(localized: "Home: open a folder or a terminal, or go back into a workspace exactly where you left it. Every launch starts here, and closing a workspace comes back here; everything keeps running.", comment: "Help page: Home"))
                    HelpKey(keys: "⌘N", text: String(localized: "A new workspace: Home, ready to open a folder or a terminal. Every other workspace stays open.", comment: "Help page: New Workspace"))
                }
                HelpSection(title: String(localized: "Laying out the window", comment: "Help page heading")) {
                    HelpKey(keys: "⌃⌘S", text: String(localized: "Show or hide the meadow; the button by the window's buttons does too. ⌃⌘1, ⌃⌘2 and ⌃⌘3 give both, the terminals alone or the meadow alone.", comment: "Help page: the meadow's toggle"))
                    HelpKey(keys: "⇧⌘E", text: String(localized: "Show or hide Files (⇧⌘C for Changes); the button at the top right does too. Drag the panel's edge to size it, past its least width to close it, or double-click it for its usual width.", comment: "Help page: the side panel's toggle"))
                    HelpKey(keys: "⌥⌘/", text: String(localized: "Show or hide the status bar.", comment: "Help page: the status bar's toggle"))
                    HelpKey(keys: "⇧⌘↩", text: String(localized: "Zoom the pane you are typing in to fill its tab, and back. A double-click on the line between two panes shares the room evenly again.", comment: "Help page: zooming a pane"))
                    Text(String(localized: "View › Reset Layout puts every part of the window back as it first was. The bars at the top move the window, and a double-click on them zooms it, as on any Mac title bar; new tabs come from + and ⌘T.", comment: "Help page: resetting the layout, and what the bars do"))
                }
                HelpSection(title: String(localized: "Your own keys")) {
                    Text(String(localized: "Any menu command can have a different shortcut: System Settings › Keyboard › Keyboard Shortcuts › App Shortcuts."))
                }
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .textSelection(.enabled)
    }
}

private struct HelpSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 15, weight: .semibold)).accessibilityAddTraits(.isHeader)
            content.fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct HelpMark: View {
    let mark: AnyView
    let title: String
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            mark.frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.medium)
                Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct HelpKey: View {
    let keys: String
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(keys).font(.system(.body, design: .rounded).weight(.medium)).frame(width: 64, alignment: .leading)
            Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}
