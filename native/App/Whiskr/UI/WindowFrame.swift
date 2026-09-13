import AppKit
import SwiftUI
import WhiskrKit

/// The window's frame (docs/DESIGN.md), as Cursor's: a top bar and a status bar, each the window's full
/// width, with the work between them: the meadow on the left, the tab row and the terminals (or Home)
/// on the right. Both bars are drawn here, in the app's own colours, as content under the clear title
/// bar: not toolbar items, which macOS 26 wraps each in a glass capsule.
final class FrameController: NSViewController {
    private let workbench: Workbench
    private let chrome: WindowChrome
    private let content: NSViewController

    /// The compact title bar's height: the traffic lights sit centred in the top bar.
    static let topBarHeight: CGFloat = 38
    static let statusBarHeight: CGFloat = 24

    init(content: NSViewController, workbench: Workbench, chrome: WindowChrome) {
        self.content = content
        self.workbench = workbench
        self.chrome = chrome
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("FrameController is created in code")
    }

    override func loadView() {
        let view = NSView()
        let top = NSHostingView(rootView: TopBar(workbench: workbench, chrome: chrome))
        let status = NSHostingView(rootView: StatusBar(workbench: workbench))
        addChild(content)
        for part in [content.view, top, status] {
            part.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(part)
        }
        // The top bar lies under the clear title bar on purpose.
        top.sizingOptions = []
        top.safeAreaRegions = []
        status.sizingOptions = []
        status.safeAreaRegions = []
        NSLayoutConstraint.activate([
            top.topAnchor.constraint(equalTo: view.topAnchor),
            top.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            top.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            top.heightAnchor.constraint(equalToConstant: Self.topBarHeight),
            content.view.topAnchor.constraint(equalTo: top.bottomAnchor),
            content.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            content.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            content.view.bottomAnchor.constraint(equalTo: status.topAnchor),
            status.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            status.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            status.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            status.heightAnchor.constraint(equalToConstant: Self.statusBarHeight),
        ])
        self.view = view
    }
}

/// What the bars need to know of the window around them: in full screen there are no traffic lights.
@MainActor @Observable
final class WindowChrome {
    var fullScreen = false
    @ObservationIgnored var toggleMeadow: () -> Void = {}

    /// Room for the close, minimise and zoom buttons at the top bar's leading end.
    var leadingInset: CGFloat { fullScreen ? 8 : 78 }
}

extension View {
    /// The window's chrome (top bar, tab row, status bar): one calm colour, the terminal's background a
    /// shade off, so the chrome and the terminals read as one surface.
    func chromeBackground() -> some View {
        background(Color(nsColor: Colors.terminalBackground).overlay(Color.primary.opacity(0.07)))
    }
}

/// The top bar: the meadow button after the traffic lights; in the middle, a quiet field naming where
/// you are that opens Go to (⌘P); at the end, New, the Files and Changes button, and Settings. Its empty
/// stretches move the window, and a double-click does what the title bar's does.
struct TopBar: View {
    let workbench: Workbench
    let chrome: WindowChrome
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            TitleBarDragArea()
            HStack(spacing: 4) {
                ChromeButton(symbol: "sidebar.left", help: String(localized: "Show or hide the meadow (⌃⌘S)"),
                             label: String(localized: "Show or hide the meadow"), action: chrome.toggleMeadow)
                Spacer(minLength: 0)
                NewMenuButton()
                PanelButton(workbench: workbench)
                ChromeButton(symbol: "gearshape", help: String(localized: "Settings (⌘,)"), label: String(localized: "Settings")) {
                    NSApp.sendAction(#selector(AppDelegate.showSettings(_:)), to: nil, from: nil)
                }
            }
            .padding(.leading, chrome.leadingInset)
            .padding(.trailing, 8)
            GoToField(workbench: workbench)
                .frame(maxWidth: 440)
                .padding(.horizontal, 180)
        }
        .frame(maxWidth: .infinity, minHeight: FrameController.topBarHeight, maxHeight: FrameController.topBarHeight)
        .chromeBackground()
        .overlay(alignment: .bottom) { Color.line.frame(height: 1) }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: chrome.leadingInset)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Top bar", comment: "Accessibility label of the window's top bar"))
    }
}

/// The middle of the top bar, as Cursor's: where you are, and a click away from Go to.
private struct GoToField: View {
    let workbench: Workbench
    @State private var hovering = false

    var body: some View {
        let place = workbench.selectedWorkspace?.name ?? String(localized: "Whiskr", comment: "The top bar's field on Home")
        Button {
            NSApp.sendAction(#selector(MainWindowController.goTo(_:)), to: nil, from: nil)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .medium))
                Text(place)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .foregroundStyle(Color.ink2)
            .frame(maxWidth: .infinity)
            .frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(hovering ? 0.08 : 0.05)))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.line))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(String(localized: "Go to a workspace, tab, Claude or file (⌘P)"))
        .accessibilityLabel(String(localized: "Go to…"))
        .accessibilityValue(place)
    }
}

/// A 28 × 26 pt icon button, as every button in the bars is.
struct ChromeButton: View {
    let symbol: String
    let help: String
    let label: String
    var active = false
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            ChromeIcon(symbol: symbol, active: active, hovering: hovering && enabled)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(label)
    }
}

/// The icon of a chrome button: one size and weight for every symbol in the bars.
struct ChromeIcon: View {
    let symbol: String
    var active = false
    var hovering = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 13))
            .foregroundStyle(active ? Color.ink : Color.ink2)
            .opacity(enabled ? 1 : 0.4)
            .frame(width: 28, height: 26)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(active || hovering ? 0.08 : 0)))
            .contentShape(Rectangle())
    }
}

/// "+": New Tab, New Workspace, Open Folder…, New Worktree…, each as in the File menu.
private struct NewMenuButton: View {
    @State private var hovering = false

    var body: some View {
        ChromeIcon(symbol: "plus", hovering: hovering)
            .background(MenuAnchor(menu: Self.menu))
            .onHover { hovering = $0 }
            .help(String(localized: "New Tab, Workspace or Worktree"))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(String(localized: "New"))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { Self.menu().popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil) }
    }

    static func menu() -> NSMenu {
        let menu = NSMenu()
        for (title, action, key, modifiers) in [
            (String(localized: "New Tab"), #selector(MainWindowController.newTab(_:)), "t", NSEvent.ModifierFlags.command),
            (String(localized: "New Workspace"), #selector(MainWindowController.newWorkspace(_:)), "n", [.command]),
            (String(localized: "Open Folder…"), #selector(MainWindowController.openFolder(_:)), "o", [.command]),
            (String(localized: "New Worktree…"), #selector(MainWindowController.newWorktree(_:)), "n", [.command, .shift]),
        ] {
            if action == #selector(MainWindowController.newWorktree(_:)) { menu.addItem(.separator()) }
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            menu.addItem(item)
        }
        return menu
    }
}

/// Shows or hides the side panel (Files and Changes); counts the workspace's changed files. Dimmed on
/// Home, which has no folder of its own.
struct PanelButton: View {
    let workbench: Workbench
    @State private var hovering = false

    var body: some View {
        let shown = workbench.selectedWorkspace.map { workbench.files.panel($0.id).shown } ?? false
        let count = workbench.selectedRepository?.status?.changeCount ?? 0
        Button { workbench.setPanelShown(!shown) } label: {
            ChromeIcon(symbol: "sidebar.right", active: shown, hovering: hovering)
                .overlay(alignment: .topTrailing) {
                    if count > 0, !shown {
                        Text(verbatim: count > 99 ? "99+" : "\(count)")
                            .font(.system(size: 9, weight: .bold).monospacedDigit())
                            .foregroundStyle(Color.ink)
                            .padding(.horizontal, 3.5)
                            .frame(minWidth: 14, minHeight: 14)
                            .background(Capsule().fill(Color(nsColor: Colors.terminalBackground)))
                            .overlay(Capsule().strokeBorder(Color.lineStrong))
                            .offset(x: 5, y: -3)
                    }
                }
        }
        .buttonStyle(.plain)
        .disabled(workbench.isHome)
        .onHover { hovering = $0 }
        .help(shown ? String(localized: "Hide Files and Changes") : count > 0 ? String(localized: "Show Files and Changes: \(count) changed files") : String(localized: "Show Files and Changes"))
        .accessibilityLabel(shown ? String(localized: "Hide Files and Changes") : String(localized: "Show Files and Changes"))
        .accessibilityValue(count > 0 ? String(localized: "\(count) changed files") : "")
    }
}

/// The top bar's empty stretch: it moves the window, and a double-click zooms (or minimises, or does
/// nothing) as the title bar's does, following Desktop & Dock's setting.
private struct TitleBarDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ view: DragView, context: Context) {}

    final class DragView: NSView {
        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            guard event.clickCount == 2 else { return window.performDrag(with: event) }
            switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
            case "Minimize": window.performMiniaturize(nil)
            case "None": break
            default: window.performZoom(nil)
            }
        }

        override var mouseDownCanMoveWindow: Bool { true }
    }
}
