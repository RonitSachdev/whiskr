import AppKit
import SwiftUI
import WhiskrKit

/// The status bar along the window's foot (as Cursor's and herdr's): the workspace's branch (a click
/// shows Changes) and where its focused terminal is; how many Claudes there are and how many need you
/// (click: Next Request, ⌘J), across every workspace; then a quiet bell while alerts are paused, the
/// focused file's details when an editor has the keyboard, and the two keys that find everything (⌘P,
/// ⇧⌘P). On Home, only the counts and keys.
struct StatusBar: View {
    let workbench: Workbench
    @Environment(\.controlActiveState) private var activeState

    var body: some View {
        // Short of room, the bar lets go of what is found elsewhere first, rather than cutting every item
        // short: the two keys (the top bar's search field says ⌘P too), then the folder (the tab and the
        // prompt show it). The branch, the Claudes, who needs you and the file's details stay whole.
        ViewThatFits(in: .horizontal) {
            items(showsKeys: true, showsFolder: true)
            items(showsKeys: false, showsFolder: true)
            items(showsKeys: false, showsFolder: false)
        }
        .labelStyle(StatusLabelStyle())
        .font(.system(size: 11))
        .foregroundStyle(Color.ink2)
        // Not the window in use: quieter, as the top bar.
        .opacity(activeState.inUse ? 1 : 0.7)
        // Clear of the window's rounded corners, where a press resizes the window: at the bar's middle
        // they reach about 12 pt in.
        .padding(.horizontal, Look.Space.l)
        .frame(maxWidth: .infinity, minHeight: Look.Height.statusBar, maxHeight: Look.Height.statusBar)
        .chromeBackground()
        .overlay(alignment: .top) { Color.line.frame(height: 1).allowsHitTesting(false) }
        // In a window that is not the one in use, the first click acts as well as bringing it forward, as
        // in the top bar and the tab row.
        .allowsWindowActivationEvents()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Status", comment: "Accessibility label of the status bar"))
    }

    /// The bar's items, with or without the keys at its end and the folder.
    private func items(showsKeys: Bool, showsFolder: Bool) -> some View {
        let workspace = workbench.selectedWorkspace
        let folder = workspace.map { workbench.focusedPane?.currentFolder ?? $0.liveFolder }
        let summary = StatusSummary(statuses: workbench.agentRows.map(\.status))
        return HStack(spacing: 0) {
            if let branch = workspace?.branch {
                let help = String(localized: "Branch \(branch): show Changes (⇧⌘C)", comment: "Status bar: the git branch's tooltip")
                Label(branch, systemImage: "arrow.triangle.branch")
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .statusItem()
                    .barButton("status.branch", label: help, help: help, radius: Look.Radius.small) {
                        NSApp.sendAction(#selector(MainWindowController.showChangesPanel(_:)), to: nil, from: nil)
                    }
                Separator()
            }
            if showsFolder, let folder {
                Label(Places.short(folder, home: FileManager.default.homeDirectoryForCurrentUser.path), systemImage: "folder")
                    .lineLimit(1)
                    .truncationMode(.head)
                    .statusItem()
                    .help(abbreviatingHome(folder))
                if summary.claudes > 0 { Separator() }
            }
            if summary.claudes > 0 {
                Text(String(localized: "\(summary.claudes) Claudes", comment: "Status bar: how many Claudes are running"))
                    .statusItem()
                if summary.needYou > 0 {
                    Separator()
                    let text = String(localized: "\(summary.needYou) need you", comment: "Status bar: how many requests wait")
                    Text(text)
                        .foregroundStyle(StateMark.vermillion)
                        .statusItem()
                        .barButton("status.requests", label: text, help: String(localized: "Go to the oldest request (⌘J)"), radius: Look.Radius.small) {
                            NSApp.sendAction(#selector(MainWindowController.goToNextThing(_:)), to: nil, from: nil)
                        }
                }
            }
            Spacer(minLength: 12)
            if let until = Preferences.shared.alertsPausedUntil, until > Date() {
                // Pause Alerts is on: no sounds and no notifications until then.
                Image(systemName: "bell.slash")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.ink3)
                    .statusItem()
                    .help(String(localized: "Alerts paused until \(until.formatted(date: .omitted, time: .shortened))"))
                    .accessibilityLabel(String(localized: "Alerts paused until \(until.formatted(date: .omitted, time: .shortened))"))
                Separator()
            }
            if let document = workbench.focusedDocument, document.isText {
                FileStatus(document: document)
                    .statusItem()
                if showsKeys { Separator() }
            }
            if showsKeys {
                KeyHint(id: "status.go-to", key: "⌘P", label: String(localized: "Go to"), action: #selector(MainWindowController.goTo(_:)))
                KeyHint(id: "status.commands", key: "⇧⌘P", label: String(localized: "Commands"), action: #selector(MainWindowController.showCommandPalette(_:)))
            }
        }
    }
}

/// The focused file: where the cursor is, how it indents, its encoding, line breaks and language; the
/// indentation, the line breaks and the language are menus that change them (`barMenu`).
private struct FileStatus: View {
    let document: FileDocument

    var body: some View {
        let status = EditorStatus.shared
        let here = status.documentID == ObjectIdentifier(document)
        HStack(spacing: 2) {
            Text(here ? (status.selected > 0
                         ? String(localized: "Ln \(status.line), Col \(status.column) (\(status.selected) selected)", comment: "Status bar: cursor and selection")
                         : String(localized: "Ln \(status.line), Col \(status.column)", comment: "Status bar: cursor position"))
                 : String(localized: "Ln 1, Col 1", comment: "Status bar: cursor position"))
                .monospacedDigit()
                .padding(.trailing, Look.Space.xs)
            Separator()
            Text(document.indentation.usesTabs ? String(localized: "Tabs", comment: "Status bar: indentation") : String(localized: "Spaces: \(document.indentation.width)", comment: "Status bar: indentation"))
                .menuItem()
                .barMenu("status.indentation", label: String(localized: "Indentation"), help: String(localized: "Indentation"),
                         value: document.indentation.usesTabs ? String(localized: "Tabs", comment: "Status bar: indentation") : String(localized: "Spaces: \(document.indentation.width)", comment: "Status bar: indentation"),
                         radius: Look.Radius.small, menu: indentationMenu)
            Separator()
            Text(document.format.encoding.displayName)
                .padding(.horizontal, Look.Space.xs)
                .help(String(localized: "Text encoding"))
            Separator()
            Text(document.format.lineEnding.displayName)
                .menuItem()
                .barMenu("status.line-ending", label: String(localized: "Line endings"),
                         help: document.format.hadMixedLineEndings ? String(localized: "Line endings: mixed in the file; saved as \(document.format.lineEnding.displayName)") : String(localized: "Line endings"),
                         value: document.format.lineEnding.displayName, radius: Look.Radius.small, menu: lineEndingMenu)
            Separator()
            Text(document.language.displayName)
                .menuItem()
                .barMenu("status.language", label: String(localized: "Language, \(document.language.displayName)", comment: "Accessibility: the status bar's language menu"),
                         help: String(localized: "Language: colour this file as another language", comment: "Status bar: the language menu's tooltip"),
                         radius: Look.Radius.small, menu: languageMenu)
        }
        .fixedSize()
    }

    private func indentationMenu() -> NSMenu {
        let menu = NSMenu()
        let now = document.indentation
        for width in [2, 4, 8] {
            let item = closureMenuItem(title: String(localized: "Spaces: \(width)")) { document.indentation = Indentation(usesTabs: false, width: width) }
            item.state = !now.usesTabs && now.width == width ? .on : .off
            menu.addItem(item)
        }
        let tabs = closureMenuItem(title: String(localized: "Tabs")) { document.indentation = Indentation(usesTabs: true, width: document.indentation.width) }
        tabs.state = now.usesTabs ? .on : .off
        menu.addItem(tabs)
        return menu
    }

    private func lineEndingMenu() -> NSMenu {
        let menu = NSMenu()
        for ending in LineEnding.allCases {
            let item = closureMenuItem(title: ending.label) { document.setLineEnding(ending) }
            item.state = document.format.lineEnding == ending ? .on : .off
            menu.addItem(item)
        }
        return menu
    }

    private func languageMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(closureMenuItem(title: String(localized: "Auto Detect (\(document.detectedLanguage.displayName))", comment: "Status bar's language menu: colour the file as its name says")) {
            document.choose(language: nil)
        })
        menu.addItem(.separator())
        for language in LanguageRegistry.shared.all {
            let item = closureMenuItem(title: language.displayName) { document.choose(language: language) }
            item.state = document.language == language ? .on : .off
            menu.addItem(item)
        }
        return menu
    }
}

private extension View {
    /// A clickable item in the status bar: a little room round it for its hover fill.
    func statusItem() -> some View {
        padding(.horizontal, Look.Space.s).frame(height: 18)
    }

    /// One of the file's menus among its details: less room, as they sit close together.
    func menuItem() -> some View {
        padding(.horizontal, Look.Space.xs).frame(height: 18)
    }
}

private struct Separator: View {
    var body: some View {
        Text(verbatim: "·").foregroundStyle(Color.ink3).accessibilityHidden(true)
    }
}

private struct StatusLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.font(.system(size: 10)).foregroundStyle(Color.ink3)
            configuration.title
        }
    }
}

/// "⌘P Go to": the key and what it does; a click does it too.
private struct KeyHint: View {
    let id: String
    let key: String
    let label: String
    let action: Selector

    var body: some View {
        HStack(spacing: Look.Space.xs) {
            Text(key).foregroundStyle(Color.ink2)
            Text(label).foregroundStyle(Color.ink2)
        }
        .statusItem()
        .barButton(id, label: label, help: "", radius: Look.Radius.small) {
            NSApp.sendAction(action, to: nil, from: nil)
        }
    }
}
