import Foundation
import WhiskrKit

/// Each workspace's repository and branch (docs/DESIGN.md): found and read off the main thread
/// from the repository's own files (no `git` process), and read again whenever its `HEAD` changes, which
/// is how a branch switch shows on the blanket's flag and in the status line.
final class GitWatcher {
    /// Called on the main thread with a workspace's repository (nil outside one) whenever it changes.
    var onChange: ((UUID, GitHead?) -> Void)?

    private struct Watch {
        let folder: String
        var source: DispatchSourceFileSystemObject?
    }

    private var watches: [UUID: Watch] = [:]
    private let queue = DispatchQueue(label: "Whiskr git", qos: .utility)

    /// Follows the repository `folder` is in for workspace `id` (nothing to do when it already does).
    func follow(_ id: UUID, folder: String) {
        guard watches[id]?.folder != folder else { return }
        stop(id)
        watches[id] = Watch(folder: folder)
        read(id, folder: folder)
    }

    func stop(_ id: UUID) {
        watches[id]?.source?.cancel()
        watches[id] = nil
    }

    private func read(_ id: UUID, folder: String) {
        queue.async { [weak self] in
            let head = GitHead.find(from: folder)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.watches[id]?.folder == folder else { return }
                    self.onChange?(id, head)
                    self.watchHead(id, folder: folder, file: head?.headFile)
                }
            }
        }
    }

    /// Git replaces `HEAD` rather than writing into it, so the watch ends with the old file and starts
    /// again on the new one after each read.
    private func watchHead(_ id: UUID, folder: String, file: String?) {
        watches[id]?.source?.cancel()
        watches[id]?.source = nil
        guard let file else { return }
        let descriptor = open(file, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .rename, .delete], queue: queue)
        // Both handlers run on the watch's queue, so they must not be the main actor's (Swift 6 traps when
        // a main-actor closure runs elsewhere): they only hand over to the main thread, or close the file.
        let target = WeakWatcher(self)
        source.setEventHandler { @Sendable in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { target.watcher?.read(id, folder: folder) }
            }
        }
        source.setCancelHandler { @Sendable in close(descriptor) }
        source.resume()
        watches[id]?.source = source
    }
}

/// The watcher, held weakly, as the watch's handlers may hold it from another thread.
nonisolated private final class WeakWatcher: @unchecked Sendable {
    weak var watcher: GitWatcher?
    init(_ watcher: GitWatcher) { self.watcher = watcher }
}
