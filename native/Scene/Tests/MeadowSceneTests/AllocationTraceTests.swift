import AppKit
import Darwin
import Foundation
import Testing
@_spi(Diagnostics) @testable import MeadowScene

// Diagnostic, only when MEADOW_TRACE_ALLOCATIONS is set: where the scene's per-frame allocations come from.
nonisolated(unsafe) private var traces = UnsafeMutablePointer<UnsafeMutableRawPointer?>.allocate(capacity: 64 * 24)
nonisolated(unsafe) private var traced = 0
nonisolated(unsafe) private var inside = false

@MainActor
@Test(.enabled(if: ProcessInfo.processInfo.environment["MEADOW_TRACE_ALLOCATIONS"] != nil))
func traceAllocations() {
    let view = MeadowView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
    view.settings = MeadowSettings(timeOfDay: .night)
    view.world = Scenes.busy()
    view.frame(nil, besidePanelWidth: 0, animated: false)
    view.advance(seconds: 3)
    for _ in 0..<30 { _ = view.timeOffscreenFrame(width: 1280, height: 800, dt: 1.0 / 120) }
    let full = ProcessInfo.processInfo.environment["MEADOW_TRACE_ALLOCATIONS"] == "frame"
    typealias Logger = @convention(c) (UInt32, UInt, UInt, UInt, UInt, UInt32) -> Void
    let logger = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "malloc_logger")!.assumingMemoryBound(to: Logger?.self)
    traced = 0
    logger.pointee = { type, _, _, _, _, _ in
        guard type & 2 != 0, !inside, traced < 64 else { return }
        inside = true
        _ = backtrace(traces + traced * 24, 24)
        traced += 1
        inside = false
    }
    for _ in 0..<(full ? 3 : 480) {
        if full { _ = view.timeOffscreenFrame(width: 1280, height: 800, dt: 1.0 / 120) } else { view.stage.update(1.0 / 120) }
    }
    logger.pointee = nil
    var seen: [String: Int] = [:]
    for t in 0..<traced {
        guard let symbols = backtrace_symbols(traces + t * 24, 24) else { continue }
        var frames: [String] = []
        for k in 1..<24 {
            guard let c = symbols[k] else { continue }
            let line = String(cString: c)
            let name = line.split(separator: " ").dropFirst(3).prefix(1).joined()
            if name.contains("malloc") || name.contains("backtrace") || name.hasPrefix("_ZN5swift") || name == "swift_allocObject" || name.contains("closure") && name.contains("traceAllocations") { continue }
            frames.append(name)
            if frames.count >= 4 { break }
        }
        free(symbols)
        seen[frames.joined(separator: " < "), default: 0] += 1
    }
    for (k, v) in seen.sorted(by: { $0.value > $1.value }) { print("ALLOC \(v)× \(k)") }
}
