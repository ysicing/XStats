// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later
import AudioControl
import Foundation

struct AudioDeviceVolumeRequest: Sendable {
  let level: Double
  let device: AudioDeviceInfo
  let direction: AudioDirection
}

/// 同时只执行一次写入；拖动期间每个方向只保留最新请求。取消不会假定已进入 HAL 的写入能撤销。
@MainActor
final class AudioDeviceVolumeWriter {
  private let write: @Sendable (AudioDeviceVolumeRequest) async throws -> Void
  private let unmute: @Sendable (AudioDeviceVolumeRequest) async throws -> Void
  private let finished: @MainActor (AudioDeviceVolumeRequest, AudioControlError?) -> Void
  private var pending: [(request: AudioDeviceVolumeRequest, sequence: UInt64)] = []
  private var outputSequence: UInt64 = 0
  private var inputSequence: UInt64 = 0
  private var generation: UInt64 = 0
  private var task: Task<Void, Never>?
  private var inFlightWrite: Task<Void, any Error>?
  init(
    write: @escaping @Sendable (AudioDeviceVolumeRequest) async throws -> Void,
    unmute: @escaping @Sendable (AudioDeviceVolumeRequest) async throws -> Void,
    finished: @escaping @MainActor (AudioDeviceVolumeRequest, AudioControlError?) -> Void
  ) {
    self.write = write
    self.unmute = unmute
    self.finished = finished
  }
  func submit(_ request: AudioDeviceVolumeRequest) {
    if request.direction == .output { outputSequence &+= 1 } else { inputSequence &+= 1 }
    let sequence = request.direction == .output ? outputSequence : inputSequence
    pending.removeAll { $0.request.direction == request.direction }
    pending.append((request, sequence))
    guard task == nil else { return }
    task = Task { [weak self] in
      guard let self else { return }
      while !pending.isEmpty {
        let epoch = generation
        let next = pending.removeFirst()
        let request = next.request
        var error: AudioControlError?
        let operation = Task {
          try Task.checkCancellation()
          try await write(request)
          // HAL 中已开始的音量写入可能无法撤销，但后续取消静音必须服从当前功能生命周期。
          try Task.checkCancellation()
          let muted =
            request.direction == .output
            ? request.device.outputMuted : request.device.inputMuted
          if request.level > 0, muted == true { try await unmute(request) }
        }
        inFlightWrite = operation
        do { try await operation.value } catch let failure {
          error = failure as? AudioControlError ?? .unavailable
        }
        inFlightWrite = nil
        let newest = request.direction == .output ? outputSequence : inputSequence
        if epoch == generation, next.sequence == newest { finished(request, error) }
      }
      task = nil
    }
  }
  func flush() async { await task?.value }
  /// 丢弃排队请求与晚到的结果；在途写入连同其取消静音照常完成。
  func discardPending() {
    generation &+= 1
    pending.removeAll()
  }
  /// 关闭功能或休眠时还要中断在途任务，已进入 HAL 的写入可能完成，但不再取消静音。
  func cancelPending() {
    discardPending()
    inFlightWrite?.cancel()
  }
}
