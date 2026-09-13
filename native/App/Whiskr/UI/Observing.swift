import Foundation
import Observation
import SwiftUI

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

/// A SwiftUI view that is there only while shown. A hidden hosting view's content is still worked out
/// again whenever something it reads changes; this keeps it out of the way until it is shown.
struct WhileShown<Content: View>: View {
    var shown: Bool
    @ViewBuilder let content: () -> Content

    var body: some View {
        // Hidden, a stand-in that takes any size, so the hosting view's own size limits stay as they were.
        if shown { content() } else { Color.clear }
    }
}
