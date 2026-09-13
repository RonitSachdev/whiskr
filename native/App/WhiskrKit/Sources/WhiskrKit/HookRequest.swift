import Foundation

/// The request line and headers of an HTTP/1.1 request.
public struct HTTPRequestHead: Sendable, Equatable {
    public let method: String
    public let path: String
    public let query: [String: String]
    /// Header names lowercased. A repeated header keeps its first value.
    public let headers: [String: String]

    /// The largest head accepted; hook requests have a handful of short headers.
    public static let maxSize = 16 * 1024

    /// Parses everything before the blank line that ends the head (without that line). nil when malformed.
    public static func parse(_ data: Data) -> HTTPRequestHead? {
        guard data.count <= maxSize, let text = String(data: data, encoding: .utf8) else { return nil }
        var lines = text.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: false)
        guard requestLine.count == 3, requestLine[2].hasPrefix("HTTP/1.") else { return nil }
        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { return nil }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            guard !name.isEmpty else { return nil }
            if headers[name] == nil { headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces) }
        }
        let target = String(requestLine[1])
        guard target.hasPrefix("/"), let components = URLComponents(string: target) else { return nil }
        var query: [String: String] = [:]
        for item in components.queryItems ?? [] where query[item.name] == nil { query[item.name] = item.value ?? "" }
        return HTTPRequestHead(method: String(requestLine[0]), path: components.path, query: query, headers: headers)
    }
}

/// How a request's body is delimited.
public enum BodyFraming: Sendable, Equatable {
    case length(Int)
    case chunked
}

/// Why a hook request was turned away, with the status it is answered with.
public enum HookRejection: Error, Sendable, Equatable {
    case wrongHost, notFound, wrongMethod, wrongToken, tooLarge, malformed

    public var status: Int {
        switch self {
        case .wrongHost: 403
        case .notFound: 404
        case .wrongMethod: 405
        case .wrongToken: 401
        case .tooLarge: 413
        case .malformed: 400
        }
    }
}

/// A hook request that passed every check: which pane it came from and how to read its body.
public struct HookRoute: Sendable, Equatable {
    public let paneID: String
    public let framing: BodyFraming
}

/// Decides whether a request is a hook post from a Claude session this app started. Hook events carry
/// prompts and file contents, so only requests to this app's own address, port and secret are taken:
/// the Host header must name 127.0.0.1 or localhost on our port (which stops a web page in a browser
/// from reaching the listener through DNS rebinding), and the token in the URL must match.
public struct HookGate: Sendable {
    public static let pathPrefix = "/hook/"
    /// Tool inputs and outputs can be large (a whole file written); this bounds what is read.
    public static let maxBody = 64 * 1024 * 1024

    public let port: UInt16
    public let token: String

    public init(port: UInt16, token: String) {
        self.port = port
        self.token = token
    }

    /// A fresh random secret: 32 bytes as hex.
    public static func makeToken() -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<32).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max, using: &generator)) }.joined()
    }

    /// The URL a pane's Claude session posts its hook events to.
    public func url(paneID: String) -> URL {
        // Only plain ASCII goes in, so this cannot fail.
        URL(string: "http://127.0.0.1:\(port)\(Self.pathPrefix)\(paneID)?token=\(token)")!
    }

    public func check(_ head: HTTPRequestHead) -> Result<HookRoute, HookRejection> {
        let host = head.headers["host"] ?? ""
        guard host == "127.0.0.1:\(port)" || host == "localhost:\(port)" else { return .failure(.wrongHost) }
        guard head.path.hasPrefix(Self.pathPrefix) else { return .failure(.notFound) }
        let paneID = String(head.path.dropFirst(Self.pathPrefix.count))
        guard UUID(uuidString: paneID) != nil else { return .failure(.notFound) }
        guard head.method == "POST" else { return .failure(.wrongMethod) }
        guard Self.constantTimeEqual(head.query["token"] ?? "", token) else { return .failure(.wrongToken) }
        if head.headers["transfer-encoding"]?.lowercased() == "chunked" {
            return .success(HookRoute(paneID: paneID, framing: .chunked))
        }
        guard let lengthText = head.headers["content-length"] else { return .success(HookRoute(paneID: paneID, framing: .length(0))) }
        guard let length = Int(lengthText), length >= 0 else { return .failure(.malformed) }
        guard length <= Self.maxBody else { return .failure(.tooLarge) }
        return .success(HookRoute(paneID: paneID, framing: .length(length)))
    }

    /// Compares without stopping at the first difference, so timing says nothing about the secret.
    static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        var difference: UInt8 = 0
        for i in x.indices { difference |= x[i] ^ y[i] }
        return difference == 0
    }
}

/// Reassembles a body sent with `Transfer-Encoding: chunked`, a piece at a time as it arrives.
public struct ChunkedDecoder: Sendable {
    public enum Failure: Error, Sendable { case malformed, tooLarge }

    private enum State: Sendable {
        case size
        case data(remaining: Int)
        case dataEnd
        case trailers
        case finished
    }

    private var state = State.size
    private var pending = Data()
    public private(set) var body = Data()
    public var isFinished: Bool { if case .finished = state { true } else { false } }

    public init() {}

    /// Takes the next bytes received. Returns true once the whole body has arrived.
    public mutating func feed(_ data: Data) throws -> Bool {
        pending.append(data)
        while true {
            switch state {
            case .finished:
                return true
            case .size:
                guard let line = try takeLine() else { return false }
                let digits = line.split(separator: ";", maxSplits: 1).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
                guard !digits.isEmpty, digits.count <= 8, let size = Int(digits, radix: 16) else { throw Failure.malformed }
                guard body.count + size <= HookGate.maxBody else { throw Failure.tooLarge }
                state = size == 0 ? .trailers : .data(remaining: size)
            case .data(let remaining):
                guard !pending.isEmpty else { return false }
                let take = min(remaining, pending.count)
                body.append(pending.prefix(take))
                pending.removeFirst(take)
                state = take == remaining ? .dataEnd : .data(remaining: remaining - take)
            case .dataEnd:
                guard let line = try takeLine() else { return false }
                guard line.isEmpty else { throw Failure.malformed }
                state = .size
            case .trailers:
                guard let line = try takeLine() else { return false }
                if line.isEmpty { state = .finished }
            }
        }
    }

    /// The next line without its CRLF, or nil until a whole line has arrived.
    private mutating func takeLine() throws -> String? {
        guard let end = pending.firstRange(of: Data([13, 10])) else {
            // A size or trailer line is short; this much without a line end is not chunked encoding.
            if pending.count > HTTPRequestHead.maxSize { throw Failure.malformed }
            return nil
        }
        let line = String(decoding: pending[pending.startIndex..<end.lowerBound], as: UTF8.self)
        pending.removeSubrange(pending.startIndex..<end.upperBound)
        return line
    }
}
