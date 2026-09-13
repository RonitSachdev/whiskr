import Darwin
import Foundation
import WhiskrKit

/// The Unix-domain socket calls the host and its clients share.
enum UnixSocket {
    struct Failure: Error, CustomStringConvertible {
        let call: String
        let code: Int32
        var description: String { "\(call): \(String(cString: strerror(code)))" }
    }

    /// Room for a terminal's burst of output on each side; the system's default is 8 KiB.
    static let bufferSize: Int32 = 512 * 1024

    private static func address(_ path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count <= HostPlaces.longestSocketPath else { throw Failure(call: "socket path", code: ENAMETOOLONG) }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        return address
    }

    private static func open() throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure(call: "socket", code: errno) }
        prepare(fd)
        return fd
    }

    /// Close-on-exec, no SIGPIPE when the other side has gone, and roomy buffers.
    static func prepare(_ fd: Int32) {
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var size = bufferSize
        setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &size, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &size, socklen_t(MemoryLayout<Int32>.size))
    }

    /// A listening socket at `path`, which only you can connect to. Anything left there is replaced:
    /// the caller holds the host's lock, so it belongs to no one.
    static func listen(at path: String) throws -> Int32 {
        var address = try address(path)
        let fd = try open()
        unlink(path)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, chmod(path, 0o600) == 0, Darwin.listen(fd, 64) == 0 else {
            let code = errno
            close(fd)
            throw Failure(call: "bind", code: code)
        }
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        return fd
    }

    /// A connection to the host at `path`; throws when nothing is listening there.
    static func connect(to path: String) throws -> Int32 {
        var address = try address(path)
        let fd = try open()
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else {
            let code = errno
            close(fd)
            throw Failure(call: "connect", code: code)
        }
        return fd
    }

    /// Whether the process on the other end runs as the same user (the folder's mode already says so;
    /// this asks the kernel).
    static func peerIsSameUser(_ fd: Int32) -> Bool {
        var uid: uid_t = 0, gid: gid_t = 0
        return getpeereid(fd, &uid, &gid) == 0 && uid == getuid()
    }

    /// A folder only you can enter.
    static func makePrivateFolder(_ path: String) throws {
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard chmod(path, 0o700) == 0 else { throw Failure(call: "chmod", code: errno) }
    }
}
