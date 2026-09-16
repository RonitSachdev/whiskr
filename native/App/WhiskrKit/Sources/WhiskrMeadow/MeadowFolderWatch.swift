import Foundation

/// Tells when the meadows' folder changes on disk (a meadow added, removed or renamed, in the Finder or by a
/// sync tool, or a file replaced whole, as atomic saves replace it) and when one file in it is written in
/// place (`watch(file:)`: the meadow shown). Changes are gathered for a fifth of a second, then `changed` is
/// called once, on the main queue. It says only that something changed; what changed is read from the
/// folder itself, so a change missed (or the app away while it happened) is caught the next time it looks.
public final class MeadowFolderWatch: @unchecked Sendable {
    private let folder: URL
    private let changed: @MainActor @Sendable () -> Void
    private let queue = DispatchQueue(label: "app.whiskr.meadow-folder-watch")
    // Touched only on `queue`.
    private var folderSource: DispatchSourceFileSystemObject?
    private var fileSource: DispatchSourceFileSystemObject?
    private var watchedFile: URL?
    private var pending = false

    /// How long changes are gathered before `changed` is called.
    public static let gathering: TimeInterval = 0.2

    public init(folder: URL, changed: @escaping @MainActor @Sendable () -> Void) {
        self.folder = folder
        self.changed = changed
        queue.async { self.openFolder() }
    }

    deinit {
        folderSource?.cancel()
        fileSource?.cancel()
    }

    /// Also tells when `file` (one in the folder) is written in place; nil watches none. Watched afresh after
    /// each change, since a file replaced whole is a new file.
    public func watch(file: URL?) {
        queue.async {
            self.watchedFile = file
            self.openFile()
        }
    }

    private func openFolder() {
        folderSource?.cancel()
        folderSource = nil
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        folderSource = source(folder, [.write, .delete, .rename, .link])
    }

    private func openFile() {
        fileSource?.cancel()
        fileSource = nil
        guard let watchedFile else { return }
        fileSource = source(watchedFile, [.write, .extend, .delete, .rename, .attrib])
    }

    private func source(_ url: URL, _ events: DispatchSource.FileSystemEvent) -> DispatchSourceFileSystemObject? {
        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: events, queue: queue)
        source.setEventHandler { [weak self] in self?.noticed() }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        return source
    }

    private func noticed() {
        // The folder itself gone (moved away, deleted) is watched again once it is made anew.
        if folderSource?.data.contains(.delete) == true || folderSource?.data.contains(.rename) == true { openFolder() }
        guard !pending else { return }
        pending = true
        queue.asyncAfter(deadline: .now() + Self.gathering) {
            self.pending = false
            self.openFile()
            let changed = self.changed
            DispatchQueue.main.async { MainActor.assumeIsolated { changed() } }
        }
    }
}
