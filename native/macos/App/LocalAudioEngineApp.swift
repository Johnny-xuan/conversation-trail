import AppKit
import SwiftUI

@MainActor
final class AudioEngineModel: ObservableObject {
    @Published var permissionGranted = false
    @Published var subscriberCount = 0
    @Published var captureActive = false
    @Published var statusMessage = "本地数据服务正在启动…"
    @Published var errorMessage = ""

    private static let permissionGuidance = """
    需要允许“屏幕与系统音频录制”权限。请点击“授予系统音频权限”；若 macOS 不再显示提示，请打开系统设置。授权后会自动开始，无需重新启用扩展。
    """

    private let analyzer = SystemAudioAnalyzer()
    private let server = AudioEngineServer()
    private var lifecycleRevision: UInt64 = 0
    private var lifecycleTask: Task<Void, Never>?
    private var waitingForPermission = false
    private var permissionWindowPresented = false
    private var permissionWindowPresenter: (() -> Void)?
    private var permissionPollingTask: Task<Void, Never>?
    private var permissionRequestTask: Task<Void, Never>?

    init() {
        permissionGranted = analyzer.permissionGranted
        server.onSubscriberCountChanged = { [weak self] count in
            DispatchQueue.main.async { [weak self] in
                self?.updateSubscriberCount(count)
            }
        }
        do {
            try server.start()
            statusMessage = "本地数据服务已就绪，等待应用连接。"
        } catch {
            errorMessage = error.localizedDescription
            statusMessage = ""
        }
    }

    func installPermissionWindowPresenter(_ presenter: @escaping () -> Void) {
        permissionWindowPresenter = presenter
        presentPermissionWindowIfNeeded()
    }

    func refreshPermission() {
        let granted = analyzer.permissionGranted
        permissionGranted = granted
        guard subscriberCount > 0 else { return }

        if granted {
            leavePermissionWait()
            errorMessage = ""
            if !captureActive {
                statusMessage = "权限已启用，正在启动系统音频分析…"
            }
        } else if !waitingForPermission {
            enterPermissionWait(announce: true)
        }
        scheduleCaptureReconciliation()
    }

    func requestPermission() {
        permissionRequestTask?.cancel()
        permissionRequestTask = nil
        errorMessage = ""
        applyPermissionResult(analyzer.requestPermission())
    }

    func openSystemSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        ) else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    private func updateSubscriberCount(_ count: Int) {
        subscriberCount = count
        permissionGranted = analyzer.permissionGranted

        if count == 0 {
            leavePermissionWait()
            errorMessage = ""
            statusMessage = "本地数据服务已就绪，等待应用连接。"
        } else if permissionGranted {
            leavePermissionWait()
            errorMessage = ""
            statusMessage = captureActive
                ? "正在向 \(count) 个应用分发实时声浪。"
                : "正在启动系统音频分析…"
        } else {
            enterPermissionWait(announce: true)
        }
        scheduleCaptureReconciliation()
    }

    private func applyPermissionResult(_ requestGranted: Bool) {
        let granted = requestGranted || analyzer.permissionGranted
        permissionGranted = granted
        if granted {
            leavePermissionWait()
            errorMessage = ""
            statusMessage = subscriberCount > 0
                ? "权限已启用，正在启动系统音频分析…"
                : "权限已启用，等待应用连接。"
        } else if subscriberCount > 0 {
            enterPermissionWait(announce: true)
        } else {
            errorMessage = Self.permissionGuidance
        }
        scheduleCaptureReconciliation()
    }

    private func enterPermissionWait(announce: Bool) {
        let isNewWaitingEpisode = !waitingForPermission
        waitingForPermission = true
        permissionGranted = false
        statusMessage = "正在等待系统音频权限；授权后将自动开始。"
        errorMessage = Self.permissionGuidance

        if announce {
            server.broadcastStatus(
                state: "permission-required",
                message: Self.permissionGuidance
            )
        }
        startPermissionPollingIfNeeded()

        if isNewWaitingEpisode {
            permissionWindowPresented = false
            presentPermissionWindowIfNeeded()
        }
    }

    private func leavePermissionWait() {
        waitingForPermission = false
        permissionWindowPresented = false
        permissionPollingTask?.cancel()
        permissionPollingTask = nil
        permissionRequestTask?.cancel()
        permissionRequestTask = nil
    }

    private func presentPermissionWindowIfNeeded() {
        guard waitingForPermission, !permissionWindowPresented else { return }
        guard permissionWindowPresenter != nil || !NSApplication.shared.windows.isEmpty else {
            return
        }
        permissionWindowPresented = true
        permissionWindowPresenter?()
        NSApplication.shared.unhide(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        DispatchQueue.main.async {
            NSApplication.shared.windows
                .first(where: { $0.canBecomeKey })?
                .makeKeyAndOrderFront(nil)
        }
        scheduleAutomaticPermissionRequest()
    }

    private func scheduleAutomaticPermissionRequest() {
        guard permissionRequestTask == nil else { return }
        permissionRequestTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: 350_000_000)
            } catch {
                return
            }
            guard let self,
                  waitingForPermission,
                  subscriberCount > 0 else {
                return
            }
            permissionRequestTask = nil
            applyPermissionResult(analyzer.requestPermission())
        }
    }

    private func startPermissionPollingIfNeeded() {
        guard permissionPollingTask == nil else { return }
        permissionPollingTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 750_000_000)
                } catch {
                    return
                }
                guard let self,
                      waitingForPermission,
                      subscriberCount > 0 else {
                    return
                }
                guard analyzer.permissionGranted else { continue }
                permissionPollingTask = nil
                applyPermissionResult(true)
                return
            }
        }
    }

    private func scheduleCaptureReconciliation() {
        lifecycleRevision &+= 1
        guard lifecycleTask == nil else { return }
        lifecycleTask = Task { @MainActor [weak self] in
            await self?.runCaptureReconciliation()
        }
    }

    private func runCaptureReconciliation() async {
        while true {
            let revision = lifecycleRevision
            let shouldCapture = subscriberCount > 0 && permissionGranted

            if shouldCapture, !captureActive {
                do {
                    try await analyzer.start { [weak server] frame in
                        server?.broadcast(frame: frame)
                    }

                    if subscriberCount > 0 && permissionGranted {
                        captureActive = true
                        errorMessage = ""
                        statusMessage = "正在向 \(subscriberCount) 个应用分发实时声浪。"
                        server.broadcastStatus(state: "streaming")
                    } else {
                        await analyzer.stop()
                        captureActive = false
                    }
                } catch SystemAudioAnalyzerError.permissionDenied {
                    captureActive = false
                    permissionGranted = false
                    if subscriberCount > 0 {
                        enterPermissionWait(announce: true)
                    }
                    lifecycleRevision &+= 1
                } catch {
                    captureActive = false
                    if subscriberCount > 0 && permissionGranted {
                        errorMessage = error.localizedDescription
                        statusMessage = ""
                        server.broadcastStatus(
                            state: "error",
                            message: error.localizedDescription
                        )
                    }
                    lifecycleTask = nil
                    return
                }
            } else if !shouldCapture, captureActive {
                await analyzer.stop()
                captureActive = false
                if subscriberCount == 0 {
                    statusMessage = "本地数据服务已就绪，等待应用连接。"
                } else if !permissionGranted {
                    statusMessage = "正在等待系统音频权限；授权后将自动开始。"
                }
            } else if shouldCapture {
                statusMessage = "正在向 \(subscriberCount) 个应用分发实时声浪。"
            }

            if lifecycleRevision == revision {
                lifecycleTask = nil
                return
            }
        }
    }
}

private struct StatusRow: View {
    let title: String
    let detail: String
    let active: Bool

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(active ? Color.green : Color.secondary.opacity(0.25))
                .frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
}

private struct ContentView: View {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var model: AudioEngineModel

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 7) {
                Text("Local Audio Engine")
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                Text("一个系统音频入口，为多个本地应用提供实时声浪数据。")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 18) {
                StatusRow(
                    title: "系统音频权限",
                    detail: model.permissionGranted ? "已授权" : "需要 macOS 屏幕与系统音频录制权限",
                    active: model.permissionGranted
                )

                HStack {
                    Button(model.permissionGranted ? "权限已启用" : "授予系统音频权限") {
                        model.requestPermission()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.permissionGranted)

                    if !model.permissionGranted {
                        Button("打开系统设置") {
                            model.openSystemSettings()
                        }
                    }
                }

                Divider()

                StatusRow(
                    title: "本地订阅服务",
                    detail: model.subscriberCount == 0
                        ? "等待本地客户端连接"
                        : "当前有 \(model.subscriberCount) 个应用订阅",
                    active: model.subscriberCount > 0
                )

                StatusRow(
                    title: "实时分析",
                    detail: model.captureActive
                        ? "左右声道各 \(AudioEngineProtocol.bandCount) 个频段，\(AudioEngineProtocol.framesPerSecond) 帧/秒"
                        : model.subscriberCount > 0 && !model.permissionGranted
                            ? "等待权限，授权后自动开始"
                            : "没有订阅时自动停止捕获",
                    active: model.captureActive
                )
            }
            .padding(20)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 18))

            if !model.statusMessage.isEmpty {
                Label(model.statusMessage, systemImage: "waveform")
                    .foregroundStyle(.secondary)
            }
            if !model.errorMessage.isEmpty {
                Label(model.errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }

            Text("音频只在本机内存中转换为强度数据。引擎不会录音、转写、保存或上传内容。各个客户端只读取同一份数据流，不会重复捕获系统声音。")
                .font(.footnote)
                .foregroundStyle(.secondary)

            Spacer(minLength: 0)
        }
        .padding(28)
        .frame(minWidth: 610, minHeight: 500)
        .onAppear {
            let presenter = openWindow
            model.installPermissionWindowPresenter {
                presenter(id: "permission-setup")
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshPermission()
        }
    }
}

private final class LocalAudioEngineAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

@main
private struct LocalAudioEngineApp: App {
    @NSApplicationDelegateAdaptor(LocalAudioEngineAppDelegate.self) private var appDelegate
    @StateObject private var model = AudioEngineModel()

    var body: some Scene {
        Window("Local Audio Engine", id: "permission-setup") {
            ContentView(model: model)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 650, height: 540)
    }
}
