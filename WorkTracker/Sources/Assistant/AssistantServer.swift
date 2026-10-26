import Foundation
import Network
import Observation

/// Lets AI assistants on this Mac (Claude Code, Codex, any MCP client) read and change
/// Work Tracker's data: an MCP server (Streamable HTTP with JSON responses) on the
/// loopback interface, turned on per Mac in Settings ▸ Assistants. Clients send a bearer
/// token. While nobody calls it, it only waits for connections, so it costs nothing.
///
/// It runs inside the app, so its changes go through the same database and preferences
/// as the app's own and sync to the other Macs. The protocol side is `MCPHandler`.
@MainActor
@Observable
final class AssistantServer {
    static let defaultPort: UInt16 = 47615
    private static let enabledKey = "assistantServerEnabled"
    /// Only set by hand (`defaults write`), for a test build next to the installed app.
    private static let portKey = "assistantServerPort"
    private static let tokenKey = "assistantServerToken"

    private(set) var isEnabled: Bool
    private(set) var isListening = false
    private(set) var errorMessage: String?
    private(set) var token: String
    let port: UInt16

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var handler: MCPHandler?
    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private var connections: [ObjectIdentifier: HTTPConnection] = [:]
    @ObservationIgnored private var retry: Task<Void, Never>?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isEnabled = defaults.bool(forKey: Self.enabledKey)
        let stored = defaults.integer(forKey: Self.portKey)
        port = (1024...65535).contains(stored) ? UInt16(stored) : Self.defaultPort
        token = defaults.string(forKey: Self.tokenKey) ?? ""
    }

    var endpoint: String { "http://127.0.0.1:\(port)/mcp" }

    /// Serve `handler`'s tools, from now on whenever the server is turned on.
    func start(handler: MCPHandler) {
        self.handler = handler
        if isEnabled { listen() }
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        defaults.set(enabled, forKey: Self.enabledKey)
        if enabled { listen() } else { stop() }
    }

    /// Assistants set up with the old token are refused until they get the new one.
    func renewToken() {
        // SystemRandomNumberGenerator is cryptographically secure on Apple platforms.
        token = (0..<24).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max)) }.joined()
        defaults.set(token, forKey: Self.tokenKey)
    }

    // MARK: - Listening

    private func listen() {
        guard isEnabled, listener == nil, handler != nil, let port = NWEndpoint.Port(rawValue: port) else { return }
        if token.isEmpty { renewToken() }
        retry?.cancel()
        retry = nil
        let parameters = NWParameters.tcp
        // Loopback only: nothing outside this Mac can connect.
        parameters.requiredInterfaceType = .loopback
        parameters.allowLocalEndpointReuse = true
        do {
            let listener = try NWListener(using: parameters, on: port)
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                MainActor.assumeIsolated { self?.update(listener, state) }
            }
            listener.newConnectionHandler = { [weak self] connection in
                MainActor.assumeIsolated { self?.accept(connection) }
            }
            self.listener = listener
            listener.start(queue: .main)
        } catch {
            fail(error)
        }
    }

    private func update(_ listener: NWListener?, _ state: NWListener.State) {
        guard let listener, listener === self.listener else { return }
        switch state {
        case .ready:
            isListening = true
            errorMessage = nil
        case .waiting(let error):
            errorMessage = message(for: error)
        case .failed(let error):
            fail(error)
        default:
            break
        }
    }

    private func fail(_ error: Error) {
        listener?.cancel()
        listener = nil
        isListening = false
        errorMessage = message(for: error)
        // The port may be taken only briefly, e.g. by a Work Tracker that's still quitting.
        retry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled else { return }
            self?.listen()
        }
    }

    private func stop() {
        retry?.cancel()
        retry = nil
        listener?.cancel()
        listener = nil
        connections.values.forEach { $0.cancel() }
        connections = [:]
        isListening = false
        errorMessage = nil
    }

    private func message(for error: Error) -> String {
        if let error = error as? NWError, case .posix(.EADDRINUSE) = error {
            return tr("Port %@ is in use by another app.", String(port))
        }
        return error.localizedDescription
    }

    private func accept(_ connection: NWConnection) {
        guard isEnabled, connections.count < 64 else {
            connection.cancel()
            return
        }
        let client = HTTPConnection(connection: connection) { [weak self] request in
            self?.respond(to: request) ?? .text(503, "Service Unavailable")
        }
        let id = ObjectIdentifier(client)
        client.onClose = { [weak self] in self?.connections[id] = nil }
        connections[id] = client
        client.start()
    }

    // MARK: - Requests

    func respond(to request: HTTPRequest) -> HTTPResponse {
        // A web page can't address a request to 127.0.0.1 by name (DNS rebinding), nor
        // send one from its own origin and read the answer.
        guard Self.isLoopback(host: request.headers["host"]) else { return .text(403, "Forbidden") }
        if let origin = request.headers["origin"], !Self.isLoopback(origin: origin) { return .text(403, "Forbidden") }
        guard request.path.split(separator: "?").first == "/mcp" else { return .text(404, "Not Found") }
        guard isAuthorized(request.headers["authorization"]) else {
            return .text(401, "Unauthorized", headers: [("WWW-Authenticate", "Bearer")])
        }
        // No server-sent event stream (GET) and no sessions to end (DELETE).
        guard request.method == "POST" else { return .text(405, "Method Not Allowed", headers: [("Allow", "POST")]) }
        guard request.headers["content-type"]?.lowercased().hasPrefix("application/json") == true else {
            return .text(415, "Unsupported Media Type")
        }
        guard let handler else { return .text(503, "Service Unavailable") }
        guard let body = handler.handle(request.body) else { return HTTPResponse(status: 202) }
        return HTTPResponse(status: 200, headers: [("Content-Type", "application/json")], body: body)
    }

    private func isAuthorized(_ header: String?) -> Bool {
        guard !token.isEmpty, let header, header.lowercased().hasPrefix("bearer ") else { return false }
        let given = Array(header.dropFirst(7).trimmingCharacters(in: .whitespaces).utf8), expected = Array(token.utf8)
        guard given.count == expected.count else { return false }
        // Compare every byte, so the time taken doesn't reveal how much matched.
        return zip(given, expected).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }

    private static let loopbackNames: Set<String> = ["127.0.0.1", "localhost", "::1"]

    static func isLoopback(host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        let name = host.hasPrefix("[") ? host.dropFirst().prefix { $0 != "]" } : host.prefix { $0 != ":" }
        return loopbackNames.contains(String(name))
    }

    static func isLoopback(origin: String) -> Bool {
        guard let host = URLComponents(string: origin)?.host?.lowercased() else { return false }
        return loopbackNames.contains(host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")))
    }
}

// MARK: - HTTP

struct HTTPRequest {
    var method: String
    var path: String
    /// Names in lower case.
    var headers: [String: String]
    var body: Data
}

struct HTTPResponse {
    var status: Int
    var headers: [(String, String)] = []
    var body = Data()

    static func text(_ status: Int, _ message: String, headers: [(String, String)] = []) -> HTTPResponse {
        HTTPResponse(status: status, headers: headers + [("Content-Type", "text/plain; charset=utf-8")],
                     body: Data("\(message)\n".utf8))
    }

    func serialized(closing: Bool) -> Data {
        var head = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
        for (name, value) in headers { head += "\(name): \(value)\r\n" }
        head += "Content-Length: \(body.count)\r\nCache-Control: no-store\r\n"
        if closing { head += "Connection: close\r\n" }
        return Data("\(head)\r\n".utf8) + body
    }

    private static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 202: return "Accepted"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 413: return "Content Too Large"
        case 415: return "Unsupported Media Type"
        default: return "Service Unavailable"
        }
    }
}

enum HTTPParseError: Error {
    case malformed
    case tooLarge
}

/// Splits the bytes a connection receives into HTTP/1.1 requests.
struct HTTPRequestParser {
    static let maxHeaderBytes = 32 * 1024
    static let maxBodyBytes = 8 * 1024 * 1024
    private static let lineBreak = Data("\r\n".utf8)
    private static let blankLine = Data("\r\n\r\n".utf8)

    /// Unparsed bytes; always indexed from 0.
    private var buffer = Data()

    mutating func append(_ data: Data) { buffer.append(data) }

    /// The next complete request, or nil until more bytes arrive.
    mutating func next() throws -> HTTPRequest? {
        guard let headerEnd = buffer.range(of: Self.blankLine) else {
            if buffer.count > Self.maxHeaderBytes { throw HTTPParseError.tooLarge }
            return nil
        }
        guard headerEnd.lowerBound <= Self.maxHeaderBytes else { throw HTTPParseError.tooLarge }
        guard let head = String(data: buffer.subdata(in: 0..<headerEnd.lowerBound), encoding: .utf8) else {
            throw HTTPParseError.malformed
        }
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count == 3, requestLine[2].hasPrefix("HTTP/1.") else { throw HTTPParseError.malformed }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { throw HTTPParseError.malformed }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = headers[name].map { "\($0), \(value)" } ?? value
        }

        let bodyStart = headerEnd.upperBound
        let body: Data, end: Int
        if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
            guard let (decoded, decodedEnd) = try Self.dechunk(buffer, from: bodyStart) else { return nil }
            (body, end) = (decoded, decodedEnd)
        } else {
            guard let length = Int(headers["content-length"] ?? "0"), length >= 0 else { throw HTTPParseError.malformed }
            guard length <= Self.maxBodyBytes else { throw HTTPParseError.tooLarge }
            guard buffer.count - bodyStart >= length else { return nil }
            (body, end) = (buffer.subdata(in: bodyStart..<bodyStart + length), bodyStart + length)
        }
        buffer = buffer.subdata(in: end..<buffer.count)
        return HTTPRequest(method: String(requestLine[0]), path: String(requestLine[1]), headers: headers, body: body)
    }

    /// A chunked body and where it ends in `data`, or nil while it's incomplete.
    private static func dechunk(_ data: Data, from start: Int) throws -> (Data, Int)? {
        var body = Data(), cursor = start
        while true {
            guard let lineEnd = data.range(of: lineBreak, in: cursor..<data.count) else { return nil }
            let sizeLine = String(decoding: data.subdata(in: cursor..<lineEnd.lowerBound), as: UTF8.self)
            guard let size = Int(sizeLine.prefix { $0 != ";" }.trimmingCharacters(in: .whitespaces), radix: 16),
                  size >= 0 else { throw HTTPParseError.malformed }
            cursor = lineEnd.upperBound
            if size == 0 {
                // Optional trailer fields, then a blank line.
                if data.count - cursor >= 2, data.subdata(in: cursor..<cursor + 2) == lineBreak { return (body, cursor + 2) }
                guard let end = data.range(of: blankLine, in: cursor..<data.count) else { return nil }
                return (body, end.upperBound)
            }
            guard body.count + size <= maxBodyBytes else { throw HTTPParseError.tooLarge }
            guard data.count >= cursor + size + 2 else { return nil }
            body.append(data.subdata(in: cursor..<cursor + size))
            cursor += size + 2
        }
    }
}

/// One client connection: answers its requests in order and keeps it open for more.
@MainActor
private final class HTTPConnection {
    private let connection: NWConnection
    private let respond: (HTTPRequest) -> HTTPResponse
    private var parser = HTTPRequestParser()
    private var isClosed = false
    var onClose: () -> Void = {}

    init(connection: NWConnection, respond: @escaping (HTTPRequest) -> HTTPResponse) {
        self.connection = connection
        self.respond = respond
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                switch state {
                case .failed, .cancelled: self?.close()
                default: break
                }
            }
        }
        connection.start(queue: .main)
        receive()
    }

    func cancel() { connection.cancel() }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            MainActor.assumeIsolated {
                guard let self, !self.isClosed else { return }
                if let data, !data.isEmpty {
                    self.parser.append(data)
                    guard self.answerRequests() else { return }
                }
                if error != nil {
                    self.connection.cancel()
                } else if isComplete {
                    // The client is done sending: close once the answers are out.
                    self.finish()
                } else {
                    self.receive()
                }
            }
        }
    }

    /// Answers every complete request. False when the connection is closing.
    private func answerRequests() -> Bool {
        do {
            while let request = try parser.next() {
                let closing = request.headers["connection"]?.lowercased() == "close"
                send(respond(request), closing: closing)
                if closing { return false }
            }
            return true
        } catch {
            let tooLarge = (error as? HTTPParseError) == .tooLarge
            send(.text(tooLarge ? 413 : 400, tooLarge ? "Content Too Large" : "Bad Request"), closing: true)
            return false
        }
    }

    private func send(_ response: HTTPResponse, closing: Bool) {
        connection.send(content: response.serialized(closing: closing), completion: .contentProcessed { _ in })
        if closing { finish() }
    }

    /// Close after everything sent so far has gone out.
    private func finish() {
        connection.send(content: nil, contentContext: .finalMessage, isComplete: true,
                        completion: .contentProcessed { [weak self] _ in
            MainActor.assumeIsolated { self?.connection.cancel() }
        })
    }

    private func close() {
        guard !isClosed else { return }
        isClosed = true
        connection.stateUpdateHandler = nil
        onClose()
    }
}
