import AppKit
import Observation
import UniformTypeIdentifiers
import WhiskrKit

/// An open file: its text (shared by every editor showing it), what it takes to write it back exactly as
/// it was, and whether it differs from the disk. Saving is explicit (⌘S); while unsaved its tab shows a
/// dot. When the file changes on disk (Claude edits constantly), an untouched document follows the disk
/// at once, keeping the selection and scroll; one with your changes shows a bar asking (`FileSync`).
@Observable
final class FileDocument {
    enum Content: Equatable {
        case loading
        case text
        case image
        case pdf
        /// Not text (`TextFile.read` found NUL bytes).
        case binary
        /// Larger than the editor opens, in bytes.
        case tooLarge(Int)
        case missing
        case unreadable(String)
    }

    /// What the disk did that the editor has not taken in.
    enum DiskChange: Equatable {
        /// The file changed while you had unsaved changes.
        case changed
        case deleted
    }

    /// Files up to this size open in the editor (a 50,000-line source file is about 2 MB).
    nonisolated static let largest = 10 * 1024 * 1024

    private(set) var url: URL
    private(set) var content: Content = .loading
    private(set) var language: SyntaxLanguage
    /// The encoding and line breaks the file is written back with.
    private(set) var format = TextFile(text: "")
    var indentation = Indentation(usesTabs: false, width: 4)
    /// The text differs from what was last read or saved.
    private(set) var isEdited = false
    private(set) var diskChange: DiskChange?
    /// Goes up with every change of the text, for views that follow it (the Markdown preview).
    private(set) var version = 0

    /// The text, in a TextKit 2 content storage that each editor's layout manager attaches to.
    @ObservationIgnored let contentStorage = NSTextContentStorage()
    @ObservationIgnored var storage: NSTextStorage { contentStorage.textStorage! }
    @ObservationIgnored let undoManager = UndoManager()
    @ObservationIgnored private(set) var lines = LineIndex("")
    @ObservationIgnored private(set) var syntax: SyntaxStates
    /// The bytes last read or written: the disk holding these again is our own save, not a change.
    @ObservationIgnored private var known = Data()
    @ObservationIgnored private var savedText: NSString = ""
    @ObservationIgnored private var checkScheduled = false
    @ObservationIgnored private var editors: [ObjectIdentifier: Editing] = [:]
    @ObservationIgnored private var loading: Task<Void, Never>?
    @ObservationIgnored private var replacing = false

    /// What an editor showing this document is told.
    struct Editing {
        /// Lines `lines` (in the new text) were edited, replacing `replacing` old lines; colours may have
        /// changed for `recoloured`.
        var edited: (_ lines: Range<Int>, _ recoloured: Range<Int>) -> Void
        /// The whole text is about to be replaced from the disk, then has been.
        var willReload: () -> Void
        var didReload: () -> Void
    }

    init(url: URL) {
        self.url = url
        let language = SyntaxLanguage.detect(fileName: url.lastPathComponent, firstLine: nil)
        self.language = language
        syntax = SyntaxStates(lexer: SyntaxLexer(language: language), lineCount: 1)
        contentStorage.textStorage = NSTextStorage()
        storage.delegate = StorageDelegate.shared
        StorageDelegate.shared.documents[ObjectIdentifier(storage)] = WeakDocument(self)
        load()
    }

    var name: String { url.lastPathComponent }
    var isText: Bool { content == .text }

    /// Kinds of file shown as pictures rather than text.
    nonisolated static func kind(of url: URL) -> Content? {
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else { return nil }
        if type.conforms(to: .pdf) { return .pdf }
        // SVG is text, with a preview: it opens in the editor.
        if type.conforms(to: .svg) { return nil }
        if type.conforms(to: .image) { return .image }
        return nil
    }

    // MARK: Editors

    func attach(_ owner: AnyObject, _ editing: Editing) { editors[ObjectIdentifier(owner)] = editing }
    func detach(_ owner: AnyObject) { editors[ObjectIdentifier(owner)] = nil }

    // MARK: Reading

    /// Reads the file off the main thread and shows it.
    private func load() {
        let url = url
        loading = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { Self.read(url) }.value
            guard let self, !Task.isCancelled else { return }
            self.take(result)
        }
    }

    enum ReadResult: Sendable {
        case text(TextFile, Data)
        case other(Content, Data?)
    }

    nonisolated static func read(_ url: URL) -> ReadResult {
        let path = url.path
        guard FileManager.default.fileExists(atPath: path) else { return .other(.missing, nil) }
        if let kind = kind(of: url) { return .other(kind, nil) }
        let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
        if size > largest { return .other(.tooLarge(size), nil) }
        do {
            let data = try Data(contentsOf: url)
            switch TextFile.read(data) {
            case .text(let file): return .text(file, data)
            case .binary: return .other(.binary, data)
            }
        } catch {
            return .other(.unreadable(error.localizedDescription), nil)
        }
    }

    private func take(_ result: ReadResult) {
        switch result {
        case .text(let file, let data):
            known = data
            format = file
            if content != .text {
                language = SyntaxLanguage.detect(fileName: url.lastPathComponent, firstLine: file.text.prefix(200).split(separator: "\n").first.map(String.init))
                indentation = Indentation.detect(in: file.text, tabWidth: EditorPreferences.shared.tabWidth)
                    ?? Indentation(usesTabs: false, width: EditorPreferences.shared.tabWidth)
            }
            replaceText(with: file.text)
            content = .text
        case .other(let kind, let data):
            known = data ?? Data()
            content = kind
        }
        diskChange = nil
    }

    /// The whole text from the disk: the editors keep their place, and undo starts afresh.
    private func replaceText(with text: String) {
        for editor in editors.values { editor.willReload() }
        replacing = true
        storage.beginEditing()
        storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: text)
        storage.setAttributes(EditorStyle.shared.baseAttributes, range: NSRange(location: 0, length: storage.length))
        storage.endEditing()
        replacing = false
        lines = LineIndex(text)
        syntax = SyntaxStates(lexer: SyntaxLexer(language: language), lineCount: lines.lineCount)
        savedText = NSString(string: text)
        isEdited = false
        undoManager.removeAllActions()
        version += 1
        lexInBackground()
        for editor in editors.values { editor.didReload() }
    }

    /// The states of every line, worked out off the main thread so the first scroll to the end of a long
    /// file never waits for them; taken in only if the text has not changed meanwhile.
    private func lexInBackground() {
        let text = storage.string
        let starting = version
        let lexer = SyntaxLexer(language: language)
        let count = lines.lineCount
        Task { [weak self] in
            let states = await Task.detached(priority: .utility) { () -> SyntaxStates in
                var states = SyntaxStates(lexer: lexer, lineCount: count)
                let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
                _ = states.state(atLine: count - 1) { index in index < lines.count ? String(lines[index]) : "" }
                return states
            }.value
            guard let self, self.version == starting else { return }
            self.syntax.adopt(states)
        }
    }

    // MARK: Editing

    /// The storage changed (typing, paste, undo): the line index and the lexer states follow, and the
    /// editors repaint what changed.
    fileprivate func storageEdited(range: NSRange, changeInLength delta: Int) {
        guard !replacing else { return }
        let removed = range.location..<(range.location + range.length - delta)
        let inserted = (storage.string as NSString).substring(with: range)
        let change = lines.replace(removed, with: inserted)
        syntax.replaceLines(change.lines.lowerBound..<(change.lines.lowerBound + change.replacing), with: change.lines.count)
        let recoloured = syntax.relex(change.lines, budget: 400) { [unowned self] in self.lineText($0) }
        version += 1
        for editor in editors.values { editor.edited(change.lines, recoloured) }
        scheduleEditedCheck()
    }

    /// A line's text without its "\n".
    func lineText(_ line: Int) -> String {
        guard line < lines.lineCount else { return "" }
        let range = lines.range(ofLine: line)
        return (storage.string as NSString).substring(with: NSRange(location: range.lowerBound, length: range.count))
    }

    /// Tokens of a line, for the painter.
    func tokens(line: Int) -> [SyntaxToken] {
        syntax.tokens(line: line) { [unowned self] in self.lineText($0) }
    }

    /// Whether the text still differs from the disk's, checked once per burst of edits (typing back what
    /// was there makes the document clean again).
    private func scheduleEditedCheck() {
        guard !checkScheduled else { return }
        checkScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.checkScheduled = false
            let edited = !(self.storage.string as NSString).isEqual(to: self.savedText as String)
            if self.isEdited != edited { self.isEdited = edited }
        }
    }

    func setLanguage(_ language: SyntaxLanguage) {
        guard language != self.language else { return }
        self.language = language
        syntax = SyntaxStates(lexer: SyntaxLexer(language: language), lineCount: lines.lineCount)
        version += 1
        lexInBackground()
        for editor in editors.values { editor.edited(0..<0, 0..<lines.lineCount) }
    }

    /// Edit › Line Endings: written back with these from the next save.
    func setLineEnding(_ ending: LineEnding) {
        guard format.lineEnding != ending || format.hadMixedLineEndings else { return }
        format.lineEnding = ending
        format.hadMixedLineEndings = false
        // The bytes on disk no longer match what would be written: saving is needed.
        isEdited = true
    }

    // MARK: Saving

    enum SaveError: LocalizedError {
        case writing(String)
        var errorDescription: String? {
            switch self { case .writing(let why): why }
        }
    }

    /// Writes the text with the file's encoding and line breaks, keeping its permissions (a script stays
    /// executable) and writing through a symbolic link to the file it points at.
    func save() throws {
        guard content == .text else { return }
        let text = storage.string
        format.encoding = format.encodingNeeded(for: text)
        let data = format.data(for: text)
        let target = url.resolvingSymlinksInPath()
        let permissions = (try? FileManager.default.attributesOfItem(atPath: target.path))?[.posixPermissions]
        do {
            try data.write(to: target, options: .atomic)
            if let permissions { try? FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: target.path) }
        } catch {
            throw SaveError.writing(error.localizedDescription)
        }
        known = data
        savedText = NSString(string: text)
        format.hadMixedLineEndings = false
        isEdited = false
        diskChange = nil
    }

    /// File › Save As…: the text is written to `newURL`, which this document then is.
    func save(as newURL: URL) throws {
        let old = url
        url = newURL
        do {
            try save()
        } catch {
            url = old
            throw error
        }
    }

    /// File › Revert to Saved, and the bar's Reload: the disk's version, your changes dropped.
    func revert() {
        let url = url
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { Self.read(url) }.value
            self?.take(result)
        }
    }

    /// The bar's Keep Mine: your version stays; the next save writes it over the disk's.
    func keepMine() {
        diskChange = nil
        isEdited = true
    }

    /// The file was renamed or moved (in the file tree): the document follows it.
    func moved(to newURL: URL) {
        url = newURL
        let detected = SyntaxLanguage.detect(fileName: newURL.lastPathComponent, firstLine: lineText(0))
        if detected != language { setLanguage(detected) }
    }

    // MARK: The disk

    /// Something changed at this file's path: looks at the disk off the main thread and follows it, asks,
    /// or says it is gone (`FileSync`).
    func diskMayHaveChanged() {
        let url = url
        Task { [weak self] in
            let disk = await Task.detached(priority: .utility) { () -> Data? in
                FileManager.default.fileExists(atPath: url.path) ? try? Data(contentsOf: url) : nil
            }.value
            guard let self, self.url == url else { return }
            switch self.content {
            case .text:
                switch FileSync.respond(disk: disk, known: self.known, edited: self.isEdited) {
                case .nothing: break
                case .reload: self.revert()
                case .ask: self.diskChange = .changed
                case .deleted: self.diskChange = .deleted
                }
            case .loading:
                break
            default:
                // A picture or a page about the file: shown afresh.
                if disk != self.known { self.revert() }
            }
        }
    }
}

/// Routes each storage's edits to its document (NSTextStorage holds its delegate weakly; one shared
/// delegate keeps that simple).
private final class StorageDelegate: NSObject, NSTextStorageDelegate {
    static let shared = StorageDelegate()
    var documents: [ObjectIdentifier: WeakDocument] = [:]

    func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions, range editedRange: NSRange, changeInLength delta: Int) {
        guard editedMask.contains(.editedCharacters) else { return }
        guard let document = documents[ObjectIdentifier(textStorage)]?.document else {
            documents[ObjectIdentifier(textStorage)] = nil
            return
        }
        document.storageEdited(range: editedRange, changeInLength: delta)
    }
}

private struct WeakDocument {
    weak var document: FileDocument?
    init(_ document: FileDocument) { self.document = document }
}
