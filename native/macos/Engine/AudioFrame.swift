import Foundation

struct AudioChannelFrame: Sendable {
    let level: Double
    let peak: Double
    let bands: [Double]

    var message: [String: Any] {
        [
            "level": level,
            "peak": peak,
            "bands": bands
        ]
    }
}

struct AudioFrame: Sendable {
    let sequence: UInt64
    let timestamp: TimeInterval
    let channels: [AudioChannelFrame]

    var message: [String: Any] {
        [
            "type": "audio-frame",
            "protocolVersion": AudioEngineProtocol.version,
            "sequence": sequence,
            "timestamp": timestamp,
            "channels": channels.map(\.message)
        ]
    }
}

enum AudioEngineProtocol {
    static let version = 2
    static let bandCount = 24
    static let framesPerSecond = 50
    static let minimumFrequency = 55.0
    static let maximumFrequency = 12_000.0
    static let streamName = "audio.spectrum.stereo"
    static let bundleIdentifier = "com.johnny.local-audio-engine"

    static var applicationSupportURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Local Audio Engine", isDirectory: true)
    }

    static var endpointURL: URL {
        applicationSupportURL.appendingPathComponent("endpoint.json")
    }
}
