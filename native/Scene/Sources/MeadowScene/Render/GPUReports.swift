import Foundation
import Synchronization

/// What Metal's handlers report from their own threads: GPU time per command buffer and when each
/// drawable reached the display. Collected under a lock with no allocation per frame, read once a second.
final class GPUReports: Sendable {
    private struct State {
        var gpuSum = 0.0
        var gpuFrames = 0
        var lastPresent = 0.0
        var intervals = [Double](repeating: 0, count: 512)
        var count = 0
    }
    private let state = Mutex(State())

    func gpu(_ ms: Double) {
        guard ms > 0 else { return }
        state.withLock { $0.gpuSum += ms; $0.gpuFrames += 1 }
    }

    func presented(_ at: CFTimeInterval) {
        guard at > 0 else { return }
        state.withLock { s in
            if s.lastPresent > 0, s.count < s.intervals.count { s.intervals[s.count] = at - s.lastPresent; s.count += 1 }
            s.lastPresent = at
        }
    }

    /// Everything since the last call, and starts afresh.
    func take() -> (gpuSum: Double, gpuFrames: Int, intervals: ArraySlice<Double>) {
        state.withLock { s in
            let out = (s.gpuSum, s.gpuFrames, s.intervals[0..<s.count])
            s.gpuSum = 0; s.gpuFrames = 0; s.count = 0
            return out
        }
    }
}
