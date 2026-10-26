// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import XStatsUI

@MainActor
struct WebRTCLeakProbeTests {
  @Test func productionScriptConfiguresAllSTUNServers() async throws {
    // 拦截构造器验证实际执行的配置，不向公网发送测试请求。
    let probe = WebRTCLeakProbe(
      script: """
        window.RTCPeerConnection = class {
          constructor(configuration) {
            const expected = [
              'stun:stun.cloudflare.com:3478',
              'stun:stun.l.google.com:19302',
              'stun:stun.voip.blackberry.com:3478',
              'stun:global.stun.twilio.com:3478'
            ];
            const actual = configuration.iceServers.map(server => server.urls);
            if (JSON.stringify(actual) !== JSON.stringify(expected)) throw new Error('Unexpected STUN configuration');
          }
          createDataChannel() {}
          createOffer() { return Promise.resolve({}); }
          setLocalDescription() {
            this.onicecandidate({candidate: {candidate: 'candidate:a 1 udp 100 192.0.2.1 1234 typ srflx'}});
            this.onicecandidate({candidate: null});
            return Promise.resolve();
          }
          close() {}
        };
        """ + WebRTCLeakProbe.script)
    let result = try await probe.run()
    #expect(!result.timedOut)
    #expect(result.candidates.first?.address == "192.0.2.1")
  }

  @Test func localScriptReturnsDeduplicatedCandidates() async throws {
    let probe = WebRTCLeakProbe(
      script: """
        const send = x => window.webkit.messageHandlers.leakTest.postMessage(x);
        send({event:'candidate',value:'candidate:a 1 udp 100 192.0.2.1 1234 typ srflx'});
        send({event:'candidate',value:'candidate:a 1 udp 100 192.0.2.1 1234 typ srflx'});
        send({event:'candidate',value:'malformed'});
        send({event:'done'});
        """)
    let result = try await probe.run()
    #expect(!result.timedOut)
    #expect(result.candidates.count == 1)
    #expect(result.candidates.first?.address == "192.0.2.1")
  }

  @Test func nativeDeadlineStopsSilentWebView() async throws {
    let result = try await WebRTCLeakProbe(script: "void 0", timeout: .milliseconds(200)).run()
    #expect(result.timedOut)
    #expect(result.candidates.isEmpty)
  }

  @Test func cancellationReleasesProbeAndDoesNotAffectNextRun() async throws {
    weak var reference: WebRTCLeakProbe?
    let task = Task {
      let probe = WebRTCLeakProbe(script: "void 0")
      reference = probe
      return try await probe.run()
    }
    while reference == nil { await Task.yield() }
    task.cancel()
    do {
      _ = try await task.value
      Issue.record("Expected cancellation")
    } catch { #expect(error is CancellationError) }
    // 取消回调队列消耗后，消息桥不能保持 probe / WebView 引用环。
    for _ in 0..<20 where reference != nil { await Task.yield() }
    #expect(reference == nil)
    let next = try await WebRTCLeakProbe(
      script:
        "window.webkit.messageHandlers.leakTest.postMessage({event:'done'});"
    ).run()
    #expect(!next.timedOut)
  }
}
