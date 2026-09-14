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
    private(set) var language: CodeLanguage
    /// A line too long to edit smoothly (`longLineEditLimit`), while it is kept from being edited.
    private(set) var guardedLine: GuardedLine?
    /// The person chose to edit over-long lines anyway (the bar's Edit Anyway).
    private(set) var editsLongLines = false

    struct GuardedLine: Equatable {
        var line: Int
        var length: Int
    }

    /// Past this many UTF-16 units, a line is kept from being edited until asked: TextKit lays a paragraph
    /// out again whole on every keystroke in it, about 0.17 ms per thousand characters on an M-series Mac,
    /// so from here a key would take most of a frame (a minified file's 2 MB line: a third of a second).
    /// Lines past 20,000 units are not coloured either (`TextMateTokenizer.lineLimit`), as in VS Code.
    nonisolated static let longLineEditLimit = 80_000

    /// The language was chosen in the status bar rather than detected: it stays when the file is renamed.
    private(set) var languageIsChosen = false
    /// Languages chosen in the status bar, by path, for as long as the app runs (a file closed and opened
    /// again keeps it, as VS Code does within a window).
    private static var chosenLanguages: [String: String] = [:]
    /// The encoding and line breaks the file is written back with.
    private(set) var format = TextFile(text: "")
    var indentation = Indentation(usesTabs: false, width: 4)
    /// What the repository's `.editorconfig` files ask of this file, as of opening or the last save.
    private(set) var editorConfig = EditorConfig.Properties()
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
    /// The colours' tokens, worked out as the text changes.
    @ObservationIgnored private lazy var syntax = DocumentSyntax(language: language) { [unowned self] in (self.storage.string as NSString, self.lines) }
    /// For each line: the bold and italic runs its paragraph was laid out with (`SyntaxParagraphs`), -1 for
    /// a paragraph not laid out since its text last changed.
    @ObservationIgnored private var fontSignatures: [Int] = [-1]
    /// The bytes last read or written: the disk holding these again is our own save, not a change.
    @ObservationIgnored private var known = Data()
    /// The disk's bytes the bar is asking about (Reload or Keep Mine).
    @ObservationIgnored private var askedAbout: Data?
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
        /// Colours changed for these lines, apart from an edit (the background's tokens arriving).
        var recoloured: (_ lines: Range<Int>) -> Void
        /// The whole text is about to be replaced from the disk, then has been.
        var willReload: () -> Void
        var didReload: () -> Void
    }

    init(url: URL) {
        self.url = url
        if let id = Self.chosenLanguages[url.path], let chosen = LanguageRegistry.shared.language(id: id) {
            language = chosen
            languageIsChosen = true
        } else {
            language = LanguageRegistry.shared.detect(fileName: url.lastPathComponent)
        }
        contentStorage.textStorage = NSTextStorage()
        storage.delegate = StorageDelegate.shared
        StorageDelegate.shared.documents[ObjectIdentifier(storage)] = WeakDocument(self)
        contentStorage.delegate = SyntaxParagraphs.shared
        SyntaxParagraphs.shared.documents[ObjectIdentifier(contentStorage)] = WeakDocument(self)
        syntax.onChange = { [weak self] lines in self?.recoloured(lines) }
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
        let chosen = Self.chosenLanguages[url.path]
        EditorStyle.shared.warmFonts()
        let faces = EditorStyle.shared.faces
        loading = Task { [weak self] in
            let (result, editorConfig) = await Task.detached(priority: .userInitiated) {
                (await Self.read(url, preparing: chosen, warming: faces), EditorConfig.properties(forFileAt: url.path))
            }.value
            guard let self, !Task.isCancelled else { return }
            self.editorConfig = editorConfig
            self.take(result)
        }
    }

    enum ReadResult: Sendable {
        case text(TextFile, Data, PreparedSyntax?)
        case other(Content, Data?)
    }

    /// The first screenful's colours, worked out with the file's reading, off the main thread: the text
    /// is laid out once, already in its colours and italics, instead of plain and then again.
    nonisolated struct PreparedSyntax: Sendable {
        let language: CodeLanguage
        let tokenizer: TextMateTokenizer
        let states: SyntaxStates

        /// Lines tokenized before the text is shown: more than a tall window holds.
        static let lines = 160
        /// And at most this long (nanoseconds).
        static let budget: UInt64 = 25_000_000
    }

    /// `read`, then the first lines tokenized in the language the file will be shown in (`chosen`, an id
    /// from the status bar, or the one detected).
    nonisolated static func read(_ url: URL, preparing chosen: String?, warming faces: EditorStyle.Faces) async -> ReadResult {
        let registry = LanguageRegistry.shared
        // The grammar the name points to is compiled while the file is read (the first line may name
        // another, rarely).
        let byName = chosen.flatMap(registry.language(id:)) ?? registry.detect(fileName: url.lastPathComponent)
        let compiled = Task.detached(priority: .userInitiated) { await GrammarStore.shared.tokenizer(for: byName) }
        let result = read(url)
        guard case .text(let file, let data, _) = result else { return result }
        // The fonts the first screen's own symbols fall back to are read now, not in its first frame.
        faces.warm(EditorStyle.Faces.commonText + EditorStyle.Faces.unusual(in: file.text.prefix(PreparedSyntax.lines * 120)))
        let language = chosen.flatMap(registry.language(id:))
            ?? registry.detect(fileName: url.lastPathComponent, firstLine: file.text.prefix(200).split(separator: "\n").first.map(String.init))
        let text = file.text as NSString
        let lines = LineIndex(file.text)
        // A file of lines too long to colour (minified) gains nothing from it, and need not wait for it.
        guard lines.longestLine.length <= TextMateTokenizer.lineLimit else { return result }
        let tokenizer = language == byName ? await compiled.value : await GrammarStore.shared.tokenizer(for: language)
        guard let tokenizer else { return result }
        var states = SyntaxStates(lineCount: lines.lineCount)
        states.advance(using: tokenizer, deadline: DispatchTime.now().uptimeNanoseconds + PreparedSyntax.budget, lines: PreparedSyntax.lines) {
            TextSnapshot.units(of: text, lines: lines, line: $0)
        }
        return .text(file, data, PreparedSyntax(language: language, tokenizer: tokenizer, states: states))
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
            case .text(let file): return .text(file, data, nil)
            case .binary: return .other(.binary, data)
            }
        } catch {
            return .other(.unreadable(error.localizedDescription), nil)
        }
    }

    private func take(_ result: ReadResult) {
        switch result {
        case .text(let file, let data, let prepared):
            known = data
            format = file
            if content != .text {
                let detected = prepared?.language ?? LanguageRegistry.shared.detect(fileName: url.lastPathComponent, firstLine: file.text.prefix(200).split(separator: "\n").first.map(String.init))
                if !languageIsChosen, detected != language {
                    language = detected
                    // With the first lines prepared, the syntax takes the language with them (below).
                    if prepared == nil { syntax.setLanguage(detected) }
                }
                // The repository's EditorConfig first, then what the lines show, then Settings › Editor.
                let preferences = EditorPreferences.shared
                indentation = editorConfig.indentation(detected: Indentation.detect(in: file.text, tabWidth: preferences.tabWidth),
                                                       fallback: Indentation(usesTabs: !preferences.insertSpaces, width: preferences.tabWidth))
            }
            replaceText(with: file.text, prepared: prepared?.language == language ? prepared : nil)
            content = .text
        case .other(let kind, let data):
            known = data ?? Data()
            content = kind
        }
        diskChange = nil
        askedAbout = nil
    }

    /// The whole text from the disk: the editors keep their place, and undo starts afresh.
    private func replaceText(with text: String, prepared: PreparedSyntax? = nil) {
        for editor in editors.values { editor.willReload() }
        replacing = true
        storage.beginEditing()
        storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: text)
        storage.setAttributes(EditorStyle.shared.baseAttributes(tabWidth: tabWidth), range: NSRange(location: 0, length: storage.length))
        storage.endEditing()
        replacing = false
        lines = LineIndex(text)
        fontSignatures = Array(repeating: -1, count: lines.lineCount)
        findGuardedLine()
        if let prepared {
            syntax.reset(language: prepared.language, tokenizer: prepared.tokenizer, states: prepared.states)
        } else {
            syntax.reset()
        }
        savedText = NSString(string: text)
        isEdited = false
        undoManager.removeAllActions()
        version += 1
        for editor in editors.values { editor.didReload() }
    }

    // MARK: Editing

    /// The storage changed (typing, paste, undo): the line index and the lexer states follow, and the
    /// editors repaint what changed.
    fileprivate func storageEdited(range: NSRange, changeInLength delta: Int) {
        guard !replacing else { return }
        let removed = range.location..<(range.location + range.length - delta)
        let inserted = (storage.string as NSString).substring(with: range)
        let change = lines.replace(removed, with: inserted)
        let replaced = change.lines.lowerBound..<(change.lines.lowerBound + change.replacing)
        fontSignatures.replaceSubrange(replaced.clamped(to: 0..<fontSignatures.count), with: Array(repeating: -1, count: change.lines.count))
        let recoloured = syntax.edited(replaced, count: change.lines.count)
        if guardedLine != nil || inserted.utf16.count > Self.longLineEditLimit { findGuardedLine() }
        version += 1
        for editor in editors.values { editor.edited(change.lines, recoloured) }
        scheduleEditedCheck()
    }

    // MARK: Over-long lines

    private func findGuardedLine() {
        let longest = lines.longestLine
        let found = !editsLongLines && longest.length > Self.longLineEditLimit ? GuardedLine(line: longest.line, length: longest.length) : nil
        if found != guardedLine { guardedLine = found }
    }

    /// Whether a change of `ranges` would edit a line too long to edit smoothly (the editor refuses it;
    /// the page's bar says why and offers Edit Anyway).
    func blocksEdit(of ranges: [NSRange]) -> Bool {
        guard guardedLine != nil else { return false }
        for range in ranges {
            let first = lines.line(at: range.location), last = lines.line(at: NSMaxRange(range))
            for line in first...last where lines.range(ofLine: line).count > Self.longLineEditLimit { return true }
        }
        return false
    }

    /// The character at `location` is in a line kept from being edited.
    func isInGuardedLine(_ location: Int) -> Bool {
        guard guardedLine != nil else { return false }
        return lines.range(ofLine: lines.line(at: location)).count > Self.longLineEditLimit
    }

    /// The bar's Edit Anyway: over-long lines can be edited, slowly, until the file is closed.
    func allowLongLineEdits() {
        editsLongLines = true
        guardedLine = nil
    }

    /// A line's text without its "\n".
    func lineText(_ line: Int) -> String {
        guard line < lines.lineCount else { return "" }
        let range = lines.range(ofLine: line)
        return (storage.string as NSString).substring(with: NSRange(location: range.lowerBound, length: range.count))
    }

    /// Tokens of a line, for the painter: right, last known (while the background catches up), or none.
    func tokens(line: Int) -> [SyntaxToken] {
        syntax.tokens(line: line)
    }

    /// Whether text in `scopes` is code, a string or a comment.
    func context(of scopes: ScopeStack) -> TokenContext {
        syntax.context(of: scopes)
    }

    /// Every line's colours are worked out.
    var syntaxIsComplete: Bool { syntax.isComplete }

    /// Lines on screen in an editor: the background tokenizes them first if it has not reached them.
    func showLines(_ lines: Range<Int>) {
        syntax.show(lines)
    }

    /// The background's tokens arrived for `lines`: editors repaint them.
    private func recoloured(_ lines: Range<Int>) {
        for editor in editors.values { editor.recoloured(lines) }
    }

    // MARK: Bold and italic

    /// The bold and italic stretches of a line's tokens, and a number standing for them (0 for none). The
    /// caller has refreshed `EditorStyle`.
    fileprivate func fontRuns(line: Int, dark: Bool) -> (runs: [(range: Range<Int>, style: FontStyle)], signature: Int) {
        let style = EditorStyle.shared
        var runs: [(range: Range<Int>, style: FontStyle)] = []
        var hasher = Hasher()
        for token in syntax.tokens(line: line) {
            let fontStyle = style.look(token.scopes).fontStyle(dark: dark).intersection([.bold, .italic])
            guard !fontStyle.isEmpty else { continue }
            runs.append((token.range, fontStyle))
            hasher.combine(token.range.lowerBound)
            hasher.combine(token.range.upperBound)
            hasher.combine(fontStyle.rawValue)
        }
        return (runs, runs.isEmpty ? 0 : hasher.finalize() & Int.max | 1)
    }

    /// A line's paragraph was just made with these bold and italic runs.
    fileprivate func laidOut(line: Int, signature: Int) {
        if line < fontSignatures.count { fontSignatures[line] = signature }
    }

    /// Lines an editor is colouring (on screen, their tokens new): those whose paragraphs were laid out with
    /// other bold and italic runs are made again (fonts change glyphs, which colours as rendering
    /// attributes cannot). Only lines on screen: a comment opened above ten thousand laid-out lines makes
    /// again only the few shown, the rest when they come on screen.
    func refreshFonts(_ shown: IndexSet) {
        EditorStyle.shared.refresh()
        let dark = Palette.isDark(NSApp.effectiveAppearance)
        var stale: [Int] = []
        for line in shown where line < min(fontSignatures.count, lines.lineCount) && fontSignatures[line] != -1 {
            if fontRuns(line: line, dark: dark).signature != fontSignatures[line] { stale.append(line) }
        }
        guard !stale.isEmpty else { return }
        // A screenful at once (a file's first colours, a comment opened above) is laid out again a few
        // lines per turn of the run loop, so no one turn holds the main thread for long.
        let now = stale.prefix(Self.fontLinesPerTurn), later = stale.dropFirst(Self.fontLinesPerTurn)
        contentStorage.performEditingTransaction {
            for line in now {
                let range = lines.range(ofLine: line)
                fontSignatures[line] = -1
                storage.edited(.editedAttributes, range: NSRange(location: range.lowerBound, length: range.count), changeInLength: 0)
            }
        }
        guard !later.isEmpty else { return }
        let version = version
        DispatchQueue.main.async { [weak self] in
            guard let self, self.version == version else { return }
            self.refreshFonts(IndexSet(later))
        }
    }

    private static let fontLinesPerTurn = 12

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

    /// Languages were added or removed: grammars are compiled again when next needed, and every open file
    /// finds its language again (a grammar for it may have arrived, or replaced the bundled one).
    static func languagesChanged() {
        GrammarStore.shared.reset()
        for document in SyntaxParagraphs.shared.documents.values.compactMap(\.document) where document.isText {
            // A language chosen in the status bar stays, found again by its id (it may have been replaced);
            // only when it is gone does the file go back to what it is detected as.
            let chosen = Self.chosenLanguages[document.url.path].flatMap { LanguageRegistry.shared.language(id: $0) }
            if chosen == nil, document.languageIsChosen {
                Self.chosenLanguages[document.url.path] = nil
                document.languageIsChosen = false
            }
            let detected = chosen ?? LanguageRegistry.shared.detect(fileName: document.url.lastPathComponent, firstLine: document.lineText(0))
            document.language = detected
            document.syntax.reload(detected)
            document.version += 1
        }
    }

    /// The status bar's language menu: this file is coloured as `language` from now on (nil: as detected
    /// from its name and first line again).
    func choose(language chosen: CodeLanguage?) {
        if let chosen {
            Self.chosenLanguages[url.path] = chosen.id
            languageIsChosen = true
            setLanguage(chosen)
        } else {
            Self.chosenLanguages[url.path] = nil
            languageIsChosen = false
            setLanguage(detectedLanguage)
        }
    }

    /// What the file's name and first line say it is.
    var detectedLanguage: CodeLanguage {
        LanguageRegistry.shared.detect(fileName: url.lastPathComponent, firstLine: isText ? lineText(0) : nil)
    }

    func setLanguage(_ language: CodeLanguage) {
        guard language != self.language else { return }
        self.language = language
        syntax.setLanguage(language)
        version += 1
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
    /// executable) and writing through a symbolic link to the file it points at. First, as the repository's
    /// EditorConfig or Settings › Editor ask: trailing whitespace trimmed and a final line break added (one
    /// undoable change, as VS Code makes it), and the EditorConfig's line breaks and encoding taken on.
    func save() throws {
        guard content == .text else { return }
        // Set only when it changed: the editors follow it (a tab width), and lay the text out again.
        let editorConfig = EditorConfig.properties(forFileAt: url.path)
        if editorConfig != self.editorConfig { self.editorConfig = editorConfig }
        let preferences = EditorPreferences.shared
        // The tidied text and the format are worked out first and taken on only once the file is written:
        // a failed write leaves the buffer and its line breaks and encoding as they were.
        let edits = SaveFixes.edits(in: storage.string as NSString,
                                    trimTrailingWhitespace: editorConfig.trimTrailingWhitespace ?? preferences.trimTrailingWhitespace,
                                    insertFinalNewline: editorConfig.insertFinalNewline ?? preferences.insertFinalNewline)
        let tidied = NSMutableString(string: storage.string)
        for edit in edits.reversed() { tidied.replaceCharacters(in: edit.range, with: edit.text) }
        var format = format
        if let ending = editorConfig.endOfLine, ending != format.lineEnding {
            format.lineEnding = ending
            format.hadMixedLineEndings = false
        }
        if let charset = editorConfig.charset { format.encoding = charset }
        let text = tidied as String
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
        applyUndoably(edits, named: String(localized: "Tidy on Save", comment: "Undo menu: what saving trimmed or added"))
        format.hadMixedLineEndings = false
        self.format = format
        known = data
        savedText = NSString(string: text)
        isEdited = false
        diskChange = nil
        askedAbout = nil
    }

    /// Edits made outside any text view (saving's tidying), as one change the editors' Undo takes back.
    private func applyUndoably(_ edits: [SaveFixes.Edit], named name: String) {
        guard !edits.isEmpty else { return }
        let before = storage.string as NSString
        var shift = 0
        let inverse = edits.map { edit in
            let length = (edit.text as NSString).length
            defer { shift += length - edit.range.length }
            return SaveFixes.Edit(range: NSRange(location: edit.range.location + shift, length: length), text: before.substring(with: edit.range))
        }
        contentStorage.performEditingTransaction {
            storage.beginEditing()
            for edit in edits.reversed() { storage.replaceCharacters(in: edit.range, with: edit.text) }
            storage.endEditing()
        }
        undoManager.registerUndo(withTarget: self) { document in
            MainActor.assumeIsolated { document.applyUndoably(inverse, named: name) }
        }
        undoManager.setActionName(name)
    }

    /// How wide a tab is drawn in this file: its indentation's width when it indents with tabs, else the
    /// EditorConfig's `tab_width`, else Settings › Editor's.
    var tabWidth: Int {
        indentation.usesTabs ? indentation.width : editorConfig.tabWidth ?? EditorPreferences.shared.tabWidth
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

    /// The bar's Keep Mine: your version stays; the next save writes it over the disk's. The disk's version
    /// it was asked about counts as seen, so only a further change asks again (not every event in its folder).
    func keepMine() {
        if let askedAbout { known = askedAbout }
        askedAbout = nil
        diskChange = nil
        isEdited = true
    }

    /// The file was renamed or moved (in the file tree): the document follows it.
    func moved(to newURL: URL) {
        if let id = Self.chosenLanguages.removeValue(forKey: url.path) { Self.chosenLanguages[newURL.path] = id }
        url = newURL
        guard !languageIsChosen else { return }
        let detected = LanguageRegistry.shared.detect(fileName: newURL.lastPathComponent, firstLine: lineText(0))
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
                case .nothing:
                    // Back as it was (a branch switched away and back): nothing went after all.
                    if self.diskChange == .deleted { self.diskChange = nil }
                case .reload:
                    self.diskChange = nil
                    self.revert()
                case .ask:
                    self.askedAbout = disk
                    self.diskChange = .changed
                case .deleted:
                    self.diskChange = .deleted
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

/// Gives each paragraph its tokens' bold and italics as it is laid out (TextKit 2's way to show a paragraph
/// other than as stored): the storage keeps one font, and a paragraph whose bold or italic runs change is
/// made again when it is next coloured on screen (`FileDocument.refreshFonts`). Colours are rendering attributes, which need no layout.
private final class SyntaxParagraphs: NSObject, NSTextContentStorageDelegate {
    static let shared = SyntaxParagraphs()
    var documents: [ObjectIdentifier: WeakDocument] = [:]

    func textContentStorage(_ textContentStorage: NSTextContentStorage, textParagraphWith range: NSRange) -> NSTextParagraph? {
        guard let document = documents[ObjectIdentifier(textContentStorage)]?.document, let storage = textContentStorage.textStorage,
              document.lines.lineCount > 0, range.location <= storage.length else { return nil }
        let line = document.lines.line(at: range.location)
        EditorStyle.shared.refresh()
        let (runs, signature) = document.fontRuns(line: line, dark: Palette.isDark(NSApp.effectiveAppearance))
        document.laidOut(line: line, signature: signature)
        guard !runs.isEmpty else { return nil }
        let text = NSMutableAttributedString(attributedString: storage.attributedSubstring(from: range))
        let start = document.lines.starts[line] - range.location
        for run in runs {
            let lower = start + run.range.lowerBound, upper = min(start + run.range.upperBound, range.length)
            guard lower >= 0, upper > lower else { continue }
            let font = text.attribute(.font, at: lower, effectiveRange: nil) as? NSFont ?? EditorStyle.shared.font
            text.addAttribute(.font, value: EditorStyle.shared.font(font, run.style), range: NSRange(location: lower, length: upper - lower))
        }
        return NSTextParagraph(attributedString: text)
    }
}
