// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import NetworkObservation
import SwiftUI
import Testing
@testable import XStatsUI

@MainActor
struct NetworkTrafficPreviewTests {
  private let start = Date(timeIntervalSince1970: 100)

  private func record(_ name: String, address: String) -> ObservedConnection {
    ObservedConnection(
      id: UUID(), timestamp: start, processID: 42,
      executablePath: "/Applications/\(name).app/Contents/MacOS/\(name)",
      address: address, hostname: "example.invalid", port: 443,
      transport: .tcp, direction: .outbound)
  }

  private func point(_ seconds: Double, received: Double?, sent: Double?) -> NetworkTrafficPoint {
    NetworkTrafficPoint(
      date: start.addingTimeInterval(seconds),
      receivedBytesPerSecond: received, sentBytesPerSecond: sent, segment: 0)
  }

  @Test func previewFiltersApplicationsAndAddressesAndUsesTheSameTimeWindow() {
    let controller = NetworkMonitorController(isSupported: false)
    let browser = record("Browser", address: "192.0.2.1")
    let editor = record("Editor", address: "198.51.100.1")
    let browserPoints = [
      point(5, received: 1000, sent: 100),
      point(10, received: nil, sent: nil),
      point(15, received: 2000, sent: nil),
    ]
    controller.showPreview(
      [browser, editor],
      traffic: [
        browser.id: browserPoints,
        editor.id: [point(5, received: 3000, sent: 300), point(15, received: 4000, sent: 400)],
      ])
    let all = controller.previewTrafficPoints(interval: 60, matching: { _ in true })
    #expect(all.map(\.date) == [5.0, 10, 15].map { start.addingTimeInterval($0) })
    #expect(all.map(\.receivedBytesPerSecond) == [4000, nil, 6000])
    #expect(all.map(\.sentBytesPerSecond) == [400, nil, 400])
    let appFilter = NetworkConnectionFilter(
      grouping: .apps, selection: browser.applicationGroupKey, query: "", countries: [:])
    let app = controller.previewTrafficPoints(interval: 60, matching: appFilter.matches)
    #expect(app.map(\.receivedBytesPerSecond) == browserPoints.map(\.receivedBytesPerSecond))
    #expect(
      Set(
        NetworkTrafficChartSample.make(points: app).filter { $0.direction == .received }
          .map(\.series)
      ).count == 2)
    let addressFilter = NetworkConnectionFilter(
      grouping: .domain, selection: "example.invalid", query: "192.0.2.1", countries: [:])
    let address = controller.previewTrafficPoints(interval: 10, matching: addressFilter.matches)
    #expect(address.map(\.date) == [10.0, 15].map { start.addingTimeInterval($0) })
    #expect(address.map(\.receivedBytesPerSecond) == [nil, 2000])
    #expect(controller.trafficAvailable)
    #expect(!controller.isReading)
    #expect(!controller.historyEnabled)
  }

  @Test func replacingOrClearingPreviewDoesNotRetainRemovedConnections() {
    let controller = NetworkMonitorController(isSupported: false)
    let first = record("Browser", address: "192.0.2.1")
    let second = record("Editor", address: "198.51.100.1")
    let traffic = [
      first.id: [point(5, received: 1000, sent: 100)],
      second.id: [point(15, received: 2000, sent: 200)],
    ]
    controller.showPreview([first, second], traffic: traffic)
    controller.showPreview([first], traffic: traffic)
    let remaining = controller.previewTrafficPoints(interval: 60, matching: { _ in true })
    #expect(remaining.map(\.date) == [start.addingTimeInterval(5)])
    #expect(remaining.map(\.receivedBytesPerSecond) == [1000])
    #expect(controller.previewTrafficPoints(interval: 60, matching: { _ in false }).isEmpty)
    controller.showPreview([first])
    #expect(!controller.trafficAvailable)
    #expect(controller.previewTrafficPoints(interval: 60, matching: { _ in true }).isEmpty)
    controller.showPreview([first], traffic: traffic)
    controller.setDemand(enabled: false, visible: false)
    #expect(controller.records.isEmpty)
    #expect(controller.previewTrafficPoints(interval: 60, matching: { _ in true }).isEmpty)
  }

  @Test func previewChartsRenderWithDataAndWithoutData() throws {
    _ = NSApplication.shared
    let controller = NetworkMonitorController(isSupported: false)
    let browser = record("Browser", address: "192.0.2.1")
    let curve: [NetworkTrafficPoint] = (1...12).map { index in
      let value = Double(index)
      return point(value * 5, received: value * 1000, sent: value * 200)
    }
    controller.showPreview([browser], traffic: [browser.id: curve])
    let points = controller.previewTrafficPoints(interval: 60, matching: { _ in true })
    let output = ProcessInfo.processInfo.environment["XSTATS_NETWORK_PREVIEW_DIR"]
      .map { URL(fileURLWithPath: $0, isDirectory: true) }
    if let output {
      try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    }
    for (name, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
      let appearance = try #require(NSAppearance(named: name))
      let host = NSHostingView(
        rootView: VStack(spacing: 20) {
          NetworkTrafficChart(
            points: points, samples: NetworkTrafficChartSample.make(points: points),
            available: controller.trafficAvailable, interval: 60)
          NetworkTrafficChart(
            points: [], samples: [], available: true, interval: 60)
        }.padding(20).frame(width: 600).background(DS.Palette.background))
      let size = host.fittingSize
      let window = NSWindow(
        contentRect: NSRect(origin: .zero, size: size),
        styleMask: .borderless, backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      window.appearance = appearance
      window.contentView = host
      defer { window.close() }
      host.frame = NSRect(origin: .zero, size: size)
      host.layoutSubtreeIfNeeded()
      let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
      host.cacheDisplay(in: host.bounds, to: bitmap)
      #expect(bitmap.pixelsWide > 0 && bitmap.pixelsHigh > 0)
      if let output {
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: output.appendingPathComponent("traffic-\(suffix).png"))
      }
    }
  }
}
