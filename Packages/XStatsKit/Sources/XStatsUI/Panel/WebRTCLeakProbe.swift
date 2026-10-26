// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Metrics
import WebKit

/// 每次检测独占一个临时 WebKit 上下文；不加载远端页面，不申请音视频权限。
@MainActor
final class WebRTCLeakProbe: NSObject, WKNavigationDelegate {
  struct Result: Sendable {
    let candidates: [NetworkLeakTest.Candidate]
    let timedOut: Bool
  }

  private var webView: WKWebView?
  private var continuation: CheckedContinuation<Result, any Error>?
  private var deadline: Task<Void, Never>?
  private var candidates: [NetworkLeakTest.Candidate] = []
  private var started = false
  private let probeScript: String
  private let timeout: Duration

  init(script: String = WebRTCLeakProbe.script, timeout: Duration = .seconds(10)) {
    self.probeScript = script
    self.timeout = timeout
    super.init()
  }

  func run() async throws -> Result {
    try Task.checkCancellation()
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        self.continuation = continuation
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(Bridge(owner: self), name: "leakTest")
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = self
        webView = view
        let timeout = self.timeout
        deadline = Task { [weak self] in
          do { try await Task.sleep(for: timeout) } catch { return }
          guard let self else { return }
          self.finish(.success(Result(candidates: self.candidates, timedOut: true)))
        }
        // HTTPS baseURL 只建立安全上下文，HTML 本身由本地提供，不请求 localhost。
        view.loadHTMLString(
          "<!doctype html><meta charset='utf-8'><title>Leak Test</title>",
          baseURL: URL(string: "https://localhost/"))
      }
    } onCancel: {
      Task { @MainActor [weak self] in self?.finish(.failure(CancellationError())) }
    }
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    guard continuation != nil, !started else { return }
    started = true
    webView.evaluateJavaScript(probeScript) { [weak self] _, error in
      if error != nil { self?.finish(.failure(NetworkLeakTest.Failure.unavailable)) }
    }
  }

  func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error)
  {
    finish(.failure(NetworkLeakTest.Failure.unavailable))
  }

  func webView(
    _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
    withError error: any Error
  ) {
    finish(.failure(NetworkLeakTest.Failure.unavailable))
  }

  func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
    finish(.failure(NetworkLeakTest.Failure.unavailable))
  }

  private func receive(_ body: Any) {
    guard continuation != nil, let message = body as? [String: String] else { return }
    switch message["event"] {
    case "candidate":
      if let line = message["value"], let candidate = NetworkLeakTest.candidate(line),
        candidates.count < 64, !candidates.contains(candidate)
      {
        candidates.append(candidate)
      }
    case "done":
      finish(.success(Result(candidates: candidates, timedOut: false)))
    case "error":
      finish(.failure(NetworkLeakTest.Failure.unavailable))
    default: break
    }
  }

  private func finish(_ result: Swift.Result<Result, any Error>) {
    guard let continuation else { return }
    self.continuation = nil
    deadline?.cancel()
    deadline = nil
    if let view = webView {
      // JS 定时器在隐藏页面可能被节流；截止时间由 Swift 管理，关闭连接后丢弃 WebView。
      view.evaluateJavaScript("window.leakPeer?.close(); window.leakPeer = null;")
      view.configuration.userContentController.removeScriptMessageHandler(forName: "leakTest")
      view.navigationDelegate = nil
      view.stopLoading()
    }
    webView = nil
    continuation.resume(with: result)
  }

  private final class Bridge: NSObject, WKScriptMessageHandler {
    weak var owner: WebRTCLeakProbe?
    init(owner: WebRTCLeakProbe) { self.owner = owner }
    func userContentController(
      _ controller: WKUserContentController, didReceive message: WKScriptMessage
    ) {
      guard message.frameInfo.isMainFrame else { return }
      owner?.receive(message.body)
    }
  }

  // 独立实现标准 ICE 收集流程；没有远端脚本、媒体轨道或 getUserMedia 调用。
  static let script = """
    (() => {
      const send = (event, value = '') => window.webkit.messageHandlers.leakTest.postMessage({event, value});
      try {
        const pc = new RTCPeerConnection({iceServers: [
          {urls: 'stun:stun.cloudflare.com:3478'},
          {urls: 'stun:stun.l.google.com:19302'},
          {urls: 'stun:stun.voip.blackberry.com:3478'},
          {urls: 'stun:global.stun.twilio.com:3478'}
        ]});
        window.leakPeer = pc;
        pc.onicecandidate = event => {
          if (event.candidate) send('candidate', event.candidate.candidate);
          else { pc.close(); send('done'); }
        };
        pc.createDataChannel('leak-test');
        pc.createOffer().then(offer => {
          if (pc.signalingState !== 'closed') return pc.setLocalDescription(offer);
        }).catch(() => { pc.close(); send('error'); });
      } catch (_) { send('error'); }
    })()
    """
}
