// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 拖动与最终写入完成之间保留草稿；身份变化或新拖动使旧完成事件失效。
struct AudioDeviceVolumeDraft {
    private(set) var value: Double?
    private enum Phase { case idle, dragging, waiting(UInt64) }
    private var phase = Phase.idle
    private var revision: UInt64 = 0
    mutating func update(_ value: Double) { self.value = value }
    mutating func beginEditing() { revision &+= 1; phase = .dragging }
    mutating func endEditing() -> UInt64 { revision &+= 1; phase = .waiting(revision); return revision }
    mutating func readbackChanged() { if case .idle = phase { value = nil } }
    mutating func complete(_ token: UInt64) -> Bool {
        guard case .waiting(let current) = phase, token == current else { return false }
        phase = .idle; value = nil; return true
    }
    mutating func reset() { revision &+= 1; phase = .idle; value = nil }
}
