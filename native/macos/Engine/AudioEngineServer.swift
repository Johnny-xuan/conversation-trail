import Foundation
import Network

final class AudioEngineServer: @unchecked Sendable {
    var onSubscriberCountChanged: (@Sendable (Int) -> Void)?

    private final class Client {
        let id = UUID()
        let connection: NWConnection
        var buffer = Data()
        var authenticated = false
        var subscribed = false

        init(connection: NWConnection) {
            self.connection = connection
        }
    }

    private let queue = DispatchQueue(label: "local-audio-engine.server", qos: .userInitiated)
    private let fileManager = FileManager.default
    private let token = UUID().uuidString
    private var listener: NWListener?
    private var clients: [UUID: Client] = [:]

    func start() throws {
        guard listener == nil else { return }
        try fileManager.createDirectory(
            at: AudioEngineProtocol.applicationSupportURL,
            withIntermediateDirectories: true
        )

        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        let listener = try NWListener(using: parameters, on: .any)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            if case .ready = state, let port = listener.port {
                self.writeEndpoint(port: port.rawValue)
            }
        }
        listener.start(queue: queue)
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            listener?.cancel()
            listener = nil
            clients.values.forEach { $0.connection.cancel() }
            clients.removeAll()
            try? fileManager.removeItem(at: AudioEngineProtocol.endpointURL)
            onSubscriberCountChanged?(0)
        }
    }

    func broadcast(frame: AudioFrame) {
        broadcast(message: frame.message)
    }

    func broadcastStatus(state: String, message: String? = nil) {
        var payload: [String: Any] = [
            "type": "engine-status",
            "protocolVersion": AudioEngineProtocol.version,
            "state": state
        ]
        if let message {
            payload["message"] = message
        }
        broadcast(message: payload)
    }

    private func accept(_ connection: NWConnection) {
        let client = Client(connection: connection)
        clients[client.id] = client
        connection.stateUpdateHandler = { [weak self, weak client] state in
            guard let self, let client else { return }
            if case .failed = state {
                self.remove(client)
            } else if case .cancelled = state {
                self.remove(client)
            }
        }
        connection.start(queue: queue)
        receive(from: client)
    }

    private func receive(from client: Client) {
        client.connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self, weak client] data, _, isComplete, error in
            guard let self, let client else { return }
            if let data, !data.isEmpty {
                client.buffer.append(data)
                self.consumeLines(from: client)
            }
            if isComplete || error != nil {
                self.remove(client)
            } else {
                self.receive(from: client)
            }
        }
    }

    private func consumeLines(from client: Client) {
        while let newline = client.buffer.firstRange(of: Data([0x0A])) {
            let line = client.buffer.subdata(in: client.buffer.startIndex..<newline.lowerBound)
            client.buffer.removeSubrange(client.buffer.startIndex...newline.lowerBound)
            guard !line.isEmpty,
                  let object = try? JSONSerialization.jsonObject(with: line),
                  let message = object as? [String: Any] else {
                continue
            }
            handle(message, from: client)
        }
    }

    private func handle(_ message: [String: Any], from client: Client) {
        switch message["type"] as? String {
        case "hello":
            let suppliedToken = message["token"] as? String
            let suppliedVersion = message["protocolVersion"] as? Int
            guard suppliedToken == token, suppliedVersion == AudioEngineProtocol.version else {
                send([
                    "type": "error",
                    "code": "unauthorized",
                    "message": "Audio Engine handshake failed"
                ], to: client)
                client.connection.cancel()
                return
            }
            client.authenticated = true
            client.subscribed = true
            send([
                "type": "ready",
                "protocolVersion": AudioEngineProtocol.version,
                "stream": AudioEngineProtocol.streamName,
                "channels": ["left", "right"],
                "bands": AudioEngineProtocol.bandCount,
                "framesPerSecond": AudioEngineProtocol.framesPerSecond
            ], to: client)
            publishSubscriberCount()
        case "ping" where client.authenticated:
            send(["type": "pong", "protocolVersion": AudioEngineProtocol.version], to: client)
        case "unsubscribe" where client.authenticated:
            client.subscribed = false
            publishSubscriberCount()
        default:
            break
        }
    }

    private func broadcast(message: [String: Any]) {
        queue.async { [weak self] in
            guard let self else { return }
            clients.values
                .filter { $0.authenticated && $0.subscribed }
                .forEach { self.send(message, to: $0) }
        }
    }

    private func send(_ message: [String: Any], to client: Client) {
        guard JSONSerialization.isValidJSONObject(message),
              var data = try? JSONSerialization.data(withJSONObject: message) else {
            return
        }
        data.append(0x0A)
        client.connection.send(content: data, completion: .contentProcessed { [weak self, weak client] error in
            if error != nil, let self, let client {
                self.remove(client)
            }
        })
    }

    private func remove(_ client: Client) {
        guard clients.removeValue(forKey: client.id) != nil else { return }
        client.connection.cancel()
        publishSubscriberCount()
    }

    private func publishSubscriberCount() {
        let count = clients.values.filter { $0.authenticated && $0.subscribed }.count
        onSubscriberCountChanged?(count)
    }

    private func writeEndpoint(port: UInt16) {
        let payload: [String: Any] = [
            "protocolVersion": AudioEngineProtocol.version,
            "transport": "tcp",
            "host": "127.0.0.1",
            "port": Int(port),
            "token": token,
            "stream": AudioEngineProtocol.streamName,
            "channels": ["left", "right"],
            "bands": AudioEngineProtocol.bandCount,
            "framesPerSecond": AudioEngineProtocol.framesPerSecond
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) else {
            return
        }
        try? data.write(to: AudioEngineProtocol.endpointURL, options: .atomic)
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: AudioEngineProtocol.endpointURL.path)
    }
}
