import Foundation

/// One unit on a host connection. On the wire: a four-byte length (big-endian, counting what follows),
/// one byte saying which kind, then the payload. Terminal bytes travel raw, never inside JSON, so a
/// program printing megabytes costs one copy and no encoding.
public enum HostFrame: Sendable, Equatable {
    /// A `HostCall` (client to host) or a `HostMessage` (host to client), as JSON.
    case message(Data)
    /// What a terminal printed (host to client).
    case output(terminal: UUID, Data)
    /// What was typed into a terminal (client to host).
    case input(terminal: UUID, Data)

    /// A frame larger than this is a broken or hostile peer; the connection is dropped.
    public static let maximumLength = 16 * 1024 * 1024

    private enum Kind: UInt8 {
        case message = 1, output = 2, input = 3
    }

    public static func message(_ call: HostCall) -> HostFrame {
        // Encoding plain values cannot fail.
        .message((try? JSONEncoder().encode(call)) ?? Data())
    }

    public static func message(_ message: HostMessage) -> HostFrame {
        .message((try? JSONEncoder().encode(message)) ?? Data())
    }

    public var encoded: Data {
        switch self {
        case .message(let json): Self.frame(.message, terminal: nil, json)
        case .output(let terminal, let bytes): Self.frame(.output, terminal: terminal, bytes)
        case .input(let terminal, let bytes): Self.frame(.input, terminal: terminal, bytes)
        }
    }

    private static func frame(_ kind: Kind, terminal: UUID?, _ payload: Data) -> Data {
        let length = 1 + (terminal == nil ? 0 : 16) + payload.count
        var data = Data(capacity: 4 + length)
        withUnsafeBytes(of: UInt32(length).bigEndian) { data.append(contentsOf: $0) }
        data.append(kind.rawValue)
        if let terminal { withUnsafeBytes(of: terminal.uuid) { data.append(contentsOf: $0) } }
        data.append(payload)
        return data
    }

    /// The frame whose kind byte and body are `bytes`; nil for a kind this build does not know.
    fileprivate init?(_ bytes: Data) {
        let start = bytes.startIndex
        switch Kind(rawValue: bytes[start]) {
        case .message:
            self = .message(bytes.subdata(in: start + 1..<bytes.endIndex))
        case .output, .input:
            guard bytes.count >= 17 else { return nil }
            let terminal = bytes.withUnsafeBytes { UUID(uuid: $0.loadUnaligned(fromByteOffset: 1, as: uuid_t.self)) }
            let payload = bytes.subdata(in: start + 17..<bytes.endIndex)
            self = bytes[start] == Kind.output.rawValue ? .output(terminal: terminal, payload) : .input(terminal: terminal, payload)
        case nil:
            return nil
        }
    }
}

public enum HostFramingError: Error, Equatable {
    case tooLarge(Int)
    case empty
}

/// Puts frames back together from a byte stream that arrives in pieces of any size.
public struct HostFrameDecoder: Sendable {
    private var buffer = Data()
    /// How much of `buffer` has been handed out already.
    private var consumed = 0

    public init() {}

    public mutating func append(_ bytes: UnsafeRawBufferPointer) {
        compact()
        buffer.append(bytes.bindMemory(to: UInt8.self))
    }

    public mutating func append(_ data: Data) {
        compact()
        buffer.append(data)
    }

    /// The next whole frame, or nil until more bytes arrive. A frame of a kind this build does not know
    /// (from a newer peer) is passed over.
    public mutating func next() throws -> HostFrame? {
        while true {
            let available = buffer.count - consumed
            guard available >= 4 else { return nil }
            let start = buffer.startIndex + consumed
            let length = Int(buffer[start..<start + 4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
            guard length >= 1 else { throw HostFramingError.empty }
            guard length <= HostFrame.maximumLength else { throw HostFramingError.tooLarge(length) }
            guard available >= 4 + length else { return nil }
            let frame = HostFrame(buffer[start + 4..<start + 4 + length])
            consumed += 4 + length
            if let frame { return frame }
        }
    }

    /// Drops what has been handed out, once it is worth the move.
    private mutating func compact() {
        if consumed == buffer.count {
            buffer.removeAll(keepingCapacity: true)
            consumed = 0
        } else if consumed > 256 * 1024 {
            buffer.removeSubrange(buffer.startIndex..<buffer.startIndex + consumed)
            consumed = 0
        }
    }
}
