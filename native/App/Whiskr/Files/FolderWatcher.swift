import CoreServices
import Foundation

/// Tells, a moment after the fact, which paths changed under a folder (an FSEvents stream, so a whole
/// repository costs one stream however deep it is). Changes are gathered for 0.15 s and handed over
/// together on the main thread: Claude writing ten files is one update, not ten.
nonisolated final class FolderWatcher {
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "Whiskr files", qos: .utility)
    private let sink: Sink

    /// `onChange` gets the absolute paths that changed (files and folders, standardised).
    init(folder: URL, onChange: @escaping @MainActor ([String]) -> Void) {
        sink = Sink(onChange: onChange)
        // The stream holds the sink until it is released itself: a callback already running on the queue
        // when the watcher goes still finds it.
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passRetained(sink).toOpaque(), retain: nil,
                                           release: { info in info.map { Unmanaged<Sink>.fromOpaque($0).release() } }, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let sink = Unmanaged<Sink>.fromOpaque(info).takeUnretainedValue()
            let names = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            sink.take(Array(names.prefix(count)))
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagWatchRoot)
        guard let stream = FSEventStreamCreate(nil, callback, &context, [folder.path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.15, flags) else {
            Unmanaged.passUnretained(sink).release()
            return
        }
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    deinit {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }

    /// Collects paths on the stream's queue and hands them to the main thread in one go.
    nonisolated private final class Sink: @unchecked Sendable {
        private let onChange: @MainActor ([String]) -> Void
        private var pending: Set<String> = []
        private var scheduled = false
        private let lock = NSLock()

        init(onChange: @escaping @MainActor ([String]) -> Void) {
            self.onChange = onChange
        }

        func take(_ paths: [String]) {
            let schedule = lock.withLock { () -> Bool in
                pending.formUnion(paths)
                guard !scheduled else { return false }
                scheduled = true
                return true
            }
            guard schedule else { return }
            DispatchQueue.main.async { [self] in
                let paths = lock.withLock { () -> [String] in
                    scheduled = false
                    defer { pending.removeAll() }
                    return Array(pending)
                }
                MainActor.assumeIsolated { onChange(paths) }
            }
        }
    }
}
