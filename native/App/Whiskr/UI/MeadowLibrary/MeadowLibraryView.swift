import AppKit
import MeadowFile
import SwiftUI
import UniformTypeIdentifiers
import WhiskrMeadow

/// My Meadows (docs/DESIGN.md, "My Meadows"): a card for each meadow, the read-only Default first, then yours in
/// name order; each its picture (drawn by the scene from the meadow's data, `MeadowPreviews`), its name and what
/// it holds, the one shown ringed and checked. A click shows a meadow; its menu (the card's ⋯ or a right-click)
/// has Use, Edit, Rename, Duplicate, Export…, Share…, Export Picture…, Show in Finder and Move to Trash…. A name is
/// renamed in place. A card can be dragged out as a file, and meadow files dropped on the cards are imported.
/// Under them: New Meadow (from the Default, or empty), Import… and Edit Meadow…. In Settings › Meadow, and as a
/// sheet from the editor's name menu.
struct MeadowLibraryView: View {
    /// The window it is in, for the panels and questions it shows.
    let window: () -> NSWindow?
    /// Editing a meadow ends the sheet it is in (the editor shows it); nil in Settings.
    var dismiss: (() -> Void)?
    /// A meadow to rename as soon as it shows (the editor's Rename…).
    var startRenaming: String?
    private let library = MeadowLibrary.shared
    private let previews = MeadowPreviews.shared
    @State private var renaming: String?
    @State private var newName = ""
    @FocusState private var nameFocused: Bool
    @State private var dropTargeted = false
    @State private var frames: [String: CGRect] = [:]

    static let columns = [GridItem(.adaptive(minimum: 196), spacing: 14)]
    /// The Default's place in `frames` (it has no file).
    private static let defaultKey = "\u{0}default"

    var body: some View {
        VStack(alignment: .leading, spacing: Look.Space.l) {
            LazyVGrid(columns: Self.columns, spacing: 14) {
                card(nil)
                ForEach(library.files, id: \.self) { file in card(file) }
            }
            .padding(.vertical, 4)
            .coordinateSpace(name: "cards")
            // In a sheet the buttons stand in its foot, beside Done, never scrolled away.
            if dismiss == nil {
                HStack {
                    MeadowLibraryButtons(window: window, dismiss: nil)
                    Spacer()
                    Button(String(localized: "Edit Meadow…", comment: "The grass's menu: begins editing the meadow")) {
                        NSApp.sendAction(#selector(AppDelegate.editMeadow(_:)), to: nil, from: nil)
                    }
                }
            }
        }
        .overlay {
            if dropTargeted { RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor, lineWidth: 2).padding(-4) }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted, perform: dropped)
        .onPreferenceChange(CardFrames.self) { frames = $0 }
        .onAppear {
            library.refreshFiles()
            if let startRenaming, library.files.contains(startRenaming) { beginRename(startRenaming) }
        }
    }

    // MARK: A card

    @ViewBuilder private func card(_ file: String?) -> some View {
        let shown = library.active == file
        let summary = library.summary(file)
        let readable = file == nil || summary != nil
        VStack(alignment: .leading, spacing: 6) {
            // The picture is the card's button (a click shows the meadow), and what is dragged out of it.
            Button { if readable { MeadowLibraryActions.use(file) } } label: {
                picture(file, readable: readable)
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(shown ? Color.accentColor : Color.primary.opacity(0.12), lineWidth: shown ? 2.5 : 1))
            }
            .buttonStyle(.plain)
            .onDrag { readable ? MeadowLibraryActions.dragItem(file) : NSItemProvider() }
            HStack(spacing: 4) {
                if shown {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 11)).foregroundStyle(Color.accentColor).accessibilityHidden(true)
                }
                if let file, renaming == file {
                    renameField(file)
                } else {
                    Text(verbatim: library.displayName(file)).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 2)
                cardMenuButton(file, readable: readable)
            }
            if let file, renaming == file, let note = renameNote(file) {
                Text(verbatim: note).font(.system(size: 11)).foregroundStyle(MeadowLibrary.renameProblem(newName) == nil ? Color.secondary : Color.red)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(verbatim: detail(file, summary: summary)).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .contentShape(Rectangle())
        .contextMenu { cardMenu(file, readable: readable) }
        .background(GeometryReader { geometry in
            Color.clear.preference(key: CardFrames.self, value: [file ?? Self.defaultKey: geometry.frame(in: .global)])
        })
        #if DEBUG
        .background(MeadowCardAnchor(file: file))
        #endif
        .help(file == nil ? String(localized: "The meadow as it always was. It never changes; your first change makes a copy of it.",
                                   comment: "My Meadows: the Default card's tooltip") : library.displayName(file))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(cardLabel(file, summary: summary, shown: shown))
        .accessibilityAddTraits(shown ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(named: String(localized: "Edit", comment: "My Meadows: a card's menu: edits the meadow")) { MeadowLibraryActions.edit(file) }
        .accessibilityAction { if readable { MeadowLibraryActions.use(file) } }
    }

    private func picture(_ file: String?, readable: Bool) -> some View {
        let _ = previews.drawn
        let image = readable ? previews.picture(file) : nil
        return ZStack {
            Rectangle().fill(Color.primary.opacity(0.06))
            if let image {
                Image(decorative: image, scale: 2).resizable().aspectRatio(contentMode: .fill)
            } else if readable {
                ProgressView().controlSize(.small)
            } else {
                VStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle").font(.system(size: 18))
                    Text(String(localized: "Can't be read", comment: "My Meadows: a meadow file that cannot be read")).font(.system(size: 11))
                }
                .foregroundStyle(.secondary)
            }
        }
        .aspectRatio(16 / 10, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    /// Under the name: Built in, or what it holds, or that it cannot be read.
    private func detail(_ file: String?, summary: MeadowSummary?) -> String {
        guard file != nil else { return String(localized: "Built in · never changes", comment: "My Meadows: the Default card's line") }
        guard let summary else { return String(localized: "Can't be read; kept as it is", comment: "My Meadows: a meadow file that cannot be read") }
        return MeadowFileWords.contents(things: summary.things, paints: summary.paints)
    }

    private func cardLabel(_ file: String?, summary: MeadowSummary?, shown: Bool) -> String {
        let name = library.displayName(file), detail = detail(file, summary: summary)
        return shown ? String(localized: "\(name), shown, \(detail)", comment: "VoiceOver: My Meadows' card of the meadow shown")
                     : String(localized: "\(name), \(detail)", comment: "VoiceOver: a card in My Meadows")
    }

    private func cardMenuButton(_ file: String?, readable: Bool) -> some View {
        Menu { cardMenu(file, readable: readable) } label: {
            Image(systemName: "ellipsis.circle").font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(String(localized: "More for this meadow", comment: "My Meadows: a card's menu button"))
        .accessibilityLabel(String(localized: "More for \(library.displayName(file))", comment: "VoiceOver: a card's menu button in My Meadows"))
    }

    @ViewBuilder private func cardMenu(_ file: String?, readable: Bool) -> some View {
        if readable {
            Button(String(localized: "Use", comment: "My Meadows: a card's menu: shows the meadow")) { MeadowLibraryActions.use(file) }
                .disabled(library.active == file)
            Button(String(localized: "Edit", comment: "My Meadows: a card's menu: edits the meadow")) {
                dismiss?()
                MeadowLibraryActions.edit(file)
            }
            Divider()
        }
        if let file {
            Button(String(localized: "Rename", comment: "My Meadows: a card's menu: renames the meadow in place")) { beginRename(file) }
        }
        if readable {
            Button(String(localized: "Duplicate", comment: "My Meadows: a card's menu: copies the meadow")) { MeadowLibraryActions.duplicate(file) }
            Divider()
            Button(String(localized: "Export…", comment: "My Meadows: a card's menu: saves the meadow as a file to share")) {
                MeadowLibraryActions.export(file, over: window())
            }
            Button(String(localized: "Share…", comment: "My Meadows: a card's menu: the system's share picker")) { share(file) }
            Button(String(localized: "Export Picture…", comment: "My Meadows: a card's menu: saves a picture of the meadow")) {
                MeadowLibraryActions.exportPicture(file, over: window())
            }
        }
        if let file {
            Button(String(localized: "Show in Finder")) { MeadowLibraryActions.reveal(file) }
            Divider()
            Button(String(localized: "Move to Trash…", comment: "My Meadows: a card's menu: moves the meadow's file to the Trash")) {
                MeadowLibraryActions.moveToTrash(file, over: window())
            }
        }
    }

    // MARK: Renaming in place

    private func renameField(_ file: String) -> some View {
        TextField(String(localized: "Name", comment: "My Meadows: the name field while renaming"), text: $newName)
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 12))
            .focused($nameFocused)
            .onSubmit { commitRename(file) }
            .onExitCommand { renaming = nil }
            .onChange(of: nameFocused) { _, focused in if !focused, renaming == file { commitRename(file) } }
            .accessibilityLabel(String(localized: "New name for \(library.displayName(file))", comment: "VoiceOver: My Meadows' rename field"))
    }

    func beginRename(_ file: String) {
        newName = library.displayName(file)
        renaming = file
        DispatchQueue.main.async { nameFocused = true }
    }

    /// What the name typed would be: why it cannot, or the name it takes when another meadow has it.
    private func renameNote(_ file: String) -> String? {
        if let problem = MeadowLibrary.renameProblem(newName) { return problem }
        let taken = MeadowLibraryFolder.name(of: library.renamedFileName(file, to: newName))
        let typed = MeadowText.sanitised(newName)
        return taken.lowercased() == typed.lowercased() ? nil
            : String(localized: "Another meadow has this name; this one becomes “\(taken)”.", comment: "Renaming a meadow: the name is taken")
    }

    private func commitRename(_ file: String) {
        guard renaming == file else { return }
        guard MeadowLibrary.renameProblem(newName) == nil else { return }
        renaming = nil
        do { try library.rename(file, to: newName) } catch {
            if let window = window() { NSAlert(error: error).beginSheetModal(for: window) }
        }
    }

    // MARK: Sending and receiving files

    private func share(_ file: String?) {
        guard let window = window(), let content = window.contentView else { return }
        let global = frames[file ?? Self.defaultKey] ?? CGRect(x: content.bounds.midX, y: content.bounds.midY, width: 1, height: 1)
        // SwiftUI's global frames run from the window's top left; the content view's from its bottom left.
        let rect = NSRect(x: global.minX, y: content.bounds.height - global.maxY, width: global.width, height: global.height)
        MeadowLibraryActions.share(file, from: content, rect: rect)
    }

    private func dropped(_ providers: [NSItemProvider]) -> Bool {
        let files = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !files.isEmpty else { return false }
        for provider in files {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in
                    let meadows = MeadowLibraryActions.meadowFiles([url])
                    if !meadows.isEmpty { MeadowImport.shared.open(meadows, over: window()) }
                }
            }
        }
        return true
    }
}

/// New Meadow (From the Default, Empty) and Import…, under the cards.
struct MeadowLibraryButtons: View {
    let window: () -> NSWindow?
    let dismiss: (() -> Void)?

    var body: some View {
        HStack {
            Menu(String(localized: "New Meadow", comment: "My Meadows: makes a new meadow")) {
                Button(String(localized: "From the Default", comment: "My Meadows › New Meadow: a copy of the Default")) {
                    dismiss?()
                    MeadowLibraryActions.newMeadow(fromDefault: true)
                }
                Button(String(localized: "Empty", comment: "My Meadows › New Meadow: grass, hills and sky, nothing placed")) {
                    dismiss?()
                    MeadowLibraryActions.newMeadow(fromDefault: false)
                }
            }
            .menuStyle(.button)
            .fixedSize()
            Button(String(localized: "Import…", comment: "My Meadows: imports meadow files")) { MeadowImport.shared.choose(over: window()) }
        }
    }
}

/// Where each card is in the window (Share… shows the picker beside the card it came from).
private struct CardFrames: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// The window a SwiftUI view is in, for the AppKit panels and sheets it shows.
final class HostWindow {
    weak var window: NSWindow?
}

struct HostWindowReader: NSViewRepresentable {
    let host: HostWindow

    func makeNSView(context: Context) -> NSView {
        let view = ReaderView()
        view.host = host
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        host.window = view.window
    }

    private final class ReaderView: NSView {
        var host: HostWindow?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            host?.window = window
        }
    }
}

#if DEBUG
/// A card's place, for the library flow (SwiftUI makes no accessibility elements until an assistive app asks).
struct MeadowCardAnchor: NSViewRepresentable {
    static let prefix = "meadow.card."
    let file: String?

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.identifier = NSUserInterfaceItemIdentifier(Self.prefix + (file ?? ""))
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        view.identifier = NSUserInterfaceItemIdentifier(Self.prefix + (file ?? ""))
    }
}
#endif

/// My Meadows as a sheet over the main window (the editor's name menu): the cards, and Done.
struct MeadowLibrarySheet: View {
    let host: HostWindow
    var renaming: String?
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Look.Space.l) {
            Text(String(localized: "My Meadows", comment: "The library of meadows: its title")).font(.system(size: 15, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
            ScrollView {
                MeadowLibraryView(window: { host.window }, dismiss: close, startRenaming: renaming)
                    .padding(.horizontal, 2)
            }
            .frame(minHeight: 260, maxHeight: 520)
            Divider()
            HStack {
                MeadowLibraryButtons(window: { host.window }, dismiss: close)
                Spacer()
                Button(String(localized: "Done", comment: "Meadow editor: leaves editing"), action: close).keyboardShortcut(.defaultAction)
            }
        }
        .padding(Look.Space.xl)
        .frame(width: 680)
        .background(HostWindowReader(host: host))
    }
}
