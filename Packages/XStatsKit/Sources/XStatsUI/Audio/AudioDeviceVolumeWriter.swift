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
    private let finished: @MainActor (AudioDeviceVolumeRequest, AudioControlError?) -> Void
    private var pending: [(request: AudioDeviceVolumeRequest, sequence: UInt64)] = []
    private var outputSequence: UInt64 = 0
    private var inputSequence: UInt64 = 0
    private var generation: UInt64 = 0
    private var task: Task<Void, Never>?
    init(write: @escaping @Sendable (AudioDeviceVolumeRequest) async throws -> Void,
         finished: @escaping @MainActor (AudioDeviceVolumeRequest, AudioControlError?) -> Void) {
        self.write = write; self.finished = finished
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
                do { try await write(request) }
                catch let failure { error = failure as? AudioControlError ?? .unavailable }
                let newest = request.direction == .output ? outputSequence : inputSequence
                if epoch == generation, next.sequence == newest { finished(request, error) }
            }
            task = nil
        }
    }
    func flush() async { await task?.value }
    func cancelPending() { generation &+= 1; pending.removeAll() }
}
