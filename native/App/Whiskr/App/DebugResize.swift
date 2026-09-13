#if DEBUG
import AppKit
import SwiftTerm
import WhiskrKit

/// Debug builds only: a divider drag over a terminal with a long scrollback, as the split view's tracking
/// loop runs it, and what the main thread and the program in the terminal see of it. Run from
/// `DebugScenario.run`.
///
///   --resize-drag-after <s>   fills the focused pane with 12,000 lines (and a SIGWINCH trap that prints
///                             each size the shell is told), then drags the meadow's divider 40 steps
///                             as a live resize, ends the drag, and prints how long the main thread was
///                             held at the end and how many frames in the second after took over 16 ms
@MainActor
enum DebugResize {
    static func run(workbench: Workbench, window controller: MainWindowController) {
        guard let delay = DebugScenario.value("--resize-drag-after").flatMap(Double.init) else { return }
        workbench.focusedPane?.type("trap 'echo winch-$(tput cols)x$(tput lines)' WINCH; clear; seq 1 12000\r")
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            Task { await drag(workbench: workbench, controller: controller) }
        }
    }

    private static func drag(workbench: Workbench, controller: MainWindowController) async {
        guard let window = controller.window else { return }
        for round in 0..<5 {
            var width = 420.0 + Double(round % 2) * 60
            LiveResize.shared.begin()
            for _ in 0..<40 {
                width += round % 2 == 0 ? 3 : -3
                controller.debugSetLayout { $0.dragDivider(to: width, window: Double(window.frame.width)) }
                window.contentView?.superview?.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                try? await Task.sleep(for: .milliseconds(16))
            }
            // The mouse goes up: the one resize, and the frames after it.
            let watch = FrameWatch()
            let start = DispatchTime.now()
            LiveResize.shared.end()
            window.contentView?.superview?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            let call = milliseconds(since: start)
            let (worst, long) = await watch.finish(after: 1000)
            print(String(format: "resize-drag round %d: end call %.2f ms, longest main-thread hold %.2f ms, frames over 16 ms %d, columns %d",
                         round, call, max(call, worst), long, workbench.focusedPane?.surface.terminalDimensions.cols ?? 0))
            fflush(stdout)
        }
    }

    /// The gaps between turns of the main run loop while it runs: the longest, and how many missed a frame.
    @MainActor
    private final class FrameWatch {
        private var last = DispatchTime.now()
        private var worst = 0.0
        private var long = 0
        private var timer: Timer?

        init() {
            let timer = Timer(timeInterval: 0.001, repeats: true) { _ in
                MainActor.assumeIsolated { [weak self] in self?.tick() }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }

        private func tick() {
            let now = DispatchTime.now()
            let gap = Double(now.uptimeNanoseconds - last.uptimeNanoseconds) / 1e6
            worst = max(worst, gap)
            if gap > 16 { long += 1 }
            last = now
        }

        func finish(after delay: Int) async -> (Double, Int) {
            try? await Task.sleep(for: .milliseconds(delay))
            timer?.invalidate()
            return (worst, long)
        }
    }

    nonisolated private static func milliseconds(since start: DispatchTime) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e6
    }
}
#endif
