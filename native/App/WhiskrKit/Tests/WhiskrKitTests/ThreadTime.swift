import Foundation

/// The processor time the calling thread spends running `body`. Speed tests compare this, not the time on
/// the clock: what a piece of work costs stays the same while other builds and the tests running beside
/// it load the Mac, and wall time under that load measures the scheduler instead.
func threadTime(_ body: () -> Void) -> Duration {
    func now() -> Duration {
        var time = timespec()
        clock_gettime(CLOCK_THREAD_CPUTIME_ID, &time)
        return .seconds(time.tv_sec) + .nanoseconds(time.tv_nsec)
    }
    let start = now()
    body()
    return now() - start
}
