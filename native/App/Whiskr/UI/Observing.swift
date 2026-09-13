import Foundation
import Observation

/// Runs `body` now and again whenever an observable value it read changes, for AppKit views that
/// mirror the model. Stops when the returned token is released.
final class Observing {
    private var active = true

    init(_ body: @escaping @MainActor @Sendable () -> Void) {
        track(body)
    }

    deinit {
        active = false
    }

    func cancel() { active = false }

    private func track(_ body: @escaping @MainActor @Sendable () -> Void) {
        guard active else { return }
        withObservationTracking(body) { [weak self] in
            Task { @MainActor in self?.track(body) }
        }
    }
}
