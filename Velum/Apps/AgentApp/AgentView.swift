//
//  AgentView.swift
//  Velum
//
//  dsh (DeepSeek Harness) host view.
//
//  The built-in Agent app now boots `dsh web` inside the iSH Linux guest and
//  renders its Web UI (http://127.0.0.1:3080) in a WKWebView. Guest sockets
//  are backed by host sockets, so the iOS-side loopback reaches the guest
//  server directly.
//
//  Lifecycle:
//    - view appears      -> launch dsh, stream its output, poll readiness
//    - web UI ready      -> reveal WKWebView
//    - view disappears   -> cancel the streaming consumer, which kills dsh
//

import SwiftUI
import WebKit

// MARK: - Phase

enum DshAgentPhase: Equatable {
    case starting
    case ready
    case failed(String)
}

// MARK: - Model

@MainActor
final class DshAgentModel: ObservableObject {

    static let webURL = URL(string: "http://127.0.0.1:3080")!

    /// Wrapper installed by tools/prepare-dsh-rootfs.sh:
    /// `exec /opt/node/bin/node /opt/dsh/node_modules/@deepseek-ai/dsh/lib/bin.js "$@"`
    /// `exec` replaces the shell so killing the stream's pid kills Node itself.
    static let launchCommand = "exec /opt/dsh/bin/dsh web --host 127.0.0.1 --port 3080"

    @Published var phase: DshAgentPhase = .starting
    @Published var logLines: [String] = []

    private var serviceTask: Task<Void, Never>?
    private var consumerTask: Task<Void, Never>?
    private var processFinished = false

    private let maxLogLines = 200

    func start() {
        guard serviceTask == nil else { return }
        processFinished = false
        logLines.removeAll()
        phase = .starting
        appendLog("▶ dsh 启动中：\(Self.launchCommand)")

        serviceTask = Task { [weak self] in
            await self?.runService()
        }
    }

    func retry() {
        shutdown()
        start()
    }

    func shutdown() {
        serviceTask?.cancel()
        consumerTask?.cancel()
        serviceTask = nil
        consumerTask = nil
        processFinished = true
    }

    // MARK: - Service run loop

    private func runService() async {
        let stream = await ISHBridge.shared.executeStreaming(Self.launchCommand)

        consumerTask = Task { [weak self] in
            do {
                for try await line in stream {
                    if let self {
                        await MainActor.run { self.appendLog(line) }
                    }
                }
            } catch {
                // Non-zero exit is delivered through the stream's error.
                if let self {
                    await MainActor.run { self.appendLog("[dsh 进程退出] \(error.localizedDescription)") }
                }
            }
            if let self {
                await MainActor.run { self.processFinished = true }
            }
        }

        await waitUntilReady()

        // Keep consuming until this service task is cancelled (view disappeared).
        await consumerTask?.value
    }

    /// Poll the loopback URL. iSH guest startup + Node + dsh boot can take a
    /// while on device, so allow up to two minutes before declaring failure.
    private func waitUntilReady() async {
        let polls = 240
        for _ in 0..<polls {
            if Task.isCancelled { return }
            if phase == .ready { return }
            if processFinished {
                phase = .failed("dsh 进程提前退出，请查看下方日志")
                shutdown()
                return
            }

            if let ready = await Self.probeWebServer(), ready {
                phase = .ready
                appendLog("✓ dsh Web UI 已就绪：\(Self.webURL.absoluteString)")
                return
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }

        if phase == .starting {
            phase = .failed("等待 dsh 启动超时（120 秒）")
            appendLog("✗ 启动超时，请点击「重试」或检查终端中 dsh 日志")
            shutdown()
        }
    }

    private static func probeWebServer() async -> Bool {
        var request = URLRequest(url: webURL)
        request.timeoutInterval = 2
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse).map { (200...399).contains($0.statusCode) } ?? false
        } catch {
            return false
        }
    }

    private func appendLog(_ line: String) {
        guard !line.isEmpty else { return }
        logLines.append(line)
        if logLines.count > maxLogLines {
            logLines.removeFirst(logLines.count - maxLogLines)
        }
    }
}

// MARK: - AgentView

struct AgentView: View {
    @StateObject private var model = DshAgentModel()

    var body: some View {
        ZStack {
            DshWebView(model: model)
                .opacity(model.phase == .ready ? 1 : 0)
                .allowsHitTesting(model.phase == .ready)

            if model.phase != .ready {
                statusOverlay
            }
        }
        .background(Color(.systemBackground))
        .onAppear { model.start() }
        .onDisappear { model.shutdown() }
    }

    // MARK: - Startup / failure overlay

    @ViewBuilder
    private var statusOverlay: some View {
        VStack(spacing: 14) {
            Spacer()

            switch model.phase {
            case .starting:
                ProgressView()
                    .controlSize(.large)
                Text("正在启动 dsh")
                    .font(.title3.weight(.semibold))
                Text("dsh 运行在 iSH (Alpine Linux) 内\n就绪后将自动打开 Web UI")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.callout.weight(.medium))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                Button("重试") {
                    model.retry()
                }
                .buttonStyle(.borderedProminent)
            case .ready:
                EmptyView()
            }

            if !model.logLines.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(model.logLines.indices, id: \.self) { index in
                            Text(model.logLines[index])
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(10)
                }
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .frame(maxHeight: 220)
                .padding(.horizontal, 24)
            }

            Spacer()
        }
        .padding(.vertical, 24)
    }
}

// MARK: - WebView

private struct DshWebView: UIViewRepresentable {
    @ObservedObject var model: DshAgentModel

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.preferences.javaScriptEnabled = true
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.websiteDataStore = .default()

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isOpaque = true
        webView.allowsBackForwardNavigationGestures = true
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        guard model.phase == .ready, webView.url == nil else { return }
        webView.load(URLRequest(url: DshAgentModel.webURL))
    }
}
