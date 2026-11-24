import CryptoKit
import Foundation
import Network

/// A very small web server for the remote control in the local network: plain HTTP/1.1, one request per
/// connection, plus event streams (server-sent events) that stay open.
final class LiveRemoteServer: @unchecked Sendable {
    struct Request: Sendable {
        let method: String
        let path: String
        let query: [String: String]
        let headers: [String: String]
        let body: Data

        /// The device token from the header or, for event streams and pictures, from the address.
        var token: String? {
            if let auth = headers["authorization"], auth.hasPrefix("Bearer ") { return String(auth.dropFirst(7)) }
            return query["t"]
        }

        var json: [String: Any]? { (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] }
    }

    struct Response: Sendable {
        var status = 200
        var type = "application/json; charset=utf-8"
        var body = Data()

        static func json(_ object: Any, status: Int = 200) -> Response {
            Response(status: status, body: (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8))
        }
        static func text(_ text: String, type: String, status: Int = 200) -> Response { Response(status: status, type: type, body: Data(text.utf8)) }
        static let notFound = Response.json(["error": "not found"], status: 404)
        static let unauthorized = Response.json(["error": "unauthorized"], status: 401)
    }

    enum Reply: Sendable {
        case response(Response)
        /// Keeps the connection as an event stream for this device.
        case stream(device: String)
    }

    typealias Handler = @Sendable (Request, @escaping @Sendable (Reply) -> Void) -> Void

    private let queue = DispatchQueue(label: "screenkast.remote.server")
    private let handler: Handler
    private var listener: NWListener?
    private var streams: [(device: String, connection: NWConnection)] = []
    var onStreamsChanged: (@Sendable (Set<String>) -> Void)?

    init(handler: @escaping Handler) { self.handler = handler }

    /// Starts on the preferred port (another one if it is taken); returns the port.
    func start(preferred: UInt16) async throws -> UInt16 {
        do {
            return try await listen(on: NWEndpoint.Port(rawValue: preferred) ?? .any)
        } catch {
            return try await listen(on: .any)
        }
    }

    private func listen(on port: NWEndpoint.Port) async throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters, on: port)
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        final class Once: @unchecked Sendable { var answered = false }
        let once = Once()
        return try await withCheckedThrowingContinuation { (done: CheckedContinuation<UInt16, Error>) in
            // Runs on the server's queue, one state after the other.
            listener.stateUpdateHandler = { [weak self] state in
                guard !once.answered else { return }
                switch state {
                case .ready:
                    once.answered = true
                    self?.listener = listener
                    done.resume(returning: listener.port?.rawValue ?? 0)
                case .failed(let error):
                    once.answered = true
                    listener.cancel()
                    done.resume(throwing: error)
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        queue.sync {
            listener?.cancel()
            listener = nil
            for stream in streams { stream.connection.cancel() }
            streams.removeAll()
        }
        onStreamsChanged?([])
    }

    /// Sends an event to every open stream (or only to those of one device).
    func send(event: String, json: Data, to device: String? = nil) {
        var message = Data("event: \(event)\ndata: ".utf8)
        message.append(json)
        message.append(Data("\n\n".utf8))
        queue.async {
            for stream in self.streams where device == nil || stream.device == device {
                stream.connection.send(content: message, completion: .contentProcessed { _ in })
            }
        }
    }

    /// Ends the streams of a device that is no longer allowed.
    func close(device: String) {
        queue.async {
            for stream in self.streams where stream.device == device { stream.connection.cancel() }
            self.dropClosed()
        }
    }

    var hasStreams: Bool { queue.sync { !streams.isEmpty } }

    // MARK: Connections

    private func accept(_ connection: NWConnection) {
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            switch state {
            case .failed, .cancelled:
                guard let self, let connection else { return }
                if self.streams.contains(where: { $0.connection === connection }) {
                    self.streams.removeAll { $0.connection === connection }
                    self.onStreamsChanged?(Set(self.streams.map(\.device)))
                }
            default:
                break
            }
        }
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let request = Self.parse(buffer) {
                self.handler(request) { reply in self.queue.async { self.answer(connection, reply) } }
            } else if complete || error != nil || buffer.count > 40_000_000 {
                connection.cancel()
            } else {
                self.receive(connection, buffer: buffer)
            }
        }
    }

    private func answer(_ connection: NWConnection, _ reply: Reply) {
        switch reply {
        case .response(let response):
            var head = "HTTP/1.1 \(response.status) \(Self.reason(response.status))\r\n"
            head += "Content-Type: \(response.type)\r\nContent-Length: \(response.body.count)\r\n"
            head += "Cache-Control: no-store\r\nConnection: close\r\n\r\n"
            var data = Data(head.utf8)
            data.append(response.body)
            connection.send(content: data, completion: .contentProcessed { _ in connection.cancel() })
        case .stream(let device):
            let head = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-store\r\nConnection: keep-alive\r\n\r\nretry: 1500\n\n"
            connection.send(content: Data(head.utf8), completion: .contentProcessed { _ in })
            streams.append((device, connection))
            onStreamsChanged?(Set(streams.map(\.device)))
            // Notices when the other side goes away.
            watchClose(connection)
        }
    }

    private func watchClose(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1_024) { [weak self] _, _, complete, error in
            if complete || error != nil {
                connection.cancel()
                self?.dropClosed()
            } else {
                self?.watchClose(connection)
            }
        }
    }

    private func dropClosed() {
        let before = streams.count
        streams.removeAll { if case .cancelled = $0.connection.state { return true }; if case .failed = $0.connection.state { return true }; return false }
        if streams.count != before { onStreamsChanged?(Set(streams.map(\.device))) }
    }

    // MARK: HTTP

    static func parse(_ data: Data) -> Request? {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        guard let head = String(data: data[..<end.lowerBound], encoding: .utf8) else { return nil }
        var lines = head.components(separatedBy: "\r\n")
        let first = lines.removeFirst().split(separator: " ")
        guard first.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = end.upperBound
        guard data.count - bodyStart >= length else { return nil }
        let target = String(first[1])
        let components = URLComponents(string: target)
        var query: [String: String] = [:]
        for item in components?.queryItems ?? [] { query[item.name] = item.value ?? "" }
        return Request(method: String(first[0]), path: components?.path ?? target, query: query, headers: headers,
                       body: data.subdata(in: bodyStart..<(bodyStart + length)))
    }

    private static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 404: return "Not Found"
        default: return "Error"
        }
    }

    // MARK: Addresses and secrets

    /// The address of this Mac in the local network (Wi-Fi or Ethernet), IPv4.
    static func localAddress() -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        var found: [(name: String, address: String)] = []
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard let address = entry.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  entry.ifa_flags & UInt32(IFF_UP) != 0, entry.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let text = String(cString: host)
            guard !text.hasPrefix("169.254.") else { continue }
            found.append((String(cString: entry.ifa_name), text))
        }
        // Wi-Fi or Ethernet first (en0, en1 …); bridges and VPN tunnels last.
        return (found.first { $0.name.hasPrefix("en") } ?? found.first)?.address
    }

    static func randomSecret(bytes: Int = 18) -> String {
        var data = Data(count: bytes)
        _ = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, bytes, $0.baseAddress!) }
        return data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    static func hash(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
