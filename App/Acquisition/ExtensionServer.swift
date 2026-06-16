import Foundation
import Network
import FilterCore

/// A lightweight local HTTP server that accepts text + positions from the
/// companion browser extension. Runs on 127.0.0.1:31337.
///
/// Routes:
///   POST /blocks    — the browser text source: viewport-relative paragraph
///                     rects + text for the active tab. Pushed to the overlay.
///   POST /clear     — the active tab went away (hidden / unloaded / route
///                     change / closed). Drop that browser's highlight layer.
///   POST /fallback  — a canvas editor (Google Docs) has no DOM text; let the
///                     native Accessibility/OCR path own this surface instead.
///   POST /heartbeat — keep the native AX-suppression gate warm for a static
///                     but covered page.
///   POST /evaluate  — legacy: score a single text and return the number (kept
///                     for any synchronous in-page caller).
///   OPTIONS *       — CORS / Private Network Access preflight.
///
/// Security: bound to loopback, plus a shared token and a chrome-extension://
/// Origin check. This is hardening against casual webpage abuse on the open
/// port, NOT isolation from a malicious co-resident process.
final class ExtensionServer {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "dev.aicf.ExtensionServer")

    /// Must match `TOKEN` in the extension's background.js.
    private static let token = "aicf-local-v1"
    /// Hard ceilings so a lying or slow-dribble request can't pin memory.
    private static let maxBodyBytes = 4 * 1024 * 1024          // 4 MiB
    private static let maxRequestBytes = maxBodyBytes + 64 * 1024

    // MARK: Payloads

    struct Viewport: Decodable {
        let innerWidth, innerHeight: Double
        let outerWidth, outerHeight: Double
        let screenX, screenY: Double
        let scrollX, scrollY: Double
        let dpr: Double
        let captureSeq: Int
    }
    struct Rect: Decodable { let x, y, w, h: Double }
    struct Block: Decodable { let id, text: String; let rect: Rect }

    struct BlocksPayload: Decodable {
        let layerKey: String
        let focused: Bool
        let host: String
        let url: String
        let viewport: Viewport
        let blocks: [Block]
    }
    struct ClearPayload: Decodable { let layerKey: String; let reason: String? }
    struct FallbackPayload: Decodable { let layerKey: String; let host: String?; let reason: String? }
    struct HeartbeatPayload: Decodable { let layerKey: String; let focused: Bool; let host: String? }

    // MARK: Seams (wired by MenuBarManager)

    /// Legacy single-text scoring (returns a 0–1 score), kept for back-compat.
    var onEvaluateRequest: ((_ text: String, _ domain: String) async -> Double?)?
    var onBrowserBlocks: ((BlocksPayload) async -> Void)?
    var onBrowserClear: ((ClearPayload) async -> Void)?
    var onBrowserFallback: ((FallbackPayload) async -> Void)?
    var onBrowserHeartbeat: ((HeartbeatPayload) async -> Void)?

    init?() {
        guard let port = NWEndpoint.Port(rawValue: 31337) else { return nil }
        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            listener = try NWListener(using: parameters, on: port)
        } catch {
            print("Failed to start ExtensionServer: \(error)")
            return nil
        }
    }

    func start() {
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                print("ExtensionServer running on port 31337")
            case .failed(let error):
                print("ExtensionServer failed: \(error)")
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.handleConnection(connection)
        }
        listener.start(queue: queue)
    }

    // MARK: - Connection handling (Content-Length aware)

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    /// Accumulate bytes until a full HTTP request (headers + Content-Length body)
    /// is available, then dispatch. A single rect batch can exceed one TCP read,
    /// so we must buffer rather than parse the first chunk blindly.
    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { connection.cancel(); return }
            var buf = buffer
            if let data, !data.isEmpty { buf.append(data) }

            // Bound memory: a lying or slow-dribble request must not grow forever.
            guard buf.count <= Self.maxRequestBytes else {
                self.sendResponse(to: connection, status: "413 Payload Too Large", body: "{}")
                return
            }

            switch Self.parseRequest(buf) {
            case .complete(let request):
                self.dispatch(request, connection: connection)   // Connection: close
            case .invalid:
                self.sendResponse(to: connection, status: "400 Bad Request", body: "{}")
            case .incomplete:
                if isComplete || error != nil { connection.cancel() }
                else { self.receive(on: connection, buffer: buf) }
            }
        }
    }

    private struct HTTPRequest {
        let method: String
        let path: String
        let headers: [String: String]   // lowercased keys
        let body: Data
    }

    private enum ParseResult { case incomplete, invalid, complete(HTTPRequest) }

    /// `.complete` once headers + the full Content-Length body have arrived,
    /// `.incomplete` while more bytes are needed, `.invalid` for a malformed or
    /// out-of-bounds request (negative/oversized length, chunked encoding) — the
    /// caller answers 400 and closes rather than trapping or looping forever.
    private static func parseRequest(_ buf: Data) -> ParseResult {
        let separator = Data("\r\n\r\n".utf8)
        guard let sep = buf.range(of: separator) else { return .incomplete }
        let headerData = buf.subdata(in: buf.startIndex..<sep.lowerBound)
        guard let headerString = String(data: headerData, encoding: .utf8) else { return .invalid }

        let lines = headerString.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return .invalid }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return .invalid }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }

        // The only client sets Content-Length and never chunks. Reject anything
        // else explicitly: a negative length would make the bounds check pass and
        // then trap on `subdata(in:)` with lowerBound > upperBound.
        if headers["transfer-encoding"] != nil { return .invalid }
        guard let contentLength = Int(headers["content-length"] ?? "0"),
              contentLength >= 0, contentLength <= maxBodyBytes else { return .invalid }

        let bodyStart = sep.upperBound
        let available = buf.distance(from: bodyStart, to: buf.endIndex)
        if available < contentLength { return .incomplete }   // body not fully arrived
        let bodyEnd = buf.index(bodyStart, offsetBy: contentLength)
        let body = buf.subdata(in: bodyStart..<bodyEnd)

        return .complete(HTTPRequest(method: String(parts[0]), path: String(parts[1]),
                                     headers: headers, body: body))
    }

    private func dispatch(_ req: HTTPRequest, connection: NWConnection) {
        if req.method == "OPTIONS" {
            sendPreflight(to: connection)
            return
        }

        // Every data-plane route — including legacy /evaluate, which triggers ML
        // inference — requires the token + chrome-extension:// Origin.
        guard authorized(req) else {
            sendResponse(to: connection, status: "403 Forbidden", body: "{}")
            return
        }

        switch true {
        case req.path.hasPrefix("/blocks"):
            guard let payload = Self.decode(BlocksPayload.self, req.body) else {
                sendResponse(to: connection, status: "400 Bad Request", body: "{}"); return
            }
            Task { @MainActor in
                await self.onBrowserBlocks?(payload)
                self.sendResponse(to: connection, status: "200 OK", body: "{\"ok\":true}")
            }
        case req.path.hasPrefix("/clear"):
            guard let payload = Self.decode(ClearPayload.self, req.body) else {
                sendResponse(to: connection, status: "400 Bad Request", body: "{}"); return
            }
            Task { @MainActor in
                await self.onBrowserClear?(payload)
                self.sendResponse(to: connection, status: "200 OK", body: "{\"ok\":true}")
            }
        case req.path.hasPrefix("/fallback"):
            guard let payload = Self.decode(FallbackPayload.self, req.body) else {
                sendResponse(to: connection, status: "400 Bad Request", body: "{}"); return
            }
            Task { @MainActor in
                await self.onBrowserFallback?(payload)
                self.sendResponse(to: connection, status: "200 OK", body: "{\"ok\":true}")
            }
        case req.path.hasPrefix("/heartbeat"):
            guard let payload = Self.decode(HeartbeatPayload.self, req.body) else {
                sendResponse(to: connection, status: "400 Bad Request", body: "{}"); return
            }
            Task { @MainActor in
                await self.onBrowserHeartbeat?(payload)
                self.sendResponse(to: connection, status: "200 OK", body: "{\"ok\":true}")
            }
        case req.path.hasPrefix("/evaluate"):
            handleEvaluate(req.body, connection: connection)   // now token-gated above
        default:
            sendResponse(to: connection, status: "404 Not Found", body: "{}")
        }
    }

    private func authorized(_ req: HTTPRequest) -> Bool {
        guard req.headers["x-aicf-token"] == Self.token else { return false }
        // A webpage's fetch carries its own Origin (https://…), which we reject;
        // an extension/SW fetch carries chrome-extension:// or (on some Chrome
        // versions) none. Tolerate a missing Origin, reject a wrong one.
        if let origin = req.headers["origin"], !origin.hasPrefix("chrome-extension://") {
            return false
        }
        return true
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ body: Data) -> T? {
        try? JSONDecoder().decode(type, from: body)
    }

    // MARK: - Legacy /evaluate

    private func handleEvaluate(_ body: Data, connection: NWConnection) {
        struct Payload: Decodable { let text: String; let domain: String }
        guard let payload = Self.decode(Payload.self, body) else {
            sendResponse(to: connection, status: "400 Bad Request", body: "{}")
            return
        }
        Task { @MainActor in
            guard let score = await self.onEvaluateRequest?(payload.text, payload.domain) else {
                self.sendResponse(to: connection, status: "500 Internal Server Error", body: "{}")
                return
            }
            self.sendResponse(to: connection, status: "200 OK", body: "{ \"score\": \(score) }")
        }
    }

    // MARK: - Responses

    /// Private Network Access: a secure/public page's first POST to a loopback
    /// address is preflighted, and the OPTIONS response MUST grant the private
    /// network or Chrome blocks the POST regardless of CORS.
    private func sendPreflight(to connection: NWConnection) {
        let response = """
        HTTP/1.1 204 No Content\r
        Access-Control-Allow-Origin: *\r
        Access-Control-Allow-Methods: POST, OPTIONS\r
        Access-Control-Allow-Headers: Content-Type, X-AICF-Token\r
        Access-Control-Allow-Private-Network: true\r
        Content-Length: 0\r
        Connection: close\r
        \r

        """
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func sendResponse(to connection: NWConnection, status: String, body: String) {
        let response = """
        HTTP/1.1 \(status)\r
        Content-Type: application/json\r
        Access-Control-Allow-Origin: *\r
        Access-Control-Allow-Private-Network: true\r
        Content-Length: \(body.utf8.count)\r
        Connection: close\r
        \r
        \(body)
        """
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
