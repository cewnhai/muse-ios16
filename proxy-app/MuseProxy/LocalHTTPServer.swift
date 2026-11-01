import Foundation
import Network

struct HTTPRequest {
    var method: String
    var path: String // path + query, as sent on the request line
    var headers: [String: String] // lowercased keys
    var body: Data
}

struct HTTPResponse {
    var status: Int
    var headers: [String: String]
    var body: Data
}

/// Minimal HTTP/1.1 server on localhost (keep-alive, Content-Length bodies).
final class LocalHTTPServer {
    private var listener: NWListener?
    private let port: NWEndpoint.Port
    var handler: ((HTTPRequest) async -> HTTPResponse)?

    init(port: UInt16) {
        self.port = NWEndpoint.Port(rawValue: port)!
    }

    func start() throws {
        let listener = try NWListener(using: .tcp, on: port)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] conn in
            self?.handleConnection(conn)
        }
        listener.start(queue: .global(qos: .userInitiated))
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func handleConnection(_ conn: NWConnection) {
        conn.start(queue: .global(qos: .userInitiated))
        receiveRequest(on: conn, buffer: Data())
    }

    private func receiveRequest(on conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            var buf = buffer
            if let data = data { buf.append(data) }
            if let req = Self.parseRequest(from: &buf) {
                Task {
                    let resp = await self.handler?(req)
                        ?? HTTPResponse(status: 500, headers: [:], body: Data())
                    self.sendResponse(resp, on: conn) {
                        // keep-alive: serve next request on this connection
                        self.receiveRequest(on: conn, buffer: buf)
                    }
                }
            } else if isComplete || error != nil {
                conn.cancel()
            } else {
                self.receiveRequest(on: conn, buffer: buf)
            }
        }
    }

    /// Parses one request from the buffer; removes consumed bytes. Nil = need more data.
    static func parseRequest(from buf: inout Data) -> HTTPRequest? {
        guard let headerEnd = buf.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        guard let headerStr = String(data: buf[..<headerEnd.lowerBound], encoding: .utf8) else { return nil }
        var lines = headerStr.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }
        let parts = lines.removeFirst().components(separatedBy: " ")
        guard parts.count >= 2 else { return nil }
        let method = parts[0]
        let path = parts[1]
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[String(key)] = String(value)
        }
        let bodyStart = headerEnd.upperBound
        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        guard buf.count >= bodyStart + contentLength else { return nil }
        let body = buf[bodyStart ..< (bodyStart + contentLength)]
        buf.removeSubrange(..<(bodyStart + contentLength))
        return HTTPRequest(method: method, path: path, headers: headers, body: Data(body))
    }

    private func sendResponse(_ resp: HTTPResponse, on conn: NWConnection, completion: @escaping () -> Void) {
        var head = "HTTP/1.1 \(resp.status) \(Self.reason(for: resp.status))\r\n"
        var headers = resp.headers
        headers["content-length"] = "\(resp.body.count)"
        headers["connection"] = "keep-alive"
        for (k, v) in headers { head += "\(k): \(v)\r\n" }
        head += "\r\n"
        var data = Data(head.utf8)
        data.append(resp.body)
        conn.send(content: data, completion: .contentProcessed { _ in completion() })
    }

    static func reason(for status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 301: return "Moved Permanently"
        case 302: return "Found"
        case 400: return "Bad Request"
        case 404: return "Not Found"
        case 502: return "Bad Gateway"
        case 500: return "Internal Server Error"
        default: return "OK"
        }
    }
}
