#if DEBUG
import AppKit
import MeadowScene
import WhiskrKit

/// Debug builds only: opens and closes things over and over, for checking that closing lets everything
/// go (run `leaks` or `heap` on the process once it prints "churn: done"). Run from `DebugScenario.run`.
///
///   --churn <n> [--churn-file <path>]   n rounds of: a workspace with two tabs and a split (and the file,
///                                       in a tab and beside a terminal), Home, then all closed;
///                                       done once the closed terminals' ten-second undo has run out
///   --measure-meadow-after <s>          prints what a frame of the meadow costs the main thread
@MainActor
enum DebugChurn {
    static func run(workbench: Workbench, window: MainWindowController) {
        if let delay = DebugScenario.value("--measure-meadow-after").flatMap(Double.init) {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { measureMeadow(window.navigator.meadow) }
        }
        churn(workbench: workbench)
    }

    /// `--measure-meadow-after <s>`: what one frame of the meadow costs the main thread (the scene's step
    /// and the encoding of its drawing, not the GPU's wait), so a visible window's idle cost can be told
    /// from a run whose window is behind others and draws nothing: the cost of 120 frames at the view's size.
    private static func measureMeadow(_ meadow: MeadowView) {
        func threadSeconds() -> Double {
            var time = timespec()
            clock_gettime(CLOCK_THREAD_CPUTIME_ID, &time)
            return Double(time.tv_sec) + Double(time.tv_nsec) / 1e9
        }
        let scale = meadow.window?.backingScaleFactor ?? 2
        let width = Int(meadow.bounds.width * scale), height = Int(meadow.bounds.height * scale)
        _ = meadow.renderImage(width: width, height: height)
        let frames = 120
        let start = threadSeconds()
        for _ in 0..<frames {
            meadow.advance(seconds: 1.0 / 30)
            _ = meadow.renderImage(width: width, height: height)
        }
        let perFrame = (threadSeconds() - start) / Double(frames) * 1000
        let stepStart = threadSeconds()
        for _ in 0..<frames { meadow.advance(seconds: 1.0 / 30) }
        let perStep = (threadSeconds() - stepStart) / Double(frames) * 1000
        print(String(format: "meadow: a frame at %dx%d costs the main thread %.2f ms with an offscreen draw and readback, %.2f ms of it the scene's step; at 30 Hz the step alone is %.1f%% of a core",
                     width, height, perFrame, perStep, perStep * 30 / 10))
        fflush(stdout)
    }

    private static func churn(workbench: Workbench) {
        guard let rounds = DebugScenario.value("--churn").flatMap(Int.init) else { return }
        let file = DebugScenario.value("--churn-file")
        let folder = file.map { ($0 as NSString).deletingLastPathComponent } ?? NSHomeDirectory()
        for round in 0..<rounds {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1 + Double(round) * 1.2) {
                _ = workbench.newWorkspace(folder: folder)
                _ = workbench.newTab()
                workbench.split(.horizontal)
                if let file {
                    workbench.open(file: file, mode: .keep)
                    workbench.open(file: file, mode: .beside)
                }
                workbench.goHome()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    if let workspace = workbench.workspaces.last { workbench.close(workspace: workspace) }
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1 + Double(rounds) * 1.2 + 13) {
            print("churn: done, \(workbench.workspaces.count) workspaces, \(workbench.panes.count) panes, \(workbench.pages.count) pages open")
            fflush(stdout)
        }
    }
}
#endif
