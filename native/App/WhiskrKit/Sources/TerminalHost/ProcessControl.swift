import Darwin
import Foundation

/// What the host needs to know about, and do to, the processes behind a terminal. A terminal's shell
/// leads a session of its own with the pseudo-terminal as its controlling terminal; everything started
/// in that terminal belongs to that session.
enum ProcessControl {
    /// The process group in the terminal's foreground: the shell's own while it waits at its prompt,
    /// a job's (such as `claude`) while one runs.
    static func foregroundGroup(terminalFD fd: Int32) -> pid_t {
        fd >= 0 ? tcgetpgrp(fd) : -1
    }

    /// The short name of a process, e.g. "claude" or "vim".
    static func name(of pid: pid_t) -> String? {
        guard pid > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(MAXCOMLEN) * 2 + 1)
        let length = proc_name(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// The executable's full path.
    static func executablePath(of pid: pid_t) -> String? {
        guard pid > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// A process's argv, read from the kernel (`KERN_PROCARGS2`: argc, the executable path, padding,
    /// then the arguments, each ending in a zero byte). Empty when it cannot be read.
    static func arguments(of pid: pid_t) -> [String] {
        guard pid > 0 else { return [] }
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }
        let argc = buffer.withUnsafeBytes { Int($0.loadUnaligned(as: Int32.self)) }
        var index = MemoryLayout<Int32>.size
        // Past the executable path and the zero bytes after it.
        while index < size, buffer[index] != 0 { index += 1 }
        while index < size, buffer[index] == 0 { index += 1 }
        var arguments: [String] = []
        while index < size, arguments.count < min(argc, 16) {
            let start = index
            while index < size, buffer[index] != 0 { index += 1 }
            arguments.append(String(decoding: buffer[start..<index], as: UTF8.self))
            index += 1
        }
        return arguments
    }

    /// The folder a process is in now, so a new split can start where you are.
    static func currentDirectory(of pid: pid_t) -> String? {
        guard pid > 0 else { return nil }
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: info.pvi_cdir.vip_path) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        return path.isEmpty ? nil : path
    }

    /// Every process still in the session `sid`, including ones whose parent has gone. The system has
    /// no list by session, so your processes are listed and each is asked which session it is in.
    static func sessionMembers(_ sid: pid_t) -> [pid_t] {
        guard sid > 0 else { return [] }
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_UID, Int32(bitPattern: getuid())]
        var size = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return [] }
        // Room for processes started between the two calls.
        size += 64 * MemoryLayout<kinfo_proc>.stride
        var processes = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride)
        guard sysctl(&mib, UInt32(mib.count), &processes, &size, nil, 0) == 0 else { return [] }
        return processes.prefix(size / MemoryLayout<kinfo_proc>.stride).map(\.kp_proc.p_pid).filter { $0 > 0 && getsid($0) == sid }
    }

    /// Asks everything in the terminal to end, as closing a terminal window does: a hang-up to the
    /// job in front and to the shell, which passes it on to its other jobs.
    static func hangUp(shell: pid_t, terminalFD fd: Int32) {
        guard shell > 0 else { return }
        let front = foregroundGroup(terminalFD: fd)
        if front > 0, front != shell { killpg(front, SIGHUP) }
        killpg(shell, SIGHUP)
        kill(shell, SIGCONT)
    }

    /// Ends whatever in the session did not end on the hang-up.
    static func killSession(_ sid: pid_t) {
        for pid in sessionMembers(sid) { kill(pid, SIGKILL) }
    }

    static func isAlive(_ pid: pid_t) -> Bool {
        pid > 0 && (kill(pid, 0) == 0 || errno == EPERM)
    }
}
