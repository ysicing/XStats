// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import CoreAudio
import Foundation
import os

public enum AudioListeningMode: UInt32, Sendable, CaseIterable {
  case off = 1
  case noiseCancellation = 2
  case transparency = 3
  case adaptive = 4

  /// 未文档化的 HAL 支持位只定义了这三种目标；关闭状态可读，但不猜测其可写能力。
  public static func supported(by mask: UInt32) -> [Self] {
    [.noiseCancellation, .transparency, .adaptive].filter {
      mask & (1 << ($0.rawValue - 2)) != 0
    }
  }
}

public struct AudioListeningModeState: Equatable, Sendable {
  public let modes: [AudioListeningMode]
  public let current: AudioListeningMode?
  public let canSet: Bool
  public var isControllable: Bool { canSet && modes.count >= 2 }

  public init(modes: [AudioListeningMode], current: AudioListeningMode?, canSet: Bool) {
    self.modes = modes
    self.current = current
    self.canSet = canSet
  }
}

/// 仅在音频控件可见时监听当前蓝牙输出。HAL 状态和监听器限定在串行队列，确认期间不阻塞队列。
public final class AudioListeningModeClient: @unchecked Sendable {
  private static let logger = Logger(subsystem: "work.12306.xstats", category: "AudioListeningMode")
  static let modeProperty: UInt32 = 0x6C73_746D  // 'lstm'，未文档化，必须先探测。
  static let supportProperty: UInt32 = 0x6C73_6D73  // 'lsms'
  private let queue = DispatchQueue(label: "work.12306.xstats.audio.listening-mode")
  private let queueKey = DispatchSpecificKey<UInt8>()
  private let read: @Sendable (AudioDeviceInfo) -> AudioListeningModeState?
  private let write: @Sendable (AudioDeviceInfo, AudioListeningMode) throws -> Void
  private let add:
    @Sendable (UInt32, UInt32, DispatchQueue, @escaping AudioObjectPropertyListenerBlock) -> Bool
  private let remove:
    @Sendable (UInt32, UInt32, DispatchQueue, @escaping AudioObjectPropertyListenerBlock) -> Void
  private let confirmationDelay: Duration
  private var device: AudioDeviceInfo?
  private var listeners: [(UInt32, AudioObjectPropertyListenerBlock)] = []
  private var callback: (@Sendable () -> Void)?

  public convenience init() {
    self.init(read: Self.readState, write: Self.writeMode)
  }

  init(
    read: @escaping @Sendable (AudioDeviceInfo) -> AudioListeningModeState?,
    write: @escaping @Sendable (AudioDeviceInfo, AudioListeningMode) throws -> Void,
    confirmationDelay: Duration = .milliseconds(100),
    add:
      @escaping @Sendable (
        UInt32, UInt32, DispatchQueue, @escaping AudioObjectPropertyListenerBlock
      ) -> Bool = AudioListeningModeClient.addListener,
    remove:
      @escaping @Sendable (
        UInt32, UInt32, DispatchQueue, @escaping AudioObjectPropertyListenerBlock
      ) -> Void = AudioListeningModeClient.removeListener
  ) {
    self.read = read
    self.write = write
    self.confirmationDelay = confirmationDelay
    self.add = add
    self.remove = remove
    queue.setSpecific(key: queueKey, value: 1)
  }

  deinit {
    if DispatchQueue.getSpecific(key: queueKey) != nil { clear() } else { queue.sync { clear() } }
  }

  public func watch(_ device: AudioDeviceInfo?, onChange: @escaping @Sendable () -> Void) async
    -> AudioListeningModeState?
  {
    await execute { [self] in
      guard let device, device.hasOutput, device.bluetoothAddress != nil else {
        clear()
        return nil
      }
      let state = read(device)
      if self.device?.id != device.id || self.device?.uid != device.uid || state == nil {
        clear()
      }
      guard let state else { return nil }
      callback = onChange
      if self.device == nil {
        self.device = device
        for selector in [Self.modeProperty, Self.supportProperty] {
          let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.callback?() }
          if add(device.id, selector, queue, listener) { listeners.append((selector, listener)) }
        }
        Self.logger.debug("聆听模式监听已启用")
      }
      return state
    }
  }

  public func stopWatching() {
    queue.async { [self] in clear() }
  }

  public func setMode(_ mode: AudioListeningMode, device: AudioDeviceInfo) async throws {
    let cancellation = AudioOperationCancellation()
    do {
      try await withTaskCancellationHandler {
        try Task.checkCancellation()
        let result: Result<Void, AudioControlError> = await execute { [self] in
          guard !cancellation.isCancelled else { return .failure(.routeChanged) }
          guard let state = read(device) else { return .failure(.routeChanged) }
          guard device.hasOutput, device.bluetoothAddress != nil,
            state.isControllable, state.modes.contains(mode), mode != .off
          else { return .failure(.unsupported) }
          if state.current == mode { return .success(()) }
          guard !cancellation.isCancelled else { return .failure(.routeChanged) }
          do {
            Self.logger.info("聆听模式切换已请求")
            try write(device, mode)
            return .success(())
          } catch { return .failure(error as? AudioControlError ?? .unavailable) }
        }
        try Task.checkCancellation()
        try result.get()
        // 系统接受写入不代表耳机已切换；延迟回读，最多确认八次，不重复发送写入。
        for _ in 0..<8 {
          try await Task.sleep(for: confirmationDelay)
          let state = await execute { [read] in read(device) }
          try Task.checkCancellation()
          guard let state else { throw AudioControlError.routeChanged }
          if state.current == mode {
            Self.logger.info("聆听模式切换已回读确认")
            return
          }
        }
        throw AudioControlError.listeningModeUnconfirmed
      } onCancel: {
        cancellation.cancel()
      }
    } catch is CancellationError {
      Self.logger.info("聆听模式切换已取消")
      throw CancellationError()
    } catch {
      Self.logger.error("聆听模式切换未完成")
      throw error
    }
  }

  func listenerCount() async -> Int { await execute { [self] in listeners.count } }

  private func execute<Value: Sendable>(_ operation: @escaping @Sendable () -> Value) async -> Value
  {
    await withCheckedContinuation { continuation in
      queue.async { continuation.resume(returning: operation()) }
    }
  }

  private func clear() {
    if let device {
      for (selector, listener) in listeners { remove(device.id, selector, queue, listener) }
      Self.logger.debug("聆听模式监听已停止")
    }
    listeners.removeAll()
    device = nil
    callback = nil
  }

  private static func readState(_ device: AudioDeviceInfo) -> AudioListeningModeState? {
    guard device.hasOutput, device.bluetoothAddress != nil,
      AudioHAL.defaultDevice(.output) == device.id,
      AudioHAL.string(device.id, kAudioDevicePropertyDeviceUID) == device.uid,
      let raw = AudioHAL.uint(device.id, modeProperty),
      let mask = AudioHAL.uint(device.id, supportProperty)
    else { return nil }
    return AudioListeningModeState(
      modes: AudioListeningMode.supported(by: mask), current: AudioListeningMode(rawValue: raw),
      canSet: AudioHAL.settable(device.id, AudioHAL.address(modeProperty)))
  }

  private static func writeMode(_ device: AudioDeviceInfo, _ mode: AudioListeningMode) throws {
    guard let state = readState(device) else { throw AudioControlError.routeChanged }
    guard state.isControllable, state.modes.contains(mode), mode != .off else {
      throw AudioControlError.unsupported
    }
    var property = AudioHAL.address(modeProperty)
    var raw = mode.rawValue
    let status = AudioObjectSetPropertyData(device.id, &property, 0, nil, 4, &raw)
    guard status == noErr else { throw AudioControlError.hardware(status) }
  }

  private static func addListener(
    _ id: UInt32, _ selector: UInt32, _ queue: DispatchQueue,
    _ listener: @escaping AudioObjectPropertyListenerBlock
  ) -> Bool {
    var property = AudioHAL.address(selector)
    return AudioObjectAddPropertyListenerBlock(id, &property, queue, listener) == noErr
  }

  private static func removeListener(
    _ id: UInt32, _ selector: UInt32, _ queue: DispatchQueue,
    _ listener: @escaping AudioObjectPropertyListenerBlock
  ) {
    var property = AudioHAL.address(selector)
    AudioObjectRemovePropertyListenerBlock(id, &property, queue, listener)
  }
}
