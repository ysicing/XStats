// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import Foundation
import Testing
import Cleaner
@testable import XStatsUI

private final class VolumeReadProbe: @unchecked Sendable {
  private let lock = NSLock()
  private var reads = 0
  private var running = 0
  private var peak = 0
  var counts: (reads: Int, running: Int, peak: Int) { lock.withLock { (reads, running, peak) } }
  func read() {
    lock.withLock {
      reads += 1
      running += 1
      peak = max(peak, running)
    }
    let deadline = Date().addingTimeInterval(10)
    while !Task.isCancelled, Date() < deadline { Thread.sleep(forTimeInterval: 0.005) }
    lock.withLock { running -= 1 }
  }
}

@MainActor
struct DiskVolumeDemandTests {
  @Test func volumeReadsCancelOnHideAndPauseAndCoalesceMountEvents() async throws {
    let probe = VolumeReadProbe()
    let staleVolume = MountedVolume(
      url: URL(fileURLWithPath: "/Volumes/Stale"), name: "Stale",
      total: 100, available: 50, isInternal: false, isRemovable: true, isEjectable: true,
      isLocal: true)
    let controller = DiskToolsController(
      helper: HelperClient(),
      readVolumes: {
        probe.read()
        return [staleVolume]
      })
    defer { controller.setVolumesVisible(false) }
    controller.refreshVolumes()
    #expect(probe.counts.reads == 0)
    controller.setVolumesVisible(true)
    for _ in 0..<1000 where probe.counts.running == 0 {
      try await Task.sleep(for: .milliseconds(5))
    }
    #expect(probe.counts.reads == 1)
    controller.setVolumesVisible(true)
    for _ in 0..<10 {
      NSWorkspace.shared.notificationCenter.post(
        name: NSWorkspace.didMountNotification, object: nil)
    }
    #expect(probe.counts.reads == 1)
    controller.setVolumesVisible(false)
    controller.setVolumesVisible(true)
    for _ in 0..<1000 where probe.counts.reads < 2 { try await Task.sleep(for: .milliseconds(5)) }
    #expect(probe.counts.reads == 2 && probe.counts.peak == 1)
    controller.setPaused(true)
    for _ in 0..<1000 where probe.counts.running != 0 {
      try await Task.sleep(for: .milliseconds(5))
    }
    let pausedReads = probe.counts.reads
    NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didMountNotification, object: nil)
    #expect(probe.counts.running == 0 && probe.counts.reads == pausedReads)
    controller.setPaused(false)
    for _ in 0..<1000 where probe.counts.reads == pausedReads {
      try await Task.sleep(for: .milliseconds(5))
    }
    #expect(probe.counts.reads == pausedReads + 1)
    controller.setVolumesVisible(false)
    for _ in 0..<1000 where probe.counts.running != 0 {
      try await Task.sleep(for: .milliseconds(5))
    }
    #expect(probe.counts.running == 0 && probe.counts.peak == 1)
    // 已取消的底层读取即使仍返回卷信息，也不能重新发布旧挂载项。
    #expect(controller.volumes.isEmpty)
  }
}
