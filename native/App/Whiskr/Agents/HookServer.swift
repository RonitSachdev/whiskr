import Foundation
import Network
import WhiskrKit

/// The listener Claude sessions started by the app post their hook events to: 127.0.0.1 only, on a
/// free port chosen at launch, with a fresh secret in every URL. Each request is checked by
/// `HookGate`, answered at once with `{}` ("no opinion": the app only watches and never changes
/// what Claude does), and only then handed on.
///
/// Everything here runs on one serial queue, which is what makes the unchecked Sendable sound.
nonisolated final class HookServer: @unchecked Sendable {
    typealias Delivery = @Sendable (_ paneID: String, _ payload: JSONValue) -> Void

    let token = HookGate.makeToken()
    private let queue = DispatchQueue(label: "app.whiskr.hooks")
    private let deliver: Delivery
    private var listener: NWListener?

    init(deliver: @escaping Delivery) {
        self.deliver = deliver
    }

    /// Starts listening and returns the gate for the port that was given.
    func start() async throws -> HookGate {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        parameters.acceptLocalOnly = true
        let listener = try NWListener(using: parameters)
        self.listener = listener
        return try await withCheckedThrowingContinuation { continuation in
            let waiting = Waiting(continuation)
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    guard let port = listener.port?.rawValue else { return }
                    let gate = HookGate(port: port, token: self.token)
                    listener.newConnectionHandler = { [deliver = self.deliver, queue = self.queue] connection in
                        HookExchange(connection: connection, gate: gate, queue: queue, deliver: deliver).start()
                    }
                    waiting.resume(with: .success(gate))
                case .failed(let error):
                    waiting.resume(with: .failure(error))
                default:
                    break
                }
            }
            // Connections are refused until the gate exists; none can arrive before the listener is ready.
            listener.newConnectionHandler = { $0.cancel() }
            listener.start(queue: queue)
        }
    }

    func stop() {
        queue.sync {
            listener?.cancel()
            listener = nil
        }
    }
}

/// A continuation resumed at most once, from the listener's queue.
nonisolated private final class Waiting: @unchecked Sendable {
    private var continuation: CheckedContinuation<HookGate, Error>?

    init(_ continuation: CheckedContinuation<HookGate, Error>) {
        self.continuation = continuation
    }

    func resume(with result: Result<HookGate, Error>) {
        continuation?.resume(with: result)
        continuation = nil
    }
}

/// One HTTP request on one connection: read the head, check it, read the body, answer, hand on.
nonisolated private final class HookExchange: @unchecked Sendable {
    /// A connection that has not delivered its request by then is dropped.
    static let timeout: TimeInterval = 15

    private let connection: NWConnection
    private let gate: HookGate
    private let queue: DispatchQueue
    private let deliver: HookServer.Delivery
    private var buffer = Data()
    private var route: HookRoute?
    private var chunks = ChunkedDecoder()
    private var done = false

    init(connection: NWConnection, gate: HookGate, queue: DispatchQueue, deliver: @escaping HookServer.Delivery) {
        self.connection = connection
        self.gate = gate
        self.queue = queue
        self.deliver = deliver
    }

    func start() {
        connection.stateUpdateHandler = { [self] state in
            if case .failed = state { close() }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + Self.timeout) { [self] in close() }
        receive()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [self] data, _, complete, error in
            guard !done else { return }
            if let data, !data.isEmpty {
                buffer.append(data)
                process()
            }
            if done { return }
            if error != nil || complete { close() } else { receive() }
        }
    }

    private func process() {
        if route == nil {
            guard let end = buffer.firstRange(of: Data("\r\n\r\n".utf8)) else {
                if buffer.count > HTTPRequestHead.maxSize { respond(431) }
                return
            }
            guard let head = HTTPRequestHead.parse(buffer[buffer.startIndex..<end.lowerBound]) else { return respond(400) }
            switch gate.check(head) {
            case .failure(let rejection):
                return respond(rejection.status)
            case .success(let accepted):
                route = accepted
                buffer = Data(buffer[end.upperBound...])
            }
        }
        guard let route else { return }
        switch route.framing {
        case .length(let length):
            guard buffer.count >= length else { return }
            finish(paneID: route.paneID, body: buffer.prefix(length))
        case .chunked:
            do {
                let complete = try chunks.feed(buffer)
                buffer.removeAll()
                if complete { finish(paneID: route.paneID, body: chunks.body) }
            } catch {
                respond(error as? ChunkedDecoder.Failure == .tooLarge ? 413 : 400)
            }
        }
    }

    private func finish(paneID: String, body: Data) {
        respond(200, body: "{}")
        // A body that is not JSON is still answered; it just carries nothing to use.
        if let payload = try? JSONDecoder().decode(JSONValue.self, from: body) { deliver(paneID, payload) }
    }

    private func respond(_ status: Int, body: String = "") {
        guard !done else { return }
        done = true
        let reason = [200: "OK", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden", 404: "Not Found",
                      405: "Method Not Allowed", 413: "Content Too Large", 431: "Request Header Fields Too Large"][status] ?? "Error"
        let response = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { [self] _ in close() })
    }

    private func close() {
        done = true
        connection.stateUpdateHandler = nil
        connection.cancel()
    }
}
