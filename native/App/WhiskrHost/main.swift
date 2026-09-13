import Darwin
import TerminalHost

// The session host: the small process that owns every terminal, so they keep running when the app
// quits, crashes or is updated. Started by the app on demand (`HostLauncher`); all of it is in the
// `TerminalHost` library, where it is tested.

// A test run's host (only those are started with `--abandoned-after`) that crashes exits with 70 and its
// stack in its log, as the test run's app does: a process that exits is no crash to macOS, so nothing
// appears on the screen of whoever is working at this Mac.
if CommandLine.arguments.contains("--abandoned-after") {
    let size = Int(SIGSTKSZ) * 4
    var stack = stack_t(ss_sp: UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16), ss_size: size, ss_flags: 0)
    sigaltstack(&stack, nil)
    var action = sigaction()
    action.__sigaction_u.__sa_handler = { _ in
        let note: StaticString = "test run's host crashed; its stack:\n"
        write(STDERR_FILENO, note.utf8Start, note.utf8CodeUnitCount)
        withUnsafeTemporaryAllocation(of: UnsafeMutableRawPointer?.self, capacity: 64) { frames in
            backtrace_symbols_fd(frames.baseAddress, backtrace(frames.baseAddress, 64), STDERR_FILENO)
        }
        _exit(70)
    }
    action.sa_flags = SA_ONSTACK
    for crash in [SIGTRAP, SIGILL, SIGABRT, SIGSEGV, SIGBUS, SIGFPE, SIGSYS] {
        sigaction(crash, &action, nil)
    }
}

HostMain.run(arguments: CommandLine.arguments)
