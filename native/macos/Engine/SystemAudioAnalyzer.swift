import AVFAudio
import CoreGraphics
import CoreMedia
import Foundation
import ScreenCaptureKit

enum SystemAudioAnalyzerError: LocalizedError {
    case permissionDenied
    case noDisplay

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "请先允许“屏幕与系统音频录制”权限。"
        case .noDisplay:
            return "没有找到可用于系统音频捕获的显示器。"
        }
    }
}

final class SystemAudioAnalyzer: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    typealias FrameHandler = @Sendable (AudioFrame) -> Void

    private let audioQueue = DispatchQueue(label: "local-audio-engine.capture", qos: .userInteractive)
    private let stateLock = NSLock()
    private var stream: SCStream?
    private var frameHandler: FrameHandler?
    private let energyAnalyzer = AudioEnergyAnalyzer()

    var permissionGranted: Bool {
        CGPreflightScreenCaptureAccess()
    }

    func requestPermission() -> Bool {
        CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess()
    }

    func start(frameHandler: @escaping FrameHandler) async throws {
        let alreadyRunning = stateLock.withLock { stream != nil }
        if alreadyRunning {
            stateLock.withLock {
                self.frameHandler = frameHandler
            }
            return
        }

        guard permissionGranted else {
            throw SystemAudioAnalyzerError.permissionDenied
        }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first else {
            throw SystemAudioAnalyzerError.noDisplay
        }

        let ownApplication = content.applications.first { application in
            application.processID == ProcessInfo.processInfo.processIdentifier
        }
        let filter = SCContentFilter(
            display: display,
            excludingApplications: ownApplication.map { [$0] } ?? [],
            exceptingWindows: []
        )

        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        configuration.queueDepth = 1

        let newStream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try newStream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
        try await newStream.startCapture()

        stateLock.withLock {
            self.frameHandler = frameHandler
            stream = newStream
        }
    }

    func stop() async {
        let currentStream = stateLock.withLock {
            let value = stream
            stream = nil
            frameHandler = nil
            return value
        }

        if let currentStream {
            try? await currentStream.stopCapture()
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            audioQueue.async { [self] in
                energyAnalyzer.reset()
                continuation.resume()
            }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        stateLock.lock()
        self.stream = nil
        frameHandler = nil
        stateLock.unlock()
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard outputType == .audio, sampleBuffer.isValid else {
            return
        }

        try? sampleBuffer.withAudioBufferList { audioBufferList, _ in
            guard let description = sampleBuffer.formatDescription?.audioStreamBasicDescription,
                  let format = AVAudioFormat(
                    standardFormatWithSampleRate: description.mSampleRate,
                    channels: description.mChannelsPerFrame
                  ),
                  let samples = AVAudioPCMBuffer(
                    pcmFormat: format,
                    bufferListNoCopy: audioBufferList.unsafePointer
                  ),
                  let channels = samples.floatChannelData else {
                return
            }

            let handler = stateLock.withLock { frameHandler }
            guard let handler else { return }
            energyAnalyzer.process(
                channels: channels,
                channelCount: Int(samples.format.channelCount),
                frameCount: Int(samples.frameLength),
                sampleRate: samples.format.sampleRate,
                endingAt: Date().timeIntervalSince1970,
                emit: handler
            )
        }
    }
}
