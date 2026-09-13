import CoreServices
import Foundation
import WhiskrKit

/// How each workspace's branch stands against its upstream (commits to push and to pull) and whether
/// files have changed, for the blanket's flag: `git status` run off the main thread, and run again a
/// moment after anything in the checkout changes on disk (FSEvents, so it costs nothing while all is
/// still). One run at a time per checkout; a burst of changes (a build, a checkout) is one run.
final class BranchWatcher {
    /// Called on the main thread with a workspace's branch state whenever it changes (nil outside a repository).
    var onChange: ((UUID, SceneSnapshot.BranchChanges?) -> Void)?

    private final class Watch {
        let root: String
        var stream: FSEventStreamRef?
        var running = false
        var again = false
        init(root: String) { self.root = root }
    }

    private var watches: [UUID: Watch] = [:]
    private let queue = DispatchQueue(label: "Whiskr branch status", qos: .utility)
    /// How long to let a burst of file changes settle before asking git again.
    static let settle: TimeInterval = 1.5

    /// Follows the checkout at `root` for workspace `id` (nothing to do when it already does; nil stops).
    func follow(_ id: UUID, root: String?) {
        guard watches[id]?.root != root else { return }
        stop(id)
        guard let root else {
            onChange?(id, nil)
            return
        }
        let watch = Watch(root: root)
        watches[id] = watch
        watch.stream = stream(for: id, root: root)
        refresh(id)
    }

    func stop(_ id: UUID) {
        guard let watch = watches.removeValue(forKey: id), let stream = watch.stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }

    /// Asks git, unless it is being asked already (then once more when that answer is in).
    private func refresh(_ id: UUID) {
        guard let watch = watches[id] else { return }
        guard !watch.running else {
            watch.again = true
            return
        }
        watch.running = true
        let root = watch.root
        queue.async { [weak self] in
            let status = try? GitRunner().status(in: root)
            let changes = status.map { SceneSnapshot.BranchChanges(ahead: $0.ahead, behind: $0.behind, dirty: $0.changeCount > 0) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, let watch = self.watches[id], watch.root == root else { return }
                    watch.running = false
                    self.onChange?(id, changes)
                    if watch.again {
                        watch.again = false
                        self.refresh(id)
                    }
                }
            }
        }
    }

    private func stream(for id: UUID, root: String) -> FSEventStreamRef? {
        let box = Unmanaged.passRetained(Changed { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.refresh(id) } }
        })
        var context = FSEventStreamContext(version: 0, info: box.toOpaque(), retain: nil, release: releaseChanged, copyDescription: nil)
        guard let stream = FSEventStreamCreate(nil, streamChanged, &context, [root] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                                               Self.settle, FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer)) else { return nil }
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        return stream
    }
}

/// The callback an event stream holds on to. FSEvents calls into it on the watcher's queue, never the
/// main thread, so none of this is the main actor's.
private nonisolated final class Changed: @unchecked Sendable {
    let call: @Sendable () -> Void
    init(_ call: @escaping @Sendable () -> Void) { self.call = call }
}

private nonisolated func streamChanged(_ stream: ConstFSEventStreamRef, _ info: UnsafeMutableRawPointer?, _ count: Int,
                                       _ paths: UnsafeMutableRawPointer, _ flags: UnsafePointer<FSEventStreamEventFlags>,
                                       _ ids: UnsafePointer<FSEventStreamEventId>) {
    guard let info else { return }
    Unmanaged<Changed>.fromOpaque(info).takeUnretainedValue().call()
}

private nonisolated func releaseChanged(_ info: UnsafeRawPointer?) {
    guard let info else { return }
    Unmanaged<Changed>.fromOpaque(info).release()
}
