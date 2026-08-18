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
    /// `exec /opt/bin/node /opt/dsh/node_modules/@deepseek-ai/dsh/lib/bin.js "$@"`
    /// `exec` replaces the shell so killing the stream's pid kills Node itself.
    /// The preflight echos make bind-mount failures diagnosable directly in
    /// the in-app startup log.
    static let launchCommand = [
        "echo '=== dsh preflight ==='",
        "cat /etc/velum-dsh-mount 2>&1 || true",
        "ls -ld /opt /opt/dsh /opt/dsh/bin 2>&1 || true",
        "ls -l /opt/dsh/bin 2>&1 || true",
        "stat -c '%a %A %n' /opt/dsh/bin/dsh /opt/dsh/bin/node 2>&1 || true",
        "test -r /opt/dsh/bin/dsh; echo test_read=$?",
        "test -x /opt/dsh/bin/dsh; echo test_exec=$?",
        "readlink /opt/dsh 2>&1 || true",
        "echo '=== dsh launch ==='",
        "/opt/dsh/bin/dsh web --host 127.0.0.1 --port 3080 > /tmp/dsh.log 2>&1; _dsh_status=$?; echo \"=== dsh exited: $_dsh_status ===\"; cat /tmp/dsh.log 2>/dev/null; exit $_dsh_status",
    ].joined(separator: "; ")

    @Published var phase: DshAgentPhase = .starting
    @Published var logLines: [String] = []
    @Published var showWebLog = false
    @Published var webViewEpoch = 0

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
        webViewEpoch += 1
        start()
    }

    /// iOS suspends WebKit's network process while the app is backgrounded, so
    /// on return the page's fetch/WebSocket connections all fail with "Load
    /// failed". If the guest server is still healthy, reloading the WebView
    /// re-establishes every connection; otherwise restart dsh as well.
    func handleSceneActive() {
        guard phase == .ready else { return }
        Task { [weak self] in
            guard let self else { return }
            if await Self.probeWebServer() {
                appendLog("↻ 应用回到前台：重新加载 WebView")
                webViewEpoch += 1
            } else {
                appendLog("↻ 应用回到前台：dsh 未响应，重启服务")
                retry()
            }
        }
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

            if await Self.probeWebServer() {
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

    func appendLog(_ line: String) {
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
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            DshWebView(model: model)
                .opacity(model.phase == .ready ? 1 : 0)
                .allowsHitTesting(model.phase == .ready)

            if model.phase != .ready {
                statusOverlay
            } else {
                webDiagnosticsOverlay
            }
        }
        .background(Color(.systemBackground))
        .onAppear { model.start() }
        .onDisappear { model.shutdown() }
        .onChange(of: scenePhase) { newPhase in
            if newPhase == .active {
                model.handleSceneActive()
            }
        }
    }

    // MARK: - Ready-state web diagnostics

    private var webDiagnosticsOverlay: some View {
        VStack(alignment: .trailing, spacing: 8) {
            HStack {
                Spacer()
                Button(model.showWebLog ? "隐藏诊断日志" : "诊断日志") {
                    model.showWebLog.toggle()
                }
                .font(.caption.weight(.medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(.thinMaterial, in: Capsule())
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)

            if model.showWebLog, !model.logLines.isEmpty {
                logPanel
                    .frame(maxHeight: 240)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            }
            Spacer()
        }
        .allowsHitTesting(true)
    }

    private var logPanel: some View {
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
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .allowsHitTesting(true)
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

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator: NSObject, WKScriptMessageHandler {
        weak var model: DshAgentModel?
        var lastLoadedEpoch = -1

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard message.name == "dshLog",
                  let body = message.body as? [String: Any],
                  let text = body["msg"] as? String else { return }
            let level = body["level"] as? String ?? "web"
            Task { @MainActor in
                self.model?.appendLog("[web \(level)] \(text)")
            }
        }
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.preferences.javaScriptEnabled = true
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.websiteDataStore = .default()

        // iPadOS 16.6 ships Safari/JavaScriptCore 16.6, which predates
        // AbortSignal.any() and Promise.withResolvers() (Safari 17.4) used by
        // the dsh Web UI and its dynamic client bundles. Inject small
        // spec-compatible shims before any page script runs.
        let userContentController = WKUserContentController()
        let abortedSignalShim = """
        (function () {
          "use strict";
          if (typeof AbortSignal !== "undefined" && typeof AbortSignal.any !== "function") {
            AbortSignal.any = function (signals) {
              const list = Array.from(signals);
              if (list.length === 0) {
                return typeof AbortSignal.abort === "function"
                  ? AbortSignal.abort()
                  : new AbortController().signal;
              }
              const controller = new AbortController();
              for (const signal of list) {
                if (signal.aborted) {
                  controller.abort(signal.reason);
                  break;
                }
                signal.addEventListener("abort", function () {
                  controller.abort(signal.reason);
                }, { once: true });
              }
              return controller.signal;
            };
          }
          if (typeof AbortSignal !== "undefined" && typeof AbortSignal.timeout !== "function") {
            AbortSignal.timeout = function (ms) {
              const controller = new AbortController();
              const id = setTimeout(function () {
                let reason;
                try { reason = new DOMException("signal timed out", "TimeoutError"); }
                catch (_) { reason = new Error("signal timed out"); }
                controller.abort(reason);
              }, ms);
              if (typeof controller.signal.addEventListener === "function") {
                controller.signal.addEventListener("abort", function () { clearTimeout(id); });
              }
              return controller.signal;
            };
          }
          // Safari 17.4 adds Promise.withResolvers(); the dynamic client
          // bundles served by dsh also call it.
          if (typeof Promise.withResolvers !== "function") {
            Promise.withResolvers = function () {
              let resolve, reject;
              const promise = new Promise(function (res, rej) {
                resolve = res;
                reject = rej;
              });
              return { promise, resolve, reject };
            };
          }
        })();
        """
        userContentController.addUserScript(WKUserScript(
            source: abortedSignalShim,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))

        // Pipe WebView-side JS errors, failed fetches, and WebSocket state
        // changes into the in-app diagnostic log. dsh's UI shows only generic
        // "load failed" toasts; this captures the real reason behind them.
        let diagnosticShim = """
        (function () {
          "use strict";
          var MAX = 2500;
          function send(level, msg) {
            try {
              window.webkit.messageHandlers.dshLog.postMessage({ level: level, msg: String(msg).slice(0, MAX) });
            } catch (_) {}
          }
          function describe(value) {
            if (value instanceof Error) return value.stack || (value.name + ": " + value.message);
            try { return JSON.stringify(value); } catch (_) { return String(value); }
          }
          var origError = console.error;
          if (origError) {
            console.error = function () {
              origError.apply(console, arguments);
              var parts = [];
              for (var i = 0; i < arguments.length; i++) parts.push(describe(arguments[i]));
              send("console.error", parts.join(" "));
            };
          }
          var origWarn = console.warn;
          if (origWarn) {
            console.warn = function () {
              origWarn.apply(console, arguments);
              var parts = [];
              for (var i = 0; i < arguments.length; i++) parts.push(describe(arguments[i]));
              send("console.warn", parts.join(" "));
            };
          }
          window.addEventListener("error", function (event) {
            send("window.onerror", (event.message || "") + " @ " + (event.filename || "") + ":" + (event.lineno || 0));
          });
          window.addEventListener("unhandledrejection", function (event) {
            send("unhandledrejection", describe(event.reason));
          });
          var origFetch = window.fetch;
          if (origFetch) {
            window.fetch = function () {
              var callArgs = arguments;
              var input = callArgs[0];
              var url = typeof input === "string" ? input : (input && input.url ? input.url : String(input));
              var started = Date.now();
              return origFetch.apply(this, callArgs).then(function (response) {
                if (!response.ok) send("fetch", url + " -> HTTP " + response.status + " (" + (Date.now() - started) + "ms)");
                return response;
              }, function (error) {
                send("fetch-error", url + " :: " + describe(error));
                throw error;
              });
            };
          }
          var OrigWebSocket = window.WebSocket;
          if (OrigWebSocket) {
            window.WebSocket = function (url, protocols) {
              var socket = protocols === undefined ? new OrigWebSocket(url) : new OrigWebSocket(url, protocols);
              send("ws", "new " + url);
              socket.addEventListener("open", function () { send("ws", "OPEN " + url); });
              socket.addEventListener("close", function (event) { send("ws", "CLOSE " + url + " code=" + event.code); });
              socket.addEventListener("error", function () { send("ws", "ERROR " + url); });
              return socket;
            };
            window.WebSocket.prototype = OrigWebSocket.prototype;
            try { Object.setPrototypeOf(window.WebSocket, OrigWebSocket); }
            catch (_) {
              window.WebSocket.CONNECTING = OrigWebSocket.CONNECTING;
              window.WebSocket.OPEN = OrigWebSocket.OPEN;
              window.WebSocket.CLOSING = OrigWebSocket.CLOSING;
              window.WebSocket.CLOSED = OrigWebSocket.CLOSED;
            }
          }
          send("boot", "diagnostics installed; origin=" + location.origin + "; ua=" + navigator.userAgent + "; AbortSignal.any=" + (typeof AbortSignal.any) + "; AbortSignal.timeout=" + (typeof AbortSignal.timeout) + "; Promise.withResolvers=" + (typeof Promise.withResolvers));
        })();
        """
        userContentController.addUserScript(WKUserScript(
            source: diagnosticShim,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))
        userContentController.add(context.coordinator, name: "dshLog")
        context.coordinator.model = model
        configuration.userContentController = userContentController

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isOpaque = true
        webView.allowsBackForwardNavigationGestures = true
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        guard model.phase == .ready else { return }
        if webView.url == nil {
            webView.load(URLRequest(url: DshAgentModel.webURL))
        } else if context.coordinator.lastLoadedEpoch != model.webViewEpoch {
            webView.reload()
        }
        context.coordinator.lastLoadedEpoch = model.webViewEpoch
    }
}
