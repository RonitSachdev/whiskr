import Foundation
import MeadowFile

/// The folder of a person's meadows (`…/Whiskr/Meadows`, inside an isolated run's own folder when
/// testing): one `.whiskrmeadow` file each, named after the meadow, sanitised for the file system and made
/// unique with " 2", " 3"…. Writing is atomic (a temporary file, then a rename), so a meadow on disk is
/// always whole: the one before a save, or the one after. Nothing here ever replaces a meadow but the one
/// it was asked to write: a new, imported, copied or renamed meadow takes a name no other has.
public struct MeadowLibraryFolder: Sendable {
    public let url: URL

    public init(_ url: URL) {
        self.url = url
    }

    /// The meadows' file names, in name order (as the Finder sorts them).
    public func fileNames() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
        return names.filter(Self.isPlain).sorted(by: Self.inNameOrder)
    }

    /// Meadows' files in the order of their names, as the Finder sorts them ("Orchard", "Orchard 2", "Orchard 10"):
    /// by the name, not the file's name, whose extension would put "Orchard 2" first.
    public static func inNameOrder(_ a: String, _ b: String) -> Bool {
        name(of: a).localizedStandardCompare(name(of: b)) == .orderedAscending
    }

    /// A file name for a new meadow called `name`: what the file system takes (no "/" or ":", no leading
    /// dot, at most 60 characters), `untitled` when nothing is left, and " 2", " 3"… after it when a
    /// meadow of that name is here already (`excluding` one file: a meadow renamed keeps its own name free).
    public func fileName(forNew name: String, untitled: String = "Untitled Meadow", excluding: String? = nil) -> String {
        var base = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasPrefix(".") { base.removeFirst() }
        base = String(base.prefix(60)).trimmingCharacters(in: .whitespacesAndNewlines)
        if base.isEmpty { base = untitled }
        let taken = Set(fileNames().filter { $0 != excluding }.map { $0.lowercased() })
        var candidate = base, n = 1
        while taken.contains("\(candidate).\(MeadowFormat.fileExtension)".lowercased()) {
            n += 1
            candidate = "\(base) \(n)"
        }
        return "\(candidate).\(MeadowFormat.fileExtension)"
    }

    /// Whether `fileName` names a meadow file directly in the folder (never a path elsewhere).
    public static func isPlain(_ fileName: String) -> Bool {
        !fileName.isEmpty && !fileName.contains("/") && !fileName.hasPrefix(".") && fileName.hasSuffix("." + MeadowFormat.fileExtension)
    }

    /// A meadow's name as its file's name says it (without the extension).
    public static func name(of fileName: String) -> String {
        (fileName as NSString).deletingPathExtension
    }

    public func fileURL(_ fileName: String) -> URL { url.appendingPathComponent(fileName, isDirectory: false) }

    /// The meadow in `fileName`, read with every check a file from anyone gets.
    public func read(_ fileName: String, catalog: MeadowCatalog = .current) throws -> MeadowReading {
        try MeadowDocument.read(try data(fileName), catalog: catalog)
    }

    /// The bytes of `fileName` (`Self.data(at:)`'s checks).
    public func data(_ fileName: String) throws -> Data {
        guard Self.isPlain(fileName) else { throw CocoaError(.fileReadInvalidFileName) }
        return try Self.data(at: fileURL(fileName))
    }

    /// The bytes of a meadow file anywhere (one being imported, from anyone), read only once it is known to be
    /// an ordinary file no larger than a meadow may be, and never more than that much of it: a link to a
    /// device, a pipe or a file that grows as it is read never holds the reader.
    public static func data(at file: URL) throws -> Data {
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else { throw CocoaError(.fileReadUnknown) }
        let size = values.fileSize ?? 0
        guard size <= MeadowFormat.maxBytes else { throw MeadowFileError.tooLarge(bytes: size) }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: MeadowFormat.maxBytes + 1) ?? Data()
        guard data.count <= MeadowFormat.maxBytes else { throw MeadowFileError.tooLarge(bytes: data.count) }
        return data
    }

    /// Writes `data` as `fileName`, whole: into a temporary file beside it, then renamed over it.
    public func write(_ data: Data, as fileName: String) throws {
        guard Self.isPlain(fileName) else { throw CocoaError(.fileWriteInvalidFileName) }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try data.write(to: fileURL(fileName), options: .atomic)
    }

    /// Takes `fileName` away (it was made by an edit that is being undone).
    public func remove(_ fileName: String) throws {
        guard Self.isPlain(fileName) else { throw CocoaError(.fileWriteInvalidFileName) }
        try FileManager.default.removeItem(at: fileURL(fileName))
    }

    // MARK: Meadows made, copied, renamed and added

    /// A new meadow called `name` holding `document` (the Default or the empty meadow, as each starts), written
    /// by Whiskr `writtenBy`; its file's name.
    public func add(_ document: MeadowDocument, named name: String, writtenBy: String) throws -> String {
        let file = fileName(forNew: name)
        var named = document
        named.name = Self.name(of: file)
        try write(try named.fileData(writtenBy: writtenBy), as: file)
        return file
    }

    /// A copy of `fileName` beside it under the next free name of its family ("Orchard Study" and "Orchard Study 2"
    /// both copy to "Orchard Study 3" when that is the next), the same meadow (what it keeps from a newer Whiskr
    /// kept too); its file's name.
    public func duplicate(_ fileName: String, writtenBy: String) throws -> String {
        let reading = try read(fileName)
        return try add(reading.document, named: Self.family(of: Self.name(of: fileName)), writtenBy: writtenBy)
    }

    /// A name without the " 2", " 3"… that made it unique.
    static func family(of name: String) -> String {
        guard let range = name.range(of: #"\S \d+$"#, options: .regularExpression) else { return name }
        return String(name[..<name.index(after: range.lowerBound)])
    }

    /// `fileName` renamed `name` (sanitised as a meadow's name is, " 2" after it when another meadow has it):
    /// its file takes the name and the meadow inside says it. The new file is written whole before the old one
    /// goes, so a meadow is never lost half renamed. Its new file's name (the same when nothing changed).
    public func rename(_ fileName: String, to name: String, writtenBy: String) throws -> String {
        let clean = MeadowText.sanitised(name)
        guard !clean.isEmpty, MeadowText.fits(clean, .name) else { throw MeadowFileError.textTooLong(.name) }
        let file = self.fileName(forNew: clean, excluding: fileName)
        guard file != fileName else { return fileName }
        var document = try read(fileName).document
        document.name = Self.name(of: file)
        let data = try document.fileData(writtenBy: writtenBy)
        if file.lowercased() == fileName.lowercased() {
            // Only the letters' case changes: the file system holds one name for both, so it is moved.
            try write(data, as: fileName)
            try FileManager.default.moveItem(at: fileURL(fileName), to: fileURL(file))
        } else {
            try write(data, as: file)
            try remove(fileName)
        }
        return file
    }

    /// A meadow file from anyone (already read and checked: `reading`), added as it came, byte for byte, under
    /// a name of its own: the name it gives itself (or `fallback`, the name of the file it came in), " 2" after it
    /// when a meadow here has it. Never replaces a meadow. Its file's name.
    public func addImported(_ data: Data, _ reading: MeadowReading, fallback: String) throws -> String {
        let file = importedFileName(reading, fallback: fallback)
        try write(data, as: file)
        return file
    }

    /// The name an imported meadow will take here (`addImported`).
    public func importedFileName(_ reading: MeadowReading, fallback: String) -> String {
        let named = reading.document.name.isEmpty ? MeadowText.sanitised(fallback) : reading.document.name
        return fileName(forNew: String(named.prefix(MeadowText.Field.name.limit)))
    }

    // MARK: Changes on disk

    /// What a meadow file is on disk now, cheaply (no reading): its size and when it last changed. A picture of
    /// a meadow is kept for as long as its file's stamp holds.
    public struct Stamp: Equatable, Hashable, Sendable {
        public var size: Int
        public var modified: Date
    }

    public func stamp(_ fileName: String) -> Stamp? {
        guard Self.isPlain(fileName), let values = try? fileURL(fileName).resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              let modified = values.contentModificationDate else { return nil }
        return Stamp(size: values.fileSize ?? 0, modified: modified)
    }

    /// What a meadow's bytes are, as one number (64-bit FNV-1a): the app keeps the digest of what it last read or
    /// wrote, and a file whose bytes on disk have another was changed by something else.
    public static func digest(_ data: Data) -> UInt64 {
        data.reduce(UInt64(14_695_981_039_346_656_037)) { ($0 ^ UInt64($1)) &* 1_099_511_628_211 }
    }

    /// The digest of `fileName`'s bytes on disk now; nil when it is gone or cannot be read.
    public func digest(_ fileName: String) -> UInt64? {
        (try? data(fileName)).map(Self.digest)
    }
}

/// What to do when the meadow shown is found changed on disk by something else (a sync tool, the Finder,
/// another Mac): `MeadowLibrary` asks this each time the folder or the file changes.
///
/// - Its bytes are what was last read or written: nothing (the app's own save, a touch).
/// - Changed, while it is not being edited: read again and shown (nothing of yours is unsaved: every change
///   is written within a second, and at once when editing ends).
/// - Changed while it is being edited: the person chooses, and neither side is lost (Reload shows the disk's,
///   keeping yours as a meadow of its own; Keep Mine writes yours, keeping the disk's as a meadow of its own).
/// - Gone while it is not being edited: the Default is shown; gone while it is being edited: the person
///   chooses (Save Again writes yours back; Close It shows the Default).
public enum MeadowDiskChange: Equatable, Sendable {
    case nothing
    case reload
    case ask
    case gone
    case askGone

    public static func judge(known: UInt64?, onDisk: UInt64?, editing: Bool) -> MeadowDiskChange {
        guard let onDisk else { return known == nil ? .nothing : editing ? .askGone : .gone }
        guard onDisk != known else { return .nothing }
        return editing ? .ask : .reload
    }
}
