#if os(macOS)
import Foundation
import Network
import CoreData

/// Uygulama içinde çalışan, yalnızca 127.0.0.1'de dinleyen MCP sunucusu.
/// Taşıma: MCP "Streamable HTTP" (POST /mcp → JSON yanıt). SSE akışı açılmaz.
/// Veriye uygulamanın ana viewContext'i üzerinden erişir; böylece yapay zekanın
/// yaptığı her değişiklik arayüzde anında (animasyonlu) görünür.
@MainActor
final class MCPServer: ObservableObject {
    static let shared = MCPServer()

    @Published private(set) var isRunning = false
    @Published private(set) var lastActivity: String?
    @Published var port: UInt16 {
        didSet { UserDefaults.standard.set(Int(port), forKey: "mcpPort") }
    }
    @Published var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "mcpEnabled")
            enabled ? startListener() : stop()
        }
    }

    var endpoint: String { "http://127.0.0.1:\(port)/mcp" }

    private var listener: NWListener?
    private var tools: MCPTools?

    private init() {
        let saved = UserDefaults.standard.integer(forKey: "mcpPort")
        port = saved > 0 ? UInt16(saved) : 7337
        enabled = UserDefaults.standard.object(forKey: "mcpEnabled") as? Bool ?? true
    }

    func start(context: NSManagedObjectContext) {
        tools = MCPTools(context: context) { [weak self] message in
            self?.lastActivity = message
        }
        if enabled { startListener() }
    }

    func restart() {
        if enabled { startListener() }
    }

    func startListener() {
        stop()
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        // Sadece loopback — ağdaki başka cihazlar erişemez.
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: nwPort)
        do {
            let listener = try NWListener(using: params)
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    guard let self else { return }
                    switch state {
                    case .ready: self.isRunning = true
                    case .failed(let error):
                        self.isRunning = false
                        self.lastActivity = "Hata: \(error.localizedDescription)"
                        ErrorReporter.shared.report(error, area: "MCP sunucusu")
                    case .cancelled: self.isRunning = false
                    default: break
                    }
                }
            }
            listener.newConnectionHandler = { [weak self] conn in
                Task { @MainActor in self?.accept(conn) }
            }
            listener.start(queue: .main)
            self.listener = listener
        } catch {
            lastActivity = "Başlatılamadı: \(error.localizedDescription)"
            ErrorReporter.shared.report(error, area: "MCP sunucusu")
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
    }

    // MARK: - HTTP

    private func accept(_ conn: NWConnection) {
        conn.start(queue: .main)
        receive(on: conn, buffer: Data())
    }

    private func receive(on conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            Task { @MainActor in
                guard let self else { return }
                var buffer = buffer
                if let data { buffer.append(data) }
                if let request = HTTPRequest(parsing: buffer) {
                    self.send(self.route(request), on: conn)
                } else if isComplete || error != nil || buffer.count > 8 << 20 {
                    conn.cancel()
                } else {
                    self.receive(on: conn, buffer: buffer)
                }
            }
        }
    }

    private func route(_ req: HTTPRequest) -> HTTPResponse {
        // DNS rebinding koruması: tarayıcıdan gelen yabancı Origin'leri reddet
        if let origin = req.headers["origin"],
           !(origin.hasPrefix("http://localhost") || origin.hasPrefix("http://127.0.0.1")) {
            return .text(403, "Forbidden origin")
        }
        switch (req.method, req.path) {
        case ("GET", "/health"):
            return .text(200, "ok")
        case ("POST", "/mcp"), ("POST", "/"):
            guard let json = try? JSONSerialization.jsonObject(with: req.body) else {
                return .json(400, MCPTools.rpcError(id: nil, code: -32700, message: "Parse error"))
            }
            guard let tools, let reply = tools.handle(json) else {
                return HTTPResponse(status: 202, contentType: "text/plain", body: Data())
            }
            return .json(200, reply)
        case (_, "/mcp"):
            // Sunucudan istemciye SSE akışı desteklemiyoruz (spec'e uygun: 405)
            return HTTPResponse(status: 405, contentType: "text/plain", body: Data("Method Not Allowed".utf8),
                                extraHeaders: ["Allow": "POST"])
        default:
            return .text(404, "Not found")
        }
    }

    private func send(_ response: HTTPResponse, on conn: NWConnection) {
        conn.send(content: response.serialized(), completion: .contentProcessed { _ in conn.cancel() })
    }
}

// MARK: - Minimal HTTP/1.1

struct HTTPRequest {
    var method: String
    var path: String
    var headers: [String: String]
    var body: Data

    /// Tam bir istek gelmişse döner; eksikse nil (daha fazla veri beklenir).
    init?(parsing data: Data) {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)),
              let head = String(data: data[..<headerEnd.lowerBound], encoding: .utf8) else { return nil }
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines.first?.split(separator: " ") ?? []
        guard parts.count >= 2 else { return nil }
        method = String(parts[0]).uppercased()
        path = String(parts[1].split(separator: "?").first ?? "/")

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        self.headers = headers

        let length = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = headerEnd.upperBound
        guard data.count - bodyStart >= length else { return nil }
        body = data[bodyStart..<(bodyStart + length)]
    }
}

struct HTTPResponse {
    var status: Int
    var contentType: String
    var body: Data
    var extraHeaders: [String: String] = [:]

    static func text(_ status: Int, _ text: String) -> HTTPResponse {
        HTTPResponse(status: status, contentType: "text/plain; charset=utf-8", body: Data(text.utf8))
    }

    static func json(_ status: Int, _ object: Any) -> HTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])) ?? Data()
        return HTTPResponse(status: status, contentType: "application/json", body: data)
    }

    func serialized() -> Data {
        let reason = [200: "OK", 202: "Accepted", 400: "Bad Request", 403: "Forbidden",
                      404: "Not Found", 405: "Method Not Allowed"][status] ?? "OK"
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        head += "Content-Type: \(contentType)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Connection: close\r\n"
        for (k, v) in extraHeaders { head += "\(k): \(v)\r\n" }
        head += "\r\n"
        return Data(head.utf8) + body
    }
}
#endif
