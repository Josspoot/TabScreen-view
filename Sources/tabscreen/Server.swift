import CryptoKit
import Foundation
import Network

/// Servidor HTTP + WebSocket mínimo en un solo puerto.
///  - GET /, /app.js, ... → archivos del cliente web
///  - GET /ws?t=TOKEN     → WebSocket con el video
///
/// Mensajes binarios servidor → cliente:
///  0x01 config: [u16 ancho][u16 alto][u8 fps][u16 len][SPS][u16 len][PPS]
///  0x02 cuadro: [u8 flags (bit0 = keyframe)][u64 pts µs][AVCC]
/// Mensajes de texto cliente → servidor (JSON):
///  {"type":"hello","screen":"2560x1600",...}   {"type":"keyframe"}
final class Server {
    var onKeyframeRequest: (() -> Void)?
    /// Resolución física que reporta la tablet al conectarse.
    var onTabletScreen: ((_ width: Int, _ height: Int) -> Void)?

    var clientCount: Int {
        countLock.lock()
        defer { countLock.unlock() }
        return _clientCount
    }

    private final class Client {
        let connection: NWConnection
        var buffer: [UInt8] = []
        var isWebSocket = false
        var closed = false
        var bytesInFlight = 0
        var waitingForKeyframe = true
        var needsKeyframeRequest = false

        init(connection: NWConnection) { self.connection = connection }
    }

    private static let webFiles: [String: String] = [
        "index.html": "text/html; charset=utf-8",
        "app.js": "text/javascript; charset=utf-8",
        "fmp4.js": "text/javascript; charset=utf-8",
        "style.css": "text/css; charset=utf-8",
    ]
    /// Si una tablet acumula más que esto sin enviar, se descartan cuadros
    /// hasta el siguiente keyframe (mejor saltar que acumular latencia).
    private static let maxBytesInFlight = 1_500_000

    private let token: String
    private let webRoot: URL
    private let listener: NWListener
    private let queue = DispatchQueue(label: "tabscreen.server", qos: .userInteractive)
    private var clients: [ObjectIdentifier: Client] = [:]
    private var configMessage: Data?
    private let countLock = NSLock()
    private var _clientCount = 0

    init(port: UInt16, token: String, webRoot: URL) throws {
        self.token = token
        self.webRoot = webRoot
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.allowLocalEndpointReuse = true
        listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
    }

    func start() {
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.stateUpdateHandler = { state in
            if case .failed(let error) = state {
                print("❌ El servidor falló: \(error). ¿El puerto está ocupado? Prueba con --port")
                exit(1)
            }
        }
        listener.start(queue: queue)
    }

    // MARK: - Video

    func broadcastConfig(width: Int, height: Int, fps: Int, sps: Data, pps: Data) {
        var msg = Data([0x01])
        msg.appendUInt16(width)
        msg.appendUInt16(height)
        msg.append(UInt8(clamping: fps))
        msg.appendUInt16(sps.count)
        msg.append(sps)
        msg.appendUInt16(pps.count)
        msg.append(pps)
        let framed = Self.webSocketFrame(opcode: 0x2, payload: msg)
        queue.async {
            self.configMessage = framed
            for client in self.clients.values {
                client.waitingForKeyframe = true
                self.send(framed, to: client)
            }
        }
    }

    func broadcastFrame(_ frame: H264Encoder.Frame) {
        var msg = Data(capacity: frame.data.count + 10)
        msg.append(0x02)
        msg.append(frame.isKeyframe ? 1 : 0)
        withUnsafeBytes(of: UInt64(bitPattern: frame.ptsMicros).bigEndian) { msg.append(contentsOf: $0) }
        msg.append(frame.data)
        let framed = Self.webSocketFrame(opcode: 0x2, payload: msg)

        queue.async {
            for client in self.clients.values {
                if client.waitingForKeyframe {
                    guard frame.isKeyframe else { continue }
                    client.waitingForKeyframe = false
                }
                if client.bytesInFlight > Self.maxBytesInFlight {
                    client.waitingForKeyframe = true
                    client.needsKeyframeRequest = true
                    continue
                }
                self.send(framed, to: client)
            }
        }
    }

    /// Debe llamarse en `queue`.
    private func send(_ data: Data, to client: Client) {
        guard !client.closed else { return }
        client.bytesInFlight += data.count
        client.connection.send(content: data, completion: .contentProcessed { [weak self] _ in
            guard let self else { return }
            client.bytesInFlight -= data.count
            // La red se recuperó: pedimos un keyframe para reanudar el video.
            if client.needsKeyframeRequest, client.bytesInFlight < Self.maxBytesInFlight / 2 {
                client.needsKeyframeRequest = false
                self.onKeyframeRequest?()
            }
        })
    }

    // MARK: - Conexiones

    private func accept(_ connection: NWConnection) {
        let client = Client(connection: connection)
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.drop(client)
            default: break
            }
        }
        connection.start(queue: queue)
        receive(client)
    }

    private func receive(_ client: Client) {
        client.connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                client.buffer.append(contentsOf: data)
                if client.isWebSocket { self.parseWebSocketFrames(client) } else { self.handleHTTP(client) }
            }
            if isComplete || error != nil {
                self.drop(client)
            } else if !client.closed {
                self.receive(client)
            }
        }
    }

    private func drop(_ client: Client) {
        guard !client.closed else { return }
        client.closed = true
        client.connection.cancel()
        if clients.removeValue(forKey: ObjectIdentifier(client)) != nil {
            setClientCount(clients.count)
            print("📴 Tablet desconectada (\(clients.count) conectada(s))")
        }
    }

    private func setClientCount(_ count: Int) {
        countLock.lock()
        _clientCount = count
        countLock.unlock()
    }

    // MARK: - HTTP

    private func handleHTTP(_ client: Client) {
        guard let end = client.buffer.firstRange(of: [13, 10, 13, 10]) else {
            if client.buffer.count > 16_384 { drop(client) }
            return
        }
        let head = String(decoding: client.buffer[..<end.lowerBound], as: UTF8.self)
        client.buffer.removeSubrange(..<end.upperBound)

        let lines = head.components(separatedBy: "\r\n")
        let requestLine = lines[0].split(separator: " ")
        guard requestLine.count >= 2, requestLine[0] == "GET" else {
            respond(client, status: "405 Method Not Allowed", body: Data("Método no permitido".utf8))
            return
        }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }

        let components = URLComponents(string: String(requestLine[1]))
        let path = components?.path ?? "/"

        if path == "/ws" {
            let givenToken = components?.queryItems?.first(where: { $0.name == "t" })?.value
            guard givenToken == token,
                  headers["upgrade"]?.lowercased() == "websocket",
                  let key = headers["sec-websocket-key"]
            else {
                respond(client, status: "403 Forbidden", body: Data("Token inválido. Escanea de nuevo el QR.".utf8))
                return
            }
            upgrade(client, key: key)
            return
        }

        let name = path == "/" ? "index.html" : String(path.dropFirst())
        guard let type = Self.webFiles[name],
              let body = try? Data(contentsOf: webRoot.appendingPathComponent(name))
        else {
            respond(client, status: "404 Not Found", body: Data("No encontrado".utf8))
            return
        }
        respond(client, status: "200 OK", type: type, body: body)
    }

    private func respond(_ client: Client, status: String, type: String = "text/plain; charset=utf-8", body: Data) {
        let head = "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\n"
            + "Cache-Control: no-store\r\nConnection: close\r\n\r\n"
        client.connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { [weak self] _ in
            self?.drop(client)
        })
    }

    // MARK: - WebSocket

    private func upgrade(_ client: Client, key: String) {
        let magic = key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
        let accept = Data(Insecure.SHA1.hash(data: Data(magic.utf8))).base64EncodedString()
        let response = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
            + "Sec-WebSocket-Accept: \(accept)\r\n\r\n"
        client.connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in })

        client.isWebSocket = true
        clients[ObjectIdentifier(client)] = client
        setClientCount(clients.count)
        print("📱 Tablet conectada desde \(Self.describe(client.connection.endpoint)) (\(clients.count) conectada(s))")

        if let configMessage { send(configMessage, to: client) }
        onKeyframeRequest?()
        if !client.buffer.isEmpty { parseWebSocketFrames(client) }
    }

    private func parseWebSocketFrames(_ client: Client) {
        while true {
            let b = client.buffer
            guard b.count >= 2 else { return }
            let opcode = b[0] & 0x0F
            let masked = b[1] & 0x80 != 0
            var length = Int(b[1] & 0x7F)
            var offset = 2
            if length == 126 {
                guard b.count >= 4 else { return }
                length = Int(b[2]) << 8 | Int(b[3])
                offset = 4
            } else if length == 127 {
                guard b.count >= 10 else { return }
                length = b[2..<10].reduce(0) { $0 << 8 | Int($1) }
                offset = 10
            }
            guard length < 1_000_000 else { drop(client); return }
            let maskStart = offset
            if masked { offset += 4 }
            guard b.count >= offset + length else { return }

            var payload = Array(b[offset..<offset + length])
            if masked {
                for i in payload.indices { payload[i] ^= b[maskStart + i % 4] }
            }
            client.buffer.removeFirst(offset + length)

            switch opcode {
            case 0x1: handleText(String(decoding: payload, as: UTF8.self))
            case 0x8: drop(client); return
            case 0x9: send(Self.webSocketFrame(opcode: 0xA, payload: Data(payload)), to: client)
            default: break
            }
        }
    }

    private func handleText(_ text: String) {
        guard let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let type = json["type"] as? String else { return }
        switch type {
        case "keyframe":
            onKeyframeRequest?()
        case "hello":
            let screen = json["screen"] as? String ?? "?"
            print("   Resolución de la tablet: \(screen)")
            let size = screen.split(separator: "x").compactMap { Int($0) }
            if size.count == 2 { onTabletScreen?(size[0], size[1]) }
        default:
            break
        }
    }

    private static func webSocketFrame(opcode: UInt8, payload: Data) -> Data {
        var frame = Data(capacity: payload.count + 10)
        frame.append(0x80 | opcode)
        let n = payload.count
        if n < 126 {
            frame.append(UInt8(n))
        } else if n <= 0xFFFF {
            frame.append(126)
            frame.appendUInt16(n)
        } else {
            frame.append(127)
            withUnsafeBytes(of: UInt64(n).bigEndian) { frame.append(contentsOf: $0) }
        }
        frame.append(payload)
        return frame
    }

    private static func describe(_ endpoint: NWEndpoint) -> String {
        if case .hostPort(let host, _) = endpoint { return "\(host)" }
        return "\(endpoint)"
    }
}

private extension Data {
    mutating func appendUInt16(_ value: Int) {
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8(value & 0xFF))
    }
}
