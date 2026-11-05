// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import Foundation
import Localization
import Metrics
import SwiftUI
import Testing
@testable import XStatsUI

@MainActor
struct DNSBenchmarkControllerTests {
  @Test func cancellingRetainsPartialResultsAndRejectsLateProgress() async throws {
    let gate = DNSBenchmarkRunGate()
    let controller = DNSBenchmarkController(
      environmentReader: { ProxyEnvironment(dnsServers: ["192.0.2.53"]) },
      run: { targets, _, progress in
        var result = DNSBenchmarkResult(target: targets[0])
        result.record(.success(.init(milliseconds: 10, addresses: ["192.0.2.1"])))
        progress([result], 1, 10)
        await gate.wait()
        progress([result], 10, 10)
        return [result]
      })
    #expect(controller.phase == .idle)
    controller.start()
    let task = try #require(controller.task)
    await gate.waitUntilStarted()
    while controller.completedQueries == 0 { await Task.yield() }
    controller.cancel()
    #expect(controller.phase == .cancelled)
    #expect(controller.results.count == 1)
    await gate.release()
    await task.value
    #expect(controller.phase == .cancelled)
    #expect(controller.completedQueries == 1)
    #expect(controller.completedAt == nil)
    #expect(controller.task == nil)
  }

  @Test func validatesCustomServersBeforeStartingAndDoesNotDuplicateThem() {
    let controller = DNSBenchmarkController()
    controller.customInput = "bad input"
    controller.addCustomTarget()
    #expect(controller.customTargets.isEmpty)
    #expect(controller.customError)
    controller.customInput = "192.0.2.53"
    controller.addCustomTarget()
    controller.customInput = "192.0.2.53"
    controller.addCustomTarget()
    #expect(controller.customTargets.count == 1)
    #expect(!controller.customError)
  }

  @Test(arguments: [false, true])
  func idleAndPopulatedViewsFitNarrowAndRightToLeftLayoutsWithoutStartingTests(plainOnly: Bool)
    async throws
  {
    var reads = 0
    let fixtures = DNSBenchmarkProtocol.allCases.flatMap { transport in
      DNSBenchmarkTarget.defaults(transport: transport, systemServers: ["119.29.29.29"]).map {
        target in
        var result = DNSBenchmarkResult(target: target)
        if plainOnly, transport == .doh || transport == .dot {
          result.record(.failure(.timeout))
          return result
        }
        result.recordFirstQuery(milliseconds: 95)
        result.record(
          .success(
            .init(
              milliseconds: target.name == "AliDNS" ? 12.3 : 28.5,
              handshakeMilliseconds: transport == .udp ? nil : 35, addresses: ["192.0.2.1"])))
        return result
      }
    }
    let controller = DNSBenchmarkController(
      environmentReader: {
        reads += 1
        return ProxyEnvironment()
      }, run: { _, _, _ in fixtures })
    for populated in [false, true] {
      if populated {
        controller.start()
        await controller.task?.value
        #expect(controller.plainRecommendation != nil)
        #expect((controller.recommendation == nil) == plainOnly)
      }
      for language in [AppLanguage.chinese, .english, .german, .arabic] {
        let direction: LayoutDirection = language.isRightToLeft ? .rightToLeft : .leftToRight
        let size = NSSize(width: 640, height: 640)
        let host = NSHostingView(
          rootView: DNSBenchmarkWindowView(controller: controller)
            .environment(\.isSnapshot, true)
            .environment(\.locale, L10n.locale(for: language))
            .environment(\.layoutDirection, direction)
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .background(DS.Palette.background))
        let window = NSWindow(
          contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless,
          backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        host.appearance = NSAppearance(named: .aqua)
        host.layoutSubtreeIfNeeded()
        #expect(host.fittingSize.width <= size.width, "\(language), populated: \(populated)")
        if let directory = ProcessInfo.processInfo.environment["XSTATS_DNS_PREVIEW_DIR"] {
          let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
          host.cacheDisplay(in: host.bounds, to: bitmap)
          let state = populated ? (plainOnly ? "plain-results" : "results") : "idle"
          let name = "dns-\(state)-\(language.rawValue).png"
          try bitmap.representation(using: .png, properties: [:])?.write(
            to: URL(fileURLWithPath: directory).appendingPathComponent(name))
        }
      }
    }
    #expect(reads == 1)
    #expect(controller.task == nil)
  }

  @Test func customTargetsAreIncludedWhenSystemResolverListIsLong() async throws {
    let controller = DNSBenchmarkController(
      environmentReader: {
        ProxyEnvironment(dnsServers: (1...8).map { "192.0.2.\($0)" })
      },
      run: { targets, _, _ in
        #expect(targets.count <= 64)
        #expect(Set(targets.map(\.transport)) == Set(DNSBenchmarkProtocol.allCases))
        #expect(targets.contains { $0.isSystem })
        #expect(targets.contains { $0.name == "Cloudflare" })
        for index in 1...8 {
          #expect(targets.contains { $0.host == "198.51.100.\(index)" })
        }
        return []
      })
    for index in 1...8 {
      controller.customInput = "198.51.100.\(index)"
      controller.addCustomTarget()
    }
    controller.start()
    await controller.task?.value
    #expect(controller.phase == .complete)
  }

  @Test func groupsSystemAndPublicProtocolsAndRanksOnlyTheSelectedProtocol() async throws {
    let controller = DNSBenchmarkController(
      environmentReader: { ProxyEnvironment(dnsServers: ["119.29.29.29"]) },
      run: { targets, _, _ in
        targets.map { target in
          var result = DNSBenchmarkResult(target: target)
          let fastest = target.transport == .doh ? "AliDNS" : "DNSPod"
          result.record(.success(.init(milliseconds: target.name == fastest ? 10 : 30)))
          return result
        }
      })
    controller.start()
    await controller.task?.value
    let provider = try #require(controller.providers.first { $0.name == "DNSPod" })
    #expect(provider.results.count == 4)
    #expect(provider.isSystem)
    #expect(controller.recommendation?.target.name == "AliDNS")
    #expect(controller.plainRecommendation?.target.name == "DNSPod")
    controller.rankingTransport = .dot
    #expect(controller.recommendation?.target.name == "DNSPod")
    let plainOnly = try #require(controller.providers.first { $0.name == "114DNS" })
    #expect(plainOnly.result(for: .doh) == nil)
  }

  @Test func encryptedDNSRequiresAnExplicitSchemeAndUnknownSchemesAreRejected() {
    let controller = DNSBenchmarkController()
    controller.customInput = "dns.google:853"
    controller.addCustomTarget()
    #expect(controller.customTargets.isEmpty)
    #expect(controller.customError)
    controller.customInput = "tls://dns.google:853"
    controller.addCustomTarget()
    let target = controller.customTargets.first
    #expect(target?.transport == .dot)
    #expect(target?.host == "dns.google")
    #expect(target?.port == 853)
    #expect(!controller.customError)
    controller.customInput = "ftp://dns.google"
    controller.addCustomTarget()
    #expect(controller.customTargets.count == 1)
    #expect(controller.customError)
    controller.customInput = "192.0.2.53:5353"
    controller.addCustomTarget()
    #expect(controller.customTargets.last?.transport == .udp)
    #expect(controller.customTargets.last?.port == 5353)
  }

  @Test func customSchemesAreDetectedAndPlainAddressesTestUDPAndTCP() async throws {
    let controller = DNSBenchmarkController(
      environmentReader: { ProxyEnvironment() },
      run: { targets, _, _ in
        let plain = targets.filter { $0.host == "198.51.100.53" }
        #expect(Set(plain.map(\.transport)) == [.udp, .tcp])
        #expect(Set(plain.map(\.providerID)).count == 1)
        let https = targets.filter { $0.host == "dns.example.com" && $0.transport == .doh }
        #expect(https.count == 2)
        #expect(Set(https.map(\.providerID)).count == 2)
        #expect(targets.contains { $0.host == "dns.example.com" && $0.transport == .dot })
        return []
      })
    for input in [
      "198.51.100.53", "tls://dns.example.com",
      "https://dns.example.com/one", "https://dns.example.com/two",
    ] {
      controller.customInput = input
      controller.addCustomTarget()
    }
    #expect(controller.customTargets.count == 4)
    controller.start()
    await controller.task?.value
    #expect(controller.phase == .complete)
  }
}

private actor DNSBenchmarkRunGate {
  private var started = false
  private var startWaiter: CheckedContinuation<Void, Never>?
  private var releaseWaiter: CheckedContinuation<Void, Never>?
  func wait() async {
    started = true
    startWaiter?.resume()
    startWaiter = nil
    await withCheckedContinuation { releaseWaiter = $0 }
  }
  func waitUntilStarted() async {
    if started { return }
    await withCheckedContinuation { startWaiter = $0 }
  }
  func release() {
    releaseWaiter?.resume()
    releaseWaiter = nil
  }
}
