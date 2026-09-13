import AppKit
import SwiftUI
import WhiskrKit

/// A quiet line under the terminals (as herdr's status bar; asked for over the first design's "no status
/// bar"): where the focused terminal is and the workspace's branch, how many Claudes there are and how
/// many need you (click: Next Request, ⌘J), and the two keys that find everything (⌘P, ⇧⌘P).
struct StatusLine: View {
    let workbench: Workbench

    static let height: CGFloat = 24

    var body: some View {
        let workspace = workbench.selectedWorkspace
        let folder = workbench.focusedPane?.currentFolder ?? workspace?.liveFolder
        let summary = StatusSummary(statuses: workbench.agentRows.map(\.status))
        HStack(spacing: 6) {
            if let folder {
                Label(abbreviatingHome(folder), systemImage: "folder")
                    .lineLimit(1)
                    .truncationMode(.head)
                    .help(folder)
            }
            if let branch = workspace?.branch {
                Separator()
                Label(branch, systemImage: "arrow.triangle.branch")
                    .lineLimit(1)
                    .help(String(localized: "Branch \(branch)", comment: "Status line: the git branch's tooltip"))
            }
            if summary.claudes > 0 {
                Separator()
                Text(String(localized: "\(summary.claudes) Claudes", comment: "Status line: how many Claudes are running"))
                if summary.needYou > 0 {
                    Separator()
                    Button {
                        NSApp.sendAction(#selector(MainWindowController.goToNextThing(_:)), to: nil, from: nil)
                    } label: {
                        Text(String(localized: "\(summary.needYou) need you", comment: "Status line: how many requests wait"))
                            .foregroundStyle(StateMark.vermillion)
                    }
                    .buttonStyle(.plain)
                    .help(String(localized: "Go to the oldest request (⌘J)"))
                }
            }
            Spacer(minLength: 12)
            if let document = workbench.focusedDocument, document.isText {
                FileStatus(document: document)
                Separator()
            }
            KeyHint(key: "⌘P", label: String(localized: "Go to"), action: #selector(MainWindowController.goTo(_:)))
            KeyHint(key: "⇧⌘P", label: String(localized: "Commands"), action: #selector(MainWindowController.showCommandPalette(_:)))
        }
        .labelStyle(StatusLabelStyle())
        .font(.system(size: 11))
        .foregroundStyle(Color.ink2)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, minHeight: Self.height, maxHeight: Self.height)
        .background(Color(nsColor: Colors.terminalBackground).overlay(Color.primary.opacity(0.04)))
        .overlay(alignment: .top) { Color.line.frame(height: 1) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Status", comment: "Accessibility label of the status line"))
    }
}

/// The focused file: where the cursor is, how it indents, its encoding, line breaks and language; the
/// indentation and line breaks are menus that change them.
private struct FileStatus: View {
    let document: FileDocument

    var body: some View {
        let status = EditorStatus.shared
        let here = status.documentID == ObjectIdentifier(document)
        HStack(spacing: 6) {
            Text(here ? (status.selected > 0
                         ? String(localized: "Ln \(status.line), Col \(status.column) (\(status.selected) selected)", comment: "Status line: cursor and selection")
                         : String(localized: "Ln \(status.line), Col \(status.column)", comment: "Status line: cursor position"))
                 : String(localized: "Ln 1, Col 1", comment: "Status line: cursor position"))
                .monospacedDigit()
            Separator()
            Menu {
                ForEach([2, 4, 8], id: \.self) { width in
                    Button(String(localized: "Spaces: \(width)")) { document.indentation = Indentation(usesTabs: false, width: width) }
                }
                Button(String(localized: "Tabs")) { document.indentation = Indentation(usesTabs: true, width: document.indentation.width) }
            } label: {
                Text(document.indentation.usesTabs ? String(localized: "Tabs", comment: "Status line: indentation") : String(localized: "Spaces: \(document.indentation.width)", comment: "Status line: indentation"))
                    .font(.system(size: 11))
                    .foregroundStyle(Color.ink2)
            }
            .help(String(localized: "Indentation"))
            Separator()
            Text(document.format.encoding.displayName)
                .help(String(localized: "Text encoding"))
            Separator()
            Menu {
                ForEach(LineEnding.allCases, id: \.self) { ending in
                    Button(ending.label) { document.setLineEnding(ending) }
                }
            } label: {
                Text(document.format.lineEnding.displayName)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.ink2)
            }
            .help(document.format.hadMixedLineEndings ? String(localized: "Line endings: mixed in the file; saved as \(document.format.lineEnding.displayName)") : String(localized: "Line endings"))
            Separator()
            Text(document.language.displayName)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
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
    let key: String
    let label: String
    let action: Selector
    @State private var hovering = false

    var body: some View {
        Button {
            NSApp.sendAction(action, to: nil, from: nil)
        } label: {
            HStack(spacing: 4) {
                Text(key).foregroundStyle(Color.ink2)
                Text(label).foregroundStyle(Color.ink3)
            }
            .padding(.horizontal, 6)
            .frame(height: 18)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(hovering ? 0.07 : 0)))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
