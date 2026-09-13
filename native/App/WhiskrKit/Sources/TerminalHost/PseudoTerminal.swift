import Darwin
import Foundation
import WhiskrKit

/// A program started on a pseudo-terminal of its own: the host keeps the controlling end, the program
/// gets the other as its controlling terminal and leads a new session there, so everything it starts
/// belongs to that terminal and a hang-up reaches all of it.
struct PseudoTerminal {
    /// The host's end, non-blocking.
    let descriptor: Int32
    let pid: pid_t

    /// Starts `spec`. The program inherits nothing of the host's but its three standard streams (the
    /// terminal): every other descriptor is closed for it, signals are back at their defaults.
    ///
    /// Done with `forkpty`, as terminals do: only that makes the pseudo-terminal the new session's
    /// controlling terminal, without which a shell has no job control and the host could not tell what
    /// runs in front. Everything the child needs is prepared before the fork; between fork and exec it
    /// makes system calls only.
    static func start(_ spec: TerminalSpec) throws(HostFailure) -> PseudoTerminal {
        guard access(spec.executable, X_OK) == 0 else {
            throw HostFailure(.launchFailed, "\(spec.executable): \(String(cString: strerror(errno)))")
        }
        let arguments = cStrings([spec.argv0] + spec.arguments)
        let environment = cStrings(spec.environment.map { "\($0.key)=\($0.value)" }.sorted())
        let executable = strdup(spec.executable)
        var isFolder: ObjCBool = false
        let directory = FileManager.default.fileExists(atPath: spec.directory, isDirectory: &isFolder) && isFolder.boolValue ? strdup(spec.directory) : nil
        defer {
            arguments.forEach { free($0) }
            environment.forEach { free($0) }
            free(executable)
            free(directory)
        }
        var defaultAction = sigaction()
        defaultAction.__sigaction_u.__sa_handler = SIG_DFL
        sigemptyset(&defaultAction.sa_mask)
        var unblocked = sigset_t()
        sigemptyset(&unblocked)
        let descriptorLimit = min(getdtablesize(), 65_536)
        // Erasing a character erases all of its bytes, as in Terminal.
        var settings = termios()
        cfmakesane(&settings)
        settings.c_iflag |= tcflag_t(IUTF8)
        var size = windowSize(spec.size)
        var controller: Int32 = -1

        let pid = forkpty(&controller, nil, &settings, &size)
        if pid == 0 {
            var number: Int32 = 1
            while number < NSIG {
                if number != SIGKILL && number != SIGSTOP { _ = sigaction(number, &defaultAction, nil) }
                number += 1
            }
            _ = sigprocmask(SIG_SETMASK, &unblocked, nil)
            var descriptor: Int32 = 3
            while descriptor < descriptorLimit {
                _ = close(descriptor)
                descriptor += 1
            }
            if let directory { _ = chdir(directory) }
            _ = execve(executable, arguments, environment)
            _exit(127)
        }
        guard pid > 0 else { throw failure("forkpty") }
        _ = fcntl(controller, F_SETFD, FD_CLOEXEC)
        _ = fcntl(controller, F_SETFL, O_NONBLOCK)
        return PseudoTerminal(descriptor: controller, pid: pid)
    }

    /// The terminal settings a new terminal starts with (the system's sane defaults).
    private static func cfmakesane(_ settings: inout termios) {
        settings.c_iflag = tcflag_t(ICRNL | IXON | IXANY | IMAXBEL | BRKINT)
        settings.c_oflag = tcflag_t(OPOST | ONLCR)
        settings.c_cflag = tcflag_t(CREAD | CS8 | HUPCL)
        settings.c_lflag = tcflag_t(ICANON | ISIG | IEXTEN | ECHO | ECHOE | ECHOK | ECHOKE | ECHOCTL)
        withUnsafeMutableBytes(of: &settings.c_cc) { characters in
            let defaults: [(Int32, UInt8)] = [(VEOF, 4), (VEOL, 0xFF), (VEOL2, 0xFF), (VERASE, 0x7F), (VWERASE, 23), (VKILL, 21), (VREPRINT, 18),
                                             (VINTR, 3), (VQUIT, 28), (VSUSP, 26), (VDSUSP, 25), (VSTART, 17), (VSTOP, 19), (VLNEXT, 22),
                                             (VDISCARD, 15), (VMIN, 1), (VTIME, 0), (VSTATUS, 20)]
            for (index, value) in defaults { characters[Int(index)] = value }
        }
        cfsetispeed(&settings, speed_t(B38400))
        cfsetospeed(&settings, speed_t(B38400))
    }

    /// Tells the terminal its size; the program in front hears of a change (SIGWINCH).
    static func resize(_ descriptor: Int32, to size: TerminalSize) {
        var size = windowSize(size)
        _ = ioctl(descriptor, TIOCSWINSZ, &size)
    }

    private static func windowSize(_ size: TerminalSize) -> winsize {
        func clamp(_ value: Int) -> UInt16 { UInt16(min(max(value, 0), Int(UInt16.max))) }
        return winsize(ws_row: max(clamp(size.rows), 1), ws_col: max(clamp(size.columns), 1), ws_xpixel: clamp(size.pixelWidth), ws_ypixel: clamp(size.pixelHeight))
    }

    private static func failure(_ call: String) -> HostFailure {
        HostFailure(.launchFailed, "\(call): \(String(cString: strerror(errno)))")
    }

    private static func cStrings(_ strings: [String]) -> [UnsafeMutablePointer<CChar>?] {
        strings.map { strdup($0) } + [nil]
    }
}
