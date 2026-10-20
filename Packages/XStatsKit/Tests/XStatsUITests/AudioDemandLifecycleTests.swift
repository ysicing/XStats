// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation
import Testing
@testable import AudioControl
@testable import XStatsUI

private final class DemandLog: @unchecked Sendable {
  private let lock = NSLock()
  private var items: [String] = []
  private var activityReads = 0
  func append(_ item: String) { lock.withLock { items.append(item) } }
  var entries: [String] { lock.withLock { items } }
  func readActivity() -> [UInt32] {
    lock.withLock { activityReads += 1 }
    return []
  }
  var activityReadCount: Int { lock.withLock { activityReads } }
}

private final class DemandPipeline: AudioMixPipeline, @unchecked Sendable {
  let processIDs: [UInt32]
  let outputUID: String
  let id: String
  let log: DemandLog
  var frameCount: UInt64 { 1 }
  var isOutputPresent: Bool { true }
  init(_ target: AudioMixTarget, output: String, log: DemandLog) {
    id = target.id
    processIDs = target.processObjectIDs
    outputUID = output
    self.log = log
  }
  func matches(_ target: AudioMixTarget, outputUID: String, sourceUID: String?) -> Bool {
    target.id == id && target.processObjectIDs == processIDs && self.outputUID == outputUID
  }
  func start(shouldContinue: () -> Bool) throws { log.append("start:\(id)") }
  func setVolume(_ volume: Float) {}
  func stop() throws { log.append("stop:\(id)") }
}

@MainActor
struct AudioDemandLifecycleTests {
  private func makeDefaults(appVolume: Bool) throws -> (UserDefaults, String) {
    let suite = "XStats.AudioDemandLifecycleTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defaults.set(appVolume, forKey: "audio.appVolumeEnabled")
    return (defaults, suite)
  }

  private func makeController(
    _ defaults: UserDefaults, log: DemandLog,
    mixer: AudioMixerClient = AudioMixerClient(automaticHealthChecks: false) { _, _, _ in
      throw AudioControlError.unavailable
    }
  )
    -> (AudioController, AudioHardwareClient)
  {
    let hardware = AudioHardwareClient(
      selectDevice: { _, _, _ in .unsupported }, applicationActivity: { log.readActivity() })
    // 蓝牙目录使用空替身，避免读取真实系统目录。
    let bluetooth = BluetoothAudioClient(readPaired: { [] }, connect: { _ in }, devices: { [] })
    return (
      AudioController(defaults: defaults, mixer: mixer, hardware: hardware, bluetooth: bluetooth),
      hardware
    )
  }

  @Test(arguments: [false, true])
  func visibleControlsWatchApplicationsOnlyAfterAppVolumeIsEnabled(appVolume: Bool) async throws {
    let (defaults, suite) = try makeDefaults(appVolume: appVolume)
    defer { defaults.removePersistentDomain(forName: suite) }
    let log = DemandLog()
    let (controller, hardware) = makeController(defaults, log: log)
    defer { controller.stop() }
    controller.setDemand(enabled: true, visible: true, menuVisible: false)
    _ = await hardware.listenerCount()  // 串行屏障，等待 watch 完成初始化。
    #expect((log.activityReadCount > 0) == appVolume, "未开启应用音量时界面只有授权入口，不应读取进程播放状态")
  }

  @Test func inactivityDropsVisibleDemandAndRestoresItAfterwards() async throws {
    let (defaults, suite) = try makeDefaults(appVolume: false)
    defer { defaults.removePersistentDomain(forName: suite) }
    let (controller, hardware) = makeController(defaults, log: DemandLog())
    defer { controller.stop() }
    controller.setDemand(enabled: true, visible: true, menuVisible: true)
    #expect(await hardware.listenerCount() > 0)
    controller.setPaused(true)
    #expect(await hardware.listenerCount() == 0, "锁屏期间不可见界面不应保留设备监听")
    // 暂停期间界面需求变化只记录，不重新注册监听。
    controller.setDemand(enabled: true, visible: true, menuVisible: false)
    #expect(await hardware.listenerCount() == 0)
    controller.setPaused(false)
    #expect(await hardware.listenerCount() > 0, "恢复后按最新界面需求重新监听")
  }

  @Test func appVolumePersistenceIsDeferredAndFlushedOnStop() async throws {
    let (defaults, suite) = try makeDefaults(appVolume: true)
    defer { defaults.removePersistentDomain(forName: suite) }
    let (controller, _) = makeController(defaults, log: DemandLog())
    let app = AudioApplication(
      id: "test.player", name: "Player", processObjectIDs: [1], isPlaying: false)
    controller.showPreview(
      AudioHardwareSnapshot(devices: [], outputID: nil, inputID: nil, applications: [app]),
      volumes: [:], outputs: [:])
    controller.setDemand(enabled: true, visible: false, menuVisible: false)
    guard controller.supportsMixing else {
      controller.stop()
      return
    }
    for level in stride(from: 0.9, through: 0.5, by: -0.1) {
      controller.setAppLevel(level, app: app)
    }
    #expect(controller.volumes[app.id]?.level == 0.5, "内存状态立即更新，供混音器使用")
    #expect(defaults.data(forKey: "audio.applicationVolumes") == nil, "拖动过程中不逐次编码写入偏好")
    controller.stop()
    let data = try #require(defaults.data(forKey: "audio.applicationVolumes"), "停止时必须写入尚未保存的音量")
    let saved = try JSONDecoder().decode([String: AudioAppVolume].self, from: data)
    #expect(saved[app.id]?.level == 0.5)
  }

  @Test func losingCapturePermissionTearsDownPipelinesThatStillWork() async throws {
    let (defaults, suite) = try makeDefaults(appVolume: true)
    defer { defaults.removePersistentDomain(forName: suite) }
    let log = DemandLog()
    let mixer = AudioMixerClient(automaticHealthChecks: false) { target, output, _ in
      if target.id == "denied" { throw AudioControlError.permissionRequired }
      return DemandPipeline(target, output: output, log: log)
    }
    let (controller, _) = makeController(defaults, log: log, mixer: mixer)
    defer { controller.stop() }
    guard controller.supportsMixing else { return }
    let output = AudioDeviceInfo(id: 1, uid: "test.output", name: "Output", hasOutput: true)
    let working = AudioApplication(
      id: "working", name: "Working", processObjectIDs: [11], isPlaying: true)
    let denied = AudioApplication(
      id: "denied", name: "Denied", processObjectIDs: [12], isPlaying: true)
    controller.showPreview(
      AudioHardwareSnapshot(
        devices: [output], outputID: 1, inputID: nil, applications: [working, denied]),
      volumes: [:], outputs: [:])
    // 无已保存调整且菜单不可见：不启动真实 HAL 监听，快照保持为夹具数据。
    controller.setDemand(enabled: true, visible: false, menuVisible: false)
    controller.setAppLevel(0.5, app: working)
    try await waitUntil { log.entries.contains("start:working") }
    controller.setAppLevel(0.5, app: denied)
    try await waitUntil { !controller.appVolumeEnabled && log.entries.contains("stop:working") }
    #expect(!defaults.bool(forKey: "audio.appVolumeEnabled"))
    try await Task.sleep(for: .milliseconds(100))
    #expect(controller.error == .permissionRequired, "空需求收尾后仍需提示用户去系统设置授权")
  }

  @Test func disablingAppVolumeStopsProcessingAndRetainsAdjustments() async throws {
    let (defaults, suite) = try makeDefaults(appVolume: true)
    defer { defaults.removePersistentDomain(forName: suite) }
    let log = DemandLog()
    let mixer = AudioMixerClient(automaticHealthChecks: false) { target, output, _ in
      DemandPipeline(target, output: output, log: log)
    }
    let (controller, hardware) = makeController(defaults, log: log, mixer: mixer)
    defer { controller.stop() }
    guard controller.supportsMixing else { return }
    let output = AudioDeviceInfo(id: 1, uid: "test.output", name: "Output", hasOutput: true)
    let app = AudioApplication(
      id: "test.player", name: "Player", processObjectIDs: [11], isPlaying: true)
    controller.showPreview(
      AudioHardwareSnapshot(
        devices: [output], outputID: 1, inputID: nil, applications: [app]),
      volumes: [:], outputs: [:])
    controller.setDemand(enabled: true, visible: false, menuVisible: false)
    controller.setAppLevel(0.5, app: app)
    try await waitUntil { log.entries.contains("start:\(app.id)") }
    controller.disableMixing()
    try await waitUntil { log.entries.contains("stop:\(app.id)") }
    #expect(!controller.appVolumeEnabled)
    #expect(!defaults.bool(forKey: "audio.appVolumeEnabled"))
    #expect(await hardware.listenerCount() == 0, "隐藏界面关闭应用处理后不再保留设备或应用监听")
    #expect(controller.volume(for: app).level == 0.5)
    let saved = try JSONDecoder().decode(
      [String: AudioAppVolume].self,
      from: try #require(defaults.data(forKey: "audio.applicationVolumes")))
    #expect(saved[app.id]?.level == 0.5, "关闭时立即保存尚未落盘的调整")
    let restored = AudioController(defaults: defaults)
    defer { restored.stop() }
    #expect(!restored.appVolumeEnabled)
    #expect(restored.volume(for: app).level == 0.5)
    controller.setDemand(enabled: true, visible: true, menuVisible: false)
    #expect(await hardware.listenerCount() > 0, "系统音量与设备选择仍有独立监听需求")
    #expect(log.activityReadCount == 0, "只显示系统控件不再采集应用播放状态")
  }

  @Test func disablingAppVolumeRetainsRoutesAndClearsPendingApplicationFeedback() async throws {
    let (defaults, suite) = try makeDefaults(appVolume: true)
    defer { defaults.removePersistentDomain(forName: suite) }
    let (controller, _) = makeController(defaults, log: DemandLog())
    defer { controller.stop() }
    let output = AudioDeviceInfo(id: 1, uid: "test.output", name: "Output", hasOutput: true)
    let app = AudioApplication(
      id: "test.player", name: "Player", processObjectIDs: [11], isPlaying: true)
    controller.showPreview(
      AudioHardwareSnapshot(
        devices: [output], outputID: 1, inputID: nil, applications: [app]),
      volumes: [:], outputs: [:])
    controller.setDemand(enabled: true, visible: false, menuVisible: false)
    controller.setAppOutput(output.uid, app: app)
    try #require(controller.pendingOutputApps.contains(app.id))
    controller.disableMixing()
    #expect(controller.pendingOutputApps.isEmpty)
    #expect(controller.failedOutputApps.isEmpty)
    #expect(controller.unresolvedApps.isEmpty)
    #expect(controller.outputRoutes[app.id] == output.uid)
    let restored = AudioController(defaults: defaults)
    defer { restored.stop() }
    #expect(!restored.appVolumeEnabled)
    #expect(restored.outputRoutes[app.id] == output.uid)
  }

  private func waitUntil(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(120)
    while !condition(), ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    try #require(condition())
  }
}
