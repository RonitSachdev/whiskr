import AppKit
import Darwin
@_spi(Diagnostics) import MeadowScene

// `--measure N --out report.json`: N seconds of frames drawn offscreen at the window's pixel size (no
// window is ever shown), after a two-second warm-up, with an orbit, slide or zoom played in throughout if
// `--interact` asks. Reports main-thread time per frame (and its parts), GPU time per frame, process CPU
// and memory. What only a window on screen can show (frames presented on glass, hitches, the feel of real
// input) is not measured here.

@MainActor
enum Measure {
    static func run(view: MeadowView, pixels: CGSize, seconds: Double, out: String?, interact: String?) {
        let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical], reason: "measuring frame times")
        defer { ProcessInfo.processInfo.endActivity(activity) }
        let w = Int(pixels.width), h = Int(pixels.height)
        let step = 1.0 / 120
        var phase = 0.0
        func frame() -> (cpu: Double, pose: Double, update: Double, gpu: Double) {
            phase += step
            switch interact {
            case "zoom": view.simulateZoom(by: Float(sin(phase * 1.3) > 0 ? 0.985 : 1.015), at: CGPoint(x: pixels.width * 0.2, y: pixels.height * 0.27))
            case "orbit", "pan": view.simulateDrag(dx: Float(3 * cos(phase * 0.8)), dy: Float(0.6 * sin(phase * 1.7)), slide: interact == "pan")
            default: break
            }
            return view.timeOffscreenFrame(width: w, height: h, dt: step)
        }
        let warm = CACurrentMediaTime()
        while CACurrentMediaTime() - warm < 2 { _ = frame() }
        var cpu: [Double] = [], gpu: [Double] = [], pose: [Double] = [], update: [Double] = []
        let cpu0 = processCPU(), t0 = CACurrentMediaTime()
        while CACurrentMediaTime() - t0 < seconds {
            let f = frame()
            cpu.append(f.cpu); gpu.append(f.gpu); pose.append(f.pose); update.append(f.update)
        }
        let wall = CACurrentMediaTime() - t0
        func stats(_ v: [Double]) -> [String: Double] {
            guard !v.isEmpty else { return [:] }
            let s = v.sorted()
            return ["avg": v.reduce(0, +) / Double(v.count), "p95": s[min(s.count - 1, Int(Double(s.count) * 0.95))], "max": s.last!]
        }
        let report: [String: Any] = [
            "pixels": "\(w)x\(h)", "seconds": wall, "interact": interact ?? "none", "frames": cpu.count,
            "cpu_ms": stats(cpu), "cpu_update_ms": stats(update), "cpu_pose_ms": stats(pose), "gpu_ms": stats(gpu),
            // Frames are drawn back to back here, so this is CPU per drawn frame, not per second at 120 Hz.
            "process_cpu_ms_per_frame": (processCPU() - cpu0) * 1000 / Double(max(cpu.count, 1)),
            "memory_mb": footprintMB(), "low_power_mode": ProcessInfo.processInfo.isLowPowerModeEnabled, "load_average_1min": loadAverage(),
        ]
        let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        if let out, let data { try? data.write(to: URL(fileURLWithPath: out)) }
        if let data, let text = String(data: data, encoding: .utf8) { print(text) }
    }

    static func loadAverage() -> Double {
        var l = [Double](repeating: 0, count: 3)
        return getloadavg(&l, 3) > 0 ? l[0] : 0
    }

    static func processCPU() -> Double {
        var u = rusage()
        getrusage(RUSAGE_SELF, &u)
        return Double(u.ru_utime.tv_sec) + Double(u.ru_utime.tv_usec) / 1e6 + Double(u.ru_stime.tv_sec) + Double(u.ru_stime.tv_usec) / 1e6
    }

    static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
    }
}
