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
            const actual = configuration.iceServers;
            if (actual.length !== 1 || !expected.includes(actual[0].urls)) throw new Error('Unexpected STUN configuration');
            window.seenServers ??= [];
            if (window.seenServers.includes(actual[0].urls)) throw new Error('Duplicate STUN service');
            window.seenServers.push(actual[0].urls);
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
    #expect(result.services.map(\.provider) == WebRTCLeakProbe.Provider.allCases)
    #expect(result.services.allSatisfy { $0.status == .complete })
    #expect(result.services.allSatisfy { $0.candidates.first?.address == "192.0.2.1" })
  }

  @Test func localScriptReturnsDeduplicatedCandidates() async throws {
    let probe = WebRTCLeakProbe(
      script: """
        const send = x => window.webkit.messageHandlers.leakTest.postMessage(x);
        for (const provider of ['Cloudflare','Google','BlackBerry','Twilio']) {
          send({event:'candidate',provider,value:'candidate:a 1 udp 100 192.0.2.1 1234 typ srflx'});
          send({event:'candidate',provider,value:'candidate:a 1 udp 100 192.0.2.1 1234 typ srflx'});
          send({event:'candidate',provider,value:'malformed'});
          send({event:'candidate',provider:'unknown',value:'candidate:a 1 udp 100 192.0.2.2 1234 typ srflx'});
          send({event:'done',provider});
          send({event:'error',provider});
        }
        """)
    let result = try await probe.run()
    #expect(result.services.count == 4)
    #expect(result.services.allSatisfy { $0.status == .complete && $0.candidates.count == 1 })
    #expect(result.services.allSatisfy { $0.candidates.first?.address == "192.0.2.1" })
  }

  @Test func nativeDeadlineStopsSilentWebView() async throws {
    let result = try await WebRTCLeakProbe(script: "void 0", timeout: .milliseconds(200)).run()
    #expect(result.services.count == 4)
    #expect(result.services.allSatisfy { $0.status == .timedOut && $0.candidates.isEmpty })
  }

  @Test func deadlinePreservesCompletedFailedAndPartialServiceResults() async throws {
    let result = try await WebRTCLeakProbe(
      script: """
        const send = x => window.webkit.messageHandlers.leakTest.postMessage(x);
        send({event:'done',provider:'Cloudflare'});
        send({event:'error',provider:'Google'});
        send({event:'candidate',provider:'BlackBerry',value:'candidate:a 1 udp 100 192.0.2.1 1234 typ srflx'});
        void 0;
        """, timeout: .seconds(2)
    ).run()
    #expect(result.services.map(\.status) == [.complete, .failed, .timedOut, .timedOut])
    #expect(result.services[2].candidates.first?.address == "192.0.2.1")
    #expect(result.services[3].candidates.isEmpty)
  }

  @Test func candidateStorageIsBoundedForEveryService() async throws {
    let result = try await WebRTCLeakProbe(
      script: """
        const send = x => window.webkit.messageHandlers.leakTest.postMessage(x);
        for (const provider of ['Cloudflare','Google','BlackBerry','Twilio']) {
          for (let i = 1; i <= 100; i++)
            send({event:'candidate',provider,value:`candidate:a 1 udp 100 192.0.2.${i} 1234 typ srflx`});
          send({event:'done',provider});
        }
        """
    ).run()
    #expect(result.services.allSatisfy { $0.status == .complete && $0.candidates.count == 64 })
  }

  @Test func productionScriptKeepsOtherServicesAfterOneFails() async throws {
    let result = try await WebRTCLeakProbe(
      script: """
        window.RTCPeerConnection = class {
          constructor(configuration) {
            if (configuration.iceServers[0].urls.includes('google')) throw new Error('Unavailable');
          }
          createDataChannel() {}
          createOffer() { return Promise.resolve({}); }
          setLocalDescription() {
            this.onicecandidate({candidate: null});
            return Promise.resolve();
          }
          close() {}
        };
        """ + WebRTCLeakProbe.script
    ).run()
    #expect(result.services.map(\.status) == [.complete, .failed, .complete, .complete])
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
        """
        for (const provider of ['Cloudflare','Google','BlackBerry','Twilio'])
          window.webkit.messageHandlers.leakTest.postMessage({event:'done',provider});
        """
    ).run()
    #expect(next.services.allSatisfy { $0.status == .complete })
  }
}
