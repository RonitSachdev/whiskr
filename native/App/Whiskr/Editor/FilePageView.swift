import AppKit
import Observation
import SwiftUI
import WhiskrKit

/// A file in a tab: a slim header (where the file is, and its view's tools), a bar when the disk changed
/// under unsaved changes, and the file itself: the editor, the Markdown or SVG preview (or both side by
/// side), a picture, a PDF, or a calm page saying why it cannot be shown.
final class FilePageView: NSView {
    let pageID: UUID
    let document: FileDocument
    private let workbench: Workbench
    private let state: FilePageState
    private let header: NSHostingView<FileHeader>
    private let banner: NSHostingView<DiskBanner>
    private let body = NSView()
    private var bannerHeight: NSLayoutConstraint!
    private var observers: [Observing] = []
    private(set) var editor: CodeEditorView?
    private var preview: NSView?
    private var mediaView: NSView?
    private var shown: (FileDocument.Content, EditorPreferences.MarkdownMode?)?
    private var lineField: NSPopover?

    static let headerHeight: CGFloat = 30

    init(pageID: UUID, document: FileDocument, workbench: Workbench) {
        self.pageID = pageID
        self.document = document
        self.workbench = workbench
        state = FilePageState(document: document)
        header = NSHostingView(rootView: FileHeader(document: document, workbench: workbench, state: state))
        banner = NSHostingView(rootView: DiskBanner(document: document, workbench: workbench, page: pageID))
        super.init(frame: .zero)
        header.sizingOptions = []
        banner.sizingOptions = []
        for view in [header, banner, body] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        bannerHeight = banner.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: Self.headerHeight),
            banner.topAnchor.constraint(equalTo: header.bottomAnchor),
            banner.leadingAnchor.constraint(equalTo: leadingAnchor),
            banner.trailingAnchor.constraint(equalTo: trailingAnchor),
            bannerHeight,
            body.topAnchor.constraint(equalTo: banner.bottomAnchor),
            body.leadingAnchor.constraint(equalTo: leadingAnchor),
            body.trailingAnchor.constraint(equalTo: trailingAnchor),
            body.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        wantsLayer = true
        state.onGoToLine = { [weak self] in self?.showLineField() }
        state.onActualSize = { [weak self] fits in (self?.mediaView as? ImagePreview)?.fitsPage = fits }
        observers.append(Observing { [weak self] in self?.update() })
        observers.append(Observing { [weak self] in
            guard let self else { return }
            self.bannerHeight.constant = self.document.diskChange == nil ? 0 : 34
            // Typing in a preview tab keeps it.
            if self.document.isEdited { self.workbench.keep(page: self.pageID) }
        })
        NotificationCenter.default.addObserver(self, selector: #selector(revealRequested(_:)), name: FilesCenter.revealLine, object: pageID)
        setAccessibilityElement(false)
        observers.append(PageDimming.attach(to: self, page: pageID, workbench: workbench))
    }

    required init?(coder: NSCoder) {
        fatalError("FilePageView is created in code")
    }

    isolated deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// Source, Preview or Side by Side, for Markdown and SVG.
    var mode: EditorPreferences.MarkdownMode { state.mode }
    var previewable: Bool { state.previewable }
    func setMode(_ mode: EditorPreferences.MarkdownMode) { state.mode = mode }

    /// What takes the keyboard when the page does.
    var focusTarget: NSView { editor?.textView ?? preview ?? mediaView ?? self }

    override var acceptsFirstResponder: Bool { editor == nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance { layer?.backgroundColor = Colors.terminalBackground.cgColor }
    }

    // MARK: Content

    /// Builds the view the file needs, again only when its kind or the preview mode changes.
    private func update() {
        let content = document.content
        let mode: EditorPreferences.MarkdownMode? = state.previewable ? state.mode : nil
        effectiveAppearance.performAsCurrentDrawingAppearance { layer?.backgroundColor = Colors.terminalBackground.cgColor }
        if let shown, shown.0 == content, shown.1 == mode { return }
        let hadFocus = window?.firstResponder.flatMap { $0 as? NSView }.map { $0.isDescendant(of: self) } ?? false
        shown = (content, mode)
        body.subviews.forEach { $0.removeFromSuperview() }
        preview = nil
        mediaView = nil
        var editorWanted = false
        let view: NSView
        switch content {
        case .loading:
            view = NSView()
        case .text:
            switch mode {
            case .preview?:
                view = makePreview()
            case .sideBySide?:
                editorWanted = true
                let split = NSSplitView()
                split.isVertical = true
                split.dividerStyle = .thin
                let editor = editorView()
                let preview = makePreview()
                split.addArrangedSubview(editor)
                split.addArrangedSubview(preview)
                DispatchQueue.main.async { split.setPosition(split.bounds.width / 2, ofDividerAt: 0) }
                view = split
            default:
                editorWanted = true
                view = editorView()
            }
        case .image:
            let image = ImagePreview(url: document.url)
            image.fitsPage = state.fitsPage
            mediaView = image
            state.imageSize = image.image?.size
            view = image
        case .pdf:
            let pdf = PDFPreview(url: document.url)
            mediaView = pdf
            view = pdf
        case .binary, .tooLarge, .missing, .unreadable:
            view = NSHostingView(rootView: UnreadablePage(document: document))
        }
        if !editorWanted { editor = nil }
        view.translatesAutoresizingMaskIntoConstraints = false
        body.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: body.topAnchor),
            view.bottomAnchor.constraint(equalTo: body.bottomAnchor),
            view.leadingAnchor.constraint(equalTo: body.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: body.trailingAnchor),
        ])
        if content == .text, let reveal = workbench.files.takeReveal(page: pageID) {
            DispatchQueue.main.async { [weak self] in self?.editor?.textView.show(line: reveal.line, column: reveal.column) }
        }
        if hadFocus || workbench.focusedPageID == pageID {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.window != nil else { return }
                self.window?.makeFirstResponder(self.focusTarget)
            }
        }
    }

    /// The editor, kept across mode changes so its undo, scroll and selection stay.
    private func editorView() -> CodeEditorView {
        if let editor { return editor }
        let editor = CodeEditorView(document: document)
        editor.textView.onGoToLine = { [weak self] in self?.showLineField() }
        editor.onScroll = { [weak self] line in self?.state.editorTopLine = line }
        self.editor = editor
        return editor
    }

    private func makePreview() -> NSView {
        let host: NSView
        if document.language == .markdown {
            host = NSHostingView(rootView: PreviewHost(document: document, state: state) { [weak self] url in self?.open(url) })
        } else {
            // SVG: the picture, drawn again as the text changes.
            host = NSHostingView(rootView: SVGPreview(document: document))
        }
        preview = host
        return host
    }

    /// A link in the preview: a file beside it opens here (Markdown in its preview), the web in the browser.
    private func open(_ url: URL) {
        if let scheme = url.scheme, scheme != "file" {
            NSWorkspace.shared.open(url)
            return
        }
        let base = document.url.deletingLastPathComponent()
        let path = url.isFileURL ? url.path : (url.relativeString.removingPercentEncoding ?? url.relativeString).components(separatedBy: "#")[0]
        let target = path.hasPrefix("/") ? URL(fileURLWithPath: path) : base.appendingPathComponent(path)
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: target.path, isDirectory: &isFolder) else { return NSSound.beep() }
        if isFolder.boolValue {
            NSWorkspace.shared.activateFileViewerSelecting([target])
        } else {
            workbench.open(file: target.path, mode: .keep)
        }
    }

    // MARK: Go to Line

    @objc private func revealRequested(_ notification: Notification) {
        guard let reveal = workbench.files.takeReveal(page: pageID) else { return }
        if state.previewable && state.mode == .preview { state.mode = .source }
        DispatchQueue.main.async { [weak self] in self?.editor?.textView.show(line: reveal.line, column: reveal.column) }
    }

    /// Editor › Go to Line… (⌘L, ⌃G): a small field under the header; Return goes, Esc closes.
    func showLineField() {
        guard document.isText else { return }
        if state.previewable && state.mode == .preview { state.mode = .source }
        lineField?.close()
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let count = document.lines.lineCount
        popover.contentViewController = NSHostingController(rootView: GoToLineField(lineCount: count) { [weak self, weak popover] line, column in
            popover?.close()
            guard let self, let line else { return }
            self.editor?.textView.show(line: line, column: column)
            self.window?.makeFirstResponder(self.editor?.textView)
        })
        let anchor = NSRect(x: header.bounds.midX - 1, y: 0, width: 2, height: header.bounds.height)
        popover.show(relativeTo: anchor, of: header, preferredEdge: .maxY)
        lineField = popover
    }
}

/// A page beside others in its tab shows whether it has the keyboard, as panes do (`PaneFocusView`).
enum PageDimming {
    static func attach(to view: NSView, page: UUID, workbench: Workbench) -> Observing {
        let dim = PaneFocusView()
        dim.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(dim, positioned: .above, relativeTo: nil)
        NSLayoutConstraint.activate([
            dim.topAnchor.constraint(equalTo: view.topAnchor),
            dim.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            dim.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            dim.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        return Observing { [weak workbench, weak dim] in
            guard let workbench, let dim, let (_, tab) = workbench.workspace(of: page) else { return }
            dim.state = PaneFocusView.State(tab: tab, pane: page)
        }
    }
}

/// The page's own state that its header, preview and editor share.
@Observable
final class FilePageState {
    let document: FileDocument
    var mode: EditorPreferences.MarkdownMode {
        didSet { if previewable { EditorPreferences.shared.markdownMode = mode } }
    }
    var fitsPage = true { didSet { onActualSize?(fitsPage) } }
    var imageSize: NSSize?
    var editorTopLine: Int?
    @ObservationIgnored var onGoToLine: (() -> Void)?
    @ObservationIgnored var onActualSize: ((Bool) -> Void)?

    init(document: FileDocument) {
        self.document = document
        let preferred = EditorPreferences.shared.markdownMode
        // An SVG opens as its picture; Markdown as last chosen.
        mode = document.url.pathExtension.lowercased() == "svg" ? .preview : preferred
    }

    /// Markdown and SVG have a preview.
    var previewable: Bool { document.isText && (document.language == .markdown || document.url.pathExtension.lowercased() == "svg") }
}

private struct PreviewHost: View {
    let document: FileDocument
    let state: FilePageState
    let openLink: (URL) -> Void

    var body: some View {
        MarkdownPreview(document: document, followLine: state.mode == .sideBySide ? state.editorTopLine : nil, openLink: openLink)
    }
}

/// An SVG's picture, from the text as it is now.
private struct SVGPreview: View {
    let document: FileDocument

    var body: some View {
        let _ = document.version
        Group {
            if let data = document.storage.string.data(using: .utf8), let image = NSImage(data: data) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: max(image.size.width, 64), maxHeight: max(image.size.height, 64))
                    .padding(32)
            } else {
                Text(String(localized: "This SVG can’t be drawn.")).foregroundStyle(Color.ink3)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: Colors.terminalBackground))
    }
}

/// The header: the file's place in its repository (the folders faint, the name strong), then the view's
/// tools: Source / Preview / Side by Side for Markdown and SVG, Fit / Actual Size for a picture, and Compare
/// with HEAD for a file with changes.
private struct FileHeader: View {
    let document: FileDocument
    let workbench: Workbench
    @Bindable var state: FilePageState

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: FileIcon.symbol(for: document.url.lastPathComponent, folder: false))
                .font(.system(size: 11))
                .foregroundStyle(Color.ink3)
                .accessibilityHidden(true)
            breadcrumb
            Spacer(minLength: 12)
            if document.content == .image, let size = state.imageSize {
                Text(verbatim: "\(Int(size.width)) × \(Int(size.height))")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(Color.ink3)
                HeaderButton(symbol: state.fitsPage ? "arrow.up.left.and.arrow.down.right" : "arrow.down.right.and.arrow.up.left",
                             help: state.fitsPage ? String(localized: "Actual Size") : String(localized: "Zoom to Fit")) { state.fitsPage.toggle() }
            }
            if changed {
                HeaderButton(symbol: "arrow.left.arrow.right", help: String(localized: "Compare with HEAD")) {
                    workbench.openChanges(path: document.url.path, staged: false, mode: .keep)
                }
            }
            if state.previewable {
                Picker(String(localized: "View"), selection: $state.mode) {
                    Image(systemName: "chevron.left.forwardslash.chevron.right").help(String(localized: "Source")).tag(EditorPreferences.MarkdownMode.source)
                    Image(systemName: "eye").help(String(localized: "Preview")).tag(EditorPreferences.MarkdownMode.preview)
                    Image(systemName: "rectangle.split.2x1").help(String(localized: "Side by Side")).tag(EditorPreferences.MarkdownMode.sideBySide)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
                .accessibilityLabel(String(localized: "Source, Preview or Side by Side"))
            }
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: Colors.terminalBackground))
        .overlay(alignment: .bottom) { Color.line.frame(height: 1) }
    }

    /// Whether the file has changes against HEAD (the Changes list's view of it).
    private var changed: Bool {
        guard let repository = workbench.files.repository(containing: document.url), let relative = repository.relativePath(of: document.url) else { return false }
        return repository.status?.decorations[relative].map { $0 != .untracked && $0 != .ignored } ?? false
    }

    private var breadcrumb: some View {
        let parts = crumbs
        return HStack(spacing: 4) {
            ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                if index > 0 {
                    Image(systemName: "chevron.compact.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Color.ink3.opacity(0.7))
                }
                Text(part)
                    .font(.system(size: 11.5, weight: index == parts.count - 1 ? .medium : .regular))
                    .foregroundStyle(index == parts.count - 1 ? Color.ink : Color.ink3)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(index == parts.count - 1 ? 1 : 0)
            }
            if document.isEdited {
                Text(String(localized: "Edited", comment: "File header: the file has unsaved changes"))
                    .font(.system(size: 11))
                    .foregroundStyle(Color.ink3)
            }
        }
        .help(abbreviatingHome(document.url.path))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(abbreviatingHome(document.url.path))
    }

    /// The folders from the repository's top down to the file.
    private var crumbs: [String] {
        if let repository = workbench.files.repository(containing: document.url), let relative = repository.relativePath(of: document.url) {
            return [repository.name] + relative.split(separator: "/").map(String.init)
        }
        return abbreviatingHome(document.url.path).split(separator: "/").suffix(4).map(String.init)
    }
}

/// A small borderless tool button in a header.
struct HeaderButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(Look.smallIcon)
                .foregroundStyle(Color.ink2)
                .frame(width: 24, height: 22)
        }
        .buttonStyle(ChromeButtonStyle(radius: Look.Radius.small))
        .help(help)
        .accessibilityLabel(help)
    }
}

/// The bar when the disk changed under unsaved changes (Reload · Keep Mine), or the file went away.
private struct DiskBanner: View {
    let document: FileDocument
    let workbench: Workbench
    let page: UUID

    var body: some View {
        if let change = document.diskChange {
            HStack(spacing: 10) {
                Image(systemName: change == .deleted ? "trash" : "arrow.triangle.2.circlepath")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.ink2)
                Text(change == .deleted
                     ? String(localized: "“\(document.name)” was deleted or moved. Your text is still here.")
                     : String(localized: "“\(document.name)” changed on disk while you were editing it."))
                    .font(.system(size: 12))
                    .foregroundStyle(Color.ink)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if change == .deleted {
                    Button(String(localized: "Save")) { workbench.save(document) }
                    Button(String(localized: "Close")) { workbench.close(page: page) }
                } else {
                    Button(String(localized: "Keep Mine")) { document.keepMine() }
                    Button(String(localized: "Reload")) { document.revert() }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .controlSize(.small)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.accent.opacity(0.1))
            .overlay(alignment: .bottom) { Color.line.frame(height: 1) }
            .accessibilityElement(children: .contain)
        }
    }
}

/// Go to Line's field: a line, or "line:column".
private struct GoToLineField: View {
    let lineCount: Int
    let go: (Int?, Int?) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "number").foregroundStyle(Color.ink3)
            TextField(String(localized: "Line (1–\(lineCount))", comment: "Go to Line: the field's placeholder"), text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13).monospacedDigit())
                .frame(width: 150)
                .focused($focused)
                .onSubmit {
                    let parts = text.split(separator: ":").map { Int($0.trimmingCharacters(in: .whitespaces)) }
                    go(parts.first ?? nil, parts.count > 1 ? parts[1] : nil)
                }
                .onExitCommand { go(nil, nil) }
        }
        .padding(10)
        .onAppear { focused = true }
    }
}

/// The focused editor's cursor, for the status line ("Ln 12, Col 4").
@Observable
final class EditorStatus {
    static let shared = EditorStatus()
    private(set) var line = 1
    private(set) var column = 1
    private(set) var selected = 0
    /// Which document the numbers are for.
    private(set) var documentID: ObjectIdentifier?

    func update(from editor: CodeEditorView) {
        let selection = editor.textView.selectedRange()
        let lines = editor.document.lines
        let index = lines.line(at: selection.location)
        let newLine = index + 1, newColumn = selection.location - lines.starts[index] + 1
        let id = ObjectIdentifier(editor.document)
        if documentID != id { documentID = id }
        if line != newLine { line = newLine }
        if column != newColumn { column = newColumn }
        if selected != selection.length { selected = selection.length }
    }
}

/// SF Symbols for files and folders, by kind: calm, monochrome, the theme's ink.
enum FileIcon {
    static func symbol(for name: String, folder: Bool) -> String {
        if folder { return "folder" }
        let lower = name.lowercased()
        let ext = (lower as NSString).pathExtension
        switch ext {
        case "swift": return "swift"
        case "md", "markdown", "mdx", "txt", "rtf": return "doc.text"
        case "png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "tiff", "bmp", "ico", "svg": return "photo"
        case "pdf": return "doc.richtext"
        case "json", "yml", "yaml", "toml", "plist", "xml": return "curlybraces"
        case "sh", "bash", "zsh", "fish": return "terminal"
        case "zip", "gz", "tgz", "tar", "xz", "dmg": return "archivebox"
        case "mp4", "mov", "m4v": return "film"
        case "mp3", "wav", "aiff", "m4a": return "waveform"
        case "lock": return "lock"
        default:
            if lower.hasPrefix(".git") || lower == "dockerfile" || lower == "makefile" || lower.hasPrefix(".env") { return "gearshape" }
            return SyntaxLanguage.detect(fileName: name, firstLine: nil) == .plain ? "doc" : "chevron.left.forwardslash.chevron.right"
        }
    }
}
