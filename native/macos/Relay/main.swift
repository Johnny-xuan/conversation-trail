import AppKit
import CoreFoundation
import Foundation
import Network

private enum RelayProtocol {
    static let version = 2
    static let engineBundleIdentifier = "com.johnny.local-audio-engine"
    static let endpointURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Local Audio Engine/endpoint.json")
}

private struct EngineEndpoint: Decodable {
    let protocolVersion: Int
    let host: String
    let port: UInt16
    let token: String
}

private final class NativeMessenger: @unchecked Sendable {
    private let output = FileHandle.standardOutput
    private let lock = NSLock()

    func send(_ message: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(message),
              let payload = try? JSONSerialization.data(withJSONObject: message) else {
            return
        }
        var length = UInt32(payload.count).littleEndian
        let header = Data(bytes: &length, count: MemoryLayout<UInt32>.size)
        lock.lock()
        defer { lock.unlock() }
        do {
            try output.write(contentsOf: header)
            try output.write(contentsOf: payload)
        } catch {
            exit(0)
        }
    }
}

private final class EngineRelay: @unchecked Sendable {
    private enum EndpointFile {
        case missing
        case malformed
        case incompatible(Int)
        case compatible(EngineEndpoint)
    }

    private enum EngineApplicationLookup {
        case found(URL)
        case missing
        case invalid
    }

    private static let startupTimeout: TimeInterval = 15
    private static let connectionAttemptTimeout: TimeInterval = 2
    private static let endpointRetryInterval: TimeInterval = 0.25

    private let messenger: NativeMessenger
    private let queue = DispatchQueue(label: "conversation-trail.engine-relay", qos: .userInitiated)
    private var connection: NWConnection?
    private var connectionID: UUID?
    private var receiveBuffer = Data()
    private var clientID = "conversation-trail.chrome"
    private var generation: UInt64 = 0
    private var launchAttempted = false
    private var established = false
    private var observedIncompatibleVersion: Int?
    private var lastConnectionError: String?
    private var startupDeadlineWorkItem: DispatchWorkItem?
    private var connectionTimeoutWorkItem: DispatchWorkItem?
    private var endpointRetryWorkItem: DispatchWorkItem?

    init(messenger: NativeMessenger) {
        self.messenger = messenger
    }

    func start(clientID: String) {
        queue.async { [weak self] in
            self?.beginStart(clientID: clientID)
        }
    }

    func stop(notify: Bool = true) {
        queue.async { [weak self] in
            self?.stopCurrentSession(notify: notify)
        }
    }

    func inputDidEnd(completion: @escaping @Sendable () -> Void) {
        queue.async { [weak self] in
            guard let self else {
                completion()
                return
            }
            generation &+= 1
            resetSession(sendUnsubscribe: true)
            completion()
        }
    }

    private func beginStart(clientID: String) {
        generation &+= 1
        resetSession(sendUnsubscribe: true)

        self.clientID = clientID
        launchAttempted = false
        established = false
        observedIncompatibleVersion = nil
        lastConnectionError = nil

        let currentGeneration = generation
        let deadline = DispatchWorkItem { [weak self] in
            self?.startupTimedOut(generation: currentGeneration)
        }
        startupDeadlineWorkItem = deadline
        queue.asyncAfter(deadline: .now() + Self.startupTimeout, execute: deadline)

        switch loadEndpoint() {
        case .compatible(let endpoint):
            sendRelayStatus(state: "connecting", message: "正在连接 Local Audio Engine…")
            connect(to: endpoint, generation: currentGeneration)
        case .incompatible(let version):
            observedIncompatibleVersion = version
            launchEngine(generation: currentGeneration)
        case .missing, .malformed:
            launchEngine(generation: currentGeneration)
        }
    }

    private func stopCurrentSession(notify: Bool) {
        generation &+= 1
        resetSession(sendUnsubscribe: true)
        if notify {
            messenger.send(["type": "stopped"])
        }
    }

    private func resetSession(sendUnsubscribe: Bool) {
        startupDeadlineWorkItem?.cancel()
        startupDeadlineWorkItem = nil
        connectionTimeoutWorkItem?.cancel()
        connectionTimeoutWorkItem = nil
        endpointRetryWorkItem?.cancel()
        endpointRetryWorkItem = nil
        clearConnection(sendUnsubscribe: sendUnsubscribe)
        established = false
    }

    private func connect(to endpoint: EngineEndpoint, generation expectedGeneration: UInt64) {
        guard generation == expectedGeneration, connection == nil else { return }
        guard endpoint.port > 0, let port = NWEndpoint.Port(rawValue: endpoint.port) else {
            lastConnectionError = "Local Audio Engine 端口无效"
            handleStartupConnectionFailure(generation: expectedGeneration)
            return
        }

        observedIncompatibleVersion = nil
        receiveBuffer.removeAll(keepingCapacity: true)
        let id = UUID()
        let newConnection = NWConnection(
            host: NWEndpoint.Host(endpoint.host),
            port: port,
            using: .tcp
        )
        connection = newConnection
        connectionID = id
        newConnection.stateUpdateHandler = { [weak self] state in
            self?.handleConnectionState(
                state,
                endpoint: endpoint,
                connection: newConnection,
                connectionID: id,
                generation: expectedGeneration
            )
        }
        newConnection.start(queue: queue)

        let timeout = DispatchWorkItem { [weak self] in
            guard let self,
                  isCurrentConnection(id: id, generation: expectedGeneration) else {
                return
            }
            lastConnectionError = "连接本地服务超时"
            clearConnection(sendUnsubscribe: false)
            handleStartupConnectionFailure(generation: expectedGeneration)
        }
        connectionTimeoutWorkItem = timeout
        queue.asyncAfter(deadline: .now() + Self.connectionAttemptTimeout, execute: timeout)
    }

    private func handleConnectionState(
        _ state: NWConnection.State,
        endpoint: EngineEndpoint,
        connection: NWConnection,
        connectionID id: UUID,
        generation expectedGeneration: UInt64
    ) {
        guard isCurrentConnection(id: id, generation: expectedGeneration) else { return }

        switch state {
        case .ready:
            sendLine([
                "type": "hello",
                "protocolVersion": RelayProtocol.version,
                "token": endpoint.token,
                "clientId": clientID,
                "stream": "audio.spectrum.stereo"
            ], over: connection)
            receive(
                from: connection,
                connectionID: id,
                generation: expectedGeneration
            )
        case .failed(let error):
            lastConnectionError = error.localizedDescription
            clearConnection(sendUnsubscribe: false)
            handleConnectionEndedBeforeOrAfterReady(generation: expectedGeneration)
        case .cancelled:
            clearConnection(sendUnsubscribe: false)
            handleConnectionEndedBeforeOrAfterReady(generation: expectedGeneration)
        default:
            break
        }
    }

    private func receive(
        from connection: NWConnection,
        connectionID id: UUID,
        generation expectedGeneration: UInt64
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) {
            [weak self] data, _, isComplete, error in
            guard let self,
                  isCurrentConnection(id: id, generation: expectedGeneration) else {
                return
            }

            if let data, !data.isEmpty {
                receiveBuffer.append(data)
                consumeLines(connectionID: id, generation: expectedGeneration)
            }
            guard isCurrentConnection(id: id, generation: expectedGeneration) else {
                return
            }

            if isComplete || error != nil {
                lastConnectionError = error?.localizedDescription ?? "本地服务已关闭连接"
                clearConnection(sendUnsubscribe: false)
                handleConnectionEndedBeforeOrAfterReady(generation: expectedGeneration)
            } else {
                receive(
                    from: connection,
                    connectionID: id,
                    generation: expectedGeneration
                )
            }
        }
    }

    private func consumeLines(connectionID id: UUID, generation expectedGeneration: UInt64) {
        while isCurrentConnection(id: id, generation: expectedGeneration),
              let newline = receiveBuffer.firstRange(of: Data([0x0A])) {
            let line = receiveBuffer.subdata(in: receiveBuffer.startIndex..<newline.lowerBound)
            receiveBuffer.removeSubrange(receiveBuffer.startIndex...newline.lowerBound)
            guard !line.isEmpty,
                  let object = try? JSONSerialization.jsonObject(with: line),
                  let message = object as? [String: Any] else {
                continue
            }

            if message["type"] as? String == "ready" {
                guard let version = message["protocolVersion"] as? Int,
                      version == RelayProtocol.version else {
                    observedIncompatibleVersion = message["protocolVersion"] as? Int
                    clearConnection(sendUnsubscribe: false)
                    handleStartupConnectionFailure(generation: expectedGeneration)
                    return
                }
                established = true
                startupDeadlineWorkItem?.cancel()
                startupDeadlineWorkItem = nil
                connectionTimeoutWorkItem?.cancel()
                connectionTimeoutWorkItem = nil
                endpointRetryWorkItem?.cancel()
                endpointRetryWorkItem = nil
                messenger.send(message)
                continue
            }

            if !established, message["type"] as? String == "error" {
                lastConnectionError = message["message"] as? String ?? "本地服务身份验证失败"
                clearConnection(sendUnsubscribe: false)
                handleStartupConnectionFailure(generation: expectedGeneration)
                return
            }

            messenger.send(message)
        }
    }

    private func handleConnectionEndedBeforeOrAfterReady(generation expectedGeneration: UInt64) {
        guard generation == expectedGeneration else { return }
        if established {
            fail(
                "Local Audio Engine 已断开。若您刚刚退出了应用，请重新打开后在扩展中重试。",
                generation: expectedGeneration
            )
        } else {
            handleStartupConnectionFailure(generation: expectedGeneration)
        }
    }

    private func handleStartupConnectionFailure(generation expectedGeneration: UInt64) {
        guard generation == expectedGeneration else { return }
        if launchAttempted {
            scheduleEndpointRetry(generation: expectedGeneration)
        } else {
            launchEngine(generation: expectedGeneration)
        }
    }

    private func launchEngine(generation expectedGeneration: UInt64) {
        guard generation == expectedGeneration else { return }
        guard !launchAttempted else {
            scheduleEndpointRetry(generation: expectedGeneration)
            return
        }
        launchAttempted = true
        sendRelayStatus(state: "launching", message: "正在启动 Local Audio Engine…")

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let shouldLaunch = queue.sync {
                self.generation == expectedGeneration
            }
            guard shouldLaunch else { return }
            switch Self.installedEngineApplication() {
            case .missing:
                queue.async { [weak self] in
                    self?.fail(
                        "未找到 Local Audio Engine。请先安装下载包中的 Conversation Trail Audio.pkg，然后重试。",
                        generation: expectedGeneration
                    )
                }
            case .invalid:
                queue.async { [weak self] in
                    self?.fail(
                        "Local Audio Engine 安装已损坏或版本不兼容。请重新安装最新版本。",
                        generation: expectedGeneration
                    )
                }
            case .found(let applicationURL):
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = false
                configuration.hides = true
                configuration.addsToRecentItems = false
                NSWorkspace.shared.openApplication(
                    at: applicationURL,
                    configuration: configuration
                ) { [weak self] application, error in
                    guard let self else { return }
                    queue.async { [weak self] in
                        guard let self, generation == expectedGeneration else { return }
                        if let error {
                            fail(
                                "无法启动 Local Audio Engine：\(error.localizedDescription)。请确认应用已正确安装且可打开。",
                                generation: expectedGeneration
                            )
                            return
                        }
                        guard application != nil else {
                            fail(
                                "macOS 未能启动 Local Audio Engine。请尝试从“应用程序”手动打开后重试。",
                                generation: expectedGeneration
                            )
                            return
                        }
                        sendRelayStatus(
                            state: "connecting",
                            message: "Local Audio Engine 已启动，正在等待本地服务就绪…"
                        )
                        scheduleEndpointRetry(generation: expectedGeneration, delay: 0)
                    }
                }
            }
        }
    }

    private func scheduleEndpointRetry(
        generation expectedGeneration: UInt64,
        delay: TimeInterval = EngineRelay.endpointRetryInterval
    ) {
        guard generation == expectedGeneration, connection == nil else { return }
        endpointRetryWorkItem?.cancel()
        let retry = DispatchWorkItem { [weak self] in
            guard let self, generation == expectedGeneration, connection == nil else { return }
            endpointRetryWorkItem = nil
            switch loadEndpoint() {
            case .compatible(let endpoint):
                connect(to: endpoint, generation: expectedGeneration)
            case .incompatible(let version):
                observedIncompatibleVersion = version
                scheduleEndpointRetry(generation: expectedGeneration)
            case .missing, .malformed:
                scheduleEndpointRetry(generation: expectedGeneration)
            }
        }
        endpointRetryWorkItem = retry
        queue.asyncAfter(deadline: .now() + delay, execute: retry)
    }

    private func startupTimedOut(generation expectedGeneration: UInt64) {
        guard generation == expectedGeneration else { return }
        if let version = observedIncompatibleVersion {
            fail(
                "Local Audio Engine 使用音频协议 v\(version)，但扩展需要 v\(RelayProtocol.version)。请重新安装最新版本。",
                generation: expectedGeneration
            )
            return
        }

        let detail = lastConnectionError.map { "（\($0)）" } ?? ""
        fail(
            "无法连接 Local Audio Engine\(detail)。请打开应用查看状态，确认本地服务已就绪后重试。",
            generation: expectedGeneration
        )
    }

    private func fail(_ message: String, generation expectedGeneration: UInt64) {
        guard generation == expectedGeneration else { return }
        generation &+= 1
        resetSession(sendUnsubscribe: false)
        messenger.send(["type": "error", "message": message])
    }

    private func clearConnection(sendUnsubscribe: Bool) {
        connectionTimeoutWorkItem?.cancel()
        connectionTimeoutWorkItem = nil
        guard let currentConnection = connection else {
            connectionID = nil
            receiveBuffer.removeAll(keepingCapacity: true)
            return
        }
        connection = nil
        connectionID = nil
        receiveBuffer.removeAll(keepingCapacity: true)
        currentConnection.stateUpdateHandler = nil
        if sendUnsubscribe, established {
            sendLine(["type": "unsubscribe"], over: currentConnection)
        }
        currentConnection.cancel()
    }

    private func isCurrentConnection(id: UUID, generation expectedGeneration: UInt64) -> Bool {
        generation == expectedGeneration && connectionID == id && connection != nil
    }

    private func sendLine(_ message: [String: Any], over connection: NWConnection) {
        guard var data = try? JSONSerialization.data(withJSONObject: message) else {
            return
        }
        data.append(0x0A)
        connection.send(content: data, completion: .contentProcessed { _ in })
    }

    private func sendRelayStatus(state: String, message: String) {
        messenger.send([
            "type": "relay-status",
            "state": state,
            "message": message
        ])
    }

    private func loadEndpoint() -> EndpointFile {
        guard FileManager.default.fileExists(atPath: RelayProtocol.endpointURL.path) else {
            return .missing
        }
        guard let data = try? Data(contentsOf: RelayProtocol.endpointURL),
              let endpoint = try? JSONDecoder().decode(EngineEndpoint.self, from: data) else {
            return .malformed
        }
        guard endpoint.protocolVersion == RelayProtocol.version else {
            return .incompatible(endpoint.protocolVersion)
        }
        return .compatible(endpoint)
    }

    private static func installedEngineApplication() -> EngineApplicationLookup {
        let fileManager = FileManager.default
        let fixedLocations = [
            fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Applications/Local Audio Engine.app"),
            URL(fileURLWithPath: "/Applications/Local Audio Engine.app")
        ]
        var foundInvalidApplication = false

        for applicationURL in fixedLocations where fileManager.fileExists(atPath: applicationURL.path) {
            guard Bundle(url: applicationURL)?.bundleIdentifier == RelayProtocol.engineBundleIdentifier else {
                foundInvalidApplication = true
                continue
            }
            return .found(applicationURL)
        }

        if let applicationURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: RelayProtocol.engineBundleIdentifier
        ) {
            if Bundle(url: applicationURL)?.bundleIdentifier == RelayProtocol.engineBundleIdentifier {
                return .found(applicationURL)
            }
            foundInvalidApplication = true
        }
        return foundInvalidApplication ? .invalid : .missing
    }
}

private func readExactly(_ byteCount: Int, from input: FileHandle) -> Data? {
    var data = Data()
    data.reserveCapacity(byteCount)
    while data.count < byteCount {
        let chunk = input.readData(ofLength: byteCount - data.count)
        guard !chunk.isEmpty else { return nil }
        data.append(chunk)
    }
    return data
}

private func readNativeMessage() -> [String: Any]? {
    let input = FileHandle.standardInput
    guard let header = readExactly(MemoryLayout<UInt32>.size, from: input) else {
        return nil
    }
    let length = header.withUnsafeBytes { bytes -> UInt32 in
        let raw = bytes.bindMemory(to: UInt8.self)
        return UInt32(raw[0])
            | (UInt32(raw[1]) << 8)
            | (UInt32(raw[2]) << 16)
            | (UInt32(raw[3]) << 24)
    }
    guard length > 0, length <= 1_048_576,
          let payload = readExactly(Int(length), from: input),
          let object = try? JSONSerialization.jsonObject(with: payload),
          let message = object as? [String: Any] else {
        return nil
    }
    return message
}

@main
private struct ConversationTrailRelay {
    static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(.prohibited)

        let messenger = NativeMessenger()
        let relay = EngineRelay(messenger: messenger)
        let inputQueue = DispatchQueue(
            label: "conversation-trail.native-messages",
            qos: .userInitiated
        )

        inputQueue.async {
            while let message = readNativeMessage() {
                switch message["type"] as? String {
                case "ping":
                    messenger.send(["type": "pong", "protocolVersion": RelayProtocol.version])
                case "start":
                    relay.start(
                        clientID: (message["clientId"] as? String)
                            ?? "conversation-trail.chrome"
                    )
                case "stop":
                    relay.stop()
                default:
                    messenger.send([
                        "type": "error",
                        "message": "未知的 Conversation Trail relay 命令"
                    ])
                }
            }

            relay.inputDidEnd {
                DispatchQueue.main.async {
                    CFRunLoopStop(CFRunLoopGetMain())
                }
            }
        }

        CFRunLoopRun()
    }
}
