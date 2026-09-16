import Foundation
import MeadowFile

/// The folder of a person's meadows (`…/Whiskr/Meadows`, inside an isolated run's own folder when
/// testing): one `.whiskrmeadow` file each, named after the meadow, sanitised for the file system and made
/// unique with " 2", " 3"…. Writing is atomic (a temporary file, then a rename), so a meadow on disk is
/// always whole: the one before a save, or the one after.
public struct MeadowLibraryFolder: Sendable {
    public let url: URL

    public init(_ url: URL) {
        self.url = url
    }

    /// The meadows' file names, in name order (as the Finder sorts them).
    public func fileNames() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
        return names.filter { $0.hasSuffix("." + MeadowFormat.fileExtension) && !$0.hasPrefix(".") }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// A file name for a new meadow called `name`: what the file system takes (no "/" or ":", no leading
    /// dot, at most 60 characters), "Untitled Meadow" when nothing is left, and " 2", " 3"… after it when a
    /// meadow of that name is here already.
    public func fileName(forNew name: String, untitled: String = "Untitled Meadow") -> String {
        var base = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasPrefix(".") { base.removeFirst() }
        base = String(base.prefix(60)).trimmingCharacters(in: .whitespacesAndNewlines)
        if base.isEmpty { base = untitled }
        let taken = Set(fileNames().map { $0.lowercased() })
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

    public func fileURL(_ fileName: String) -> URL { url.appendingPathComponent(fileName, isDirectory: false) }

    /// The meadow in `fileName`, read with every check a file from anyone gets.
    public func read(_ fileName: String, catalog: MeadowCatalog = .current) throws -> MeadowReading {
        guard Self.isPlain(fileName) else { throw CocoaError(.fileReadInvalidFileName) }
        let file = fileURL(fileName)
        let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
        guard size <= MeadowFormat.maxBytes else { throw MeadowFileError.tooLarge(bytes: size) }
        return try MeadowDocument.read(try Data(contentsOf: file), catalog: catalog)
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
}
