// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// 仅实现本期需要的 MCCS 连续值控制，不扫描或写入未知 VCP 码。
enum DisplayControl: UInt8, CaseIterable, Sendable {
    case brightness = 0x10
    case contrast = 0x12
    case volume = 0x62
}

struct DDCValue: Equatable, Sendable {
    let current: UInt16
    let maximum: UInt16

    var percent: Double { Double(current) / Double(maximum) * 100 }

    func rawValue(for percent: Double) -> UInt16? {
        guard percent.isFinite, (0...100).contains(percent), maximum > 0 else { return nil }
        return UInt16((percent / 100 * Double(maximum)).rounded())
    }
}

enum DDCResult: Equatable, Sendable {
    case value(DDCValue)
    case unsupported
    case unavailable
    case timedOut
    case busy
    case cancelled
    case unconfirmed(DDCValue?)
}

struct DisplayTarget: Hashable, Sendable {
    let id: UInt32
    /// CG 显示器编号会复用，用设备签名与注册表位置校验同一连接，避免热插拔后写到另一块屏。
    let identity: String
}

enum DDCProtocol {
    static func get(_ control: DisplayControl) -> [UInt8] {
        packet(payload: [0x01, control.rawValue])
    }

    static func set(_ control: DisplayControl, value: UInt16) -> [UInt8] {
        packet(payload: [0x03, control.rawValue, UInt8(value >> 8), UInt8(value & 0xff)])
    }

    private static func packet(payload: [UInt8]) -> [UInt8] {
        let bytes = [0x80 | UInt8(payload.count)] + payload
        return bytes + [bytes.reduce(UInt8(0x6e ^ 0x51), ^)]
    }

    /// Get VCP Feature Reply：只接受完整帧、对应控制码及非零范围；坏帧不是“不支持”。
    static func parse(_ bytes: [UInt8], control: DisplayControl) -> DDCResult {
        guard bytes.count == 11, bytes[0] == 0x6e, bytes[1] == 0x88,
              bytes[2] == 0x02, bytes[4] == control.rawValue,
              bytes.reduce(UInt8(0x50), ^) == 0 else { return .unavailable }
        if bytes[3] == 1 { return .unsupported }
        guard bytes[3] == 0, bytes[5] == 0 else { return .unavailable }
        let maximum = UInt16(bytes[6]) << 8 | UInt16(bytes[7])
        let current = UInt16(bytes[8]) << 8 | UInt16(bytes[9])
        guard maximum > 0, current <= maximum else { return .unavailable }
        return .value(DDCValue(current: current, maximum: maximum))
    }
}

/// 同步内核调用不可强制取消；每个请求在总线操作前后检查本令牌。
final class DDCCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() { lock.withLock { cancelled = true } }
}

protocol DisplayDDCBackend: Sendable {
    func read(_ target: DisplayTarget, cancellation: DDCCancellation) async -> [DisplayControl: DDCResult]
    func write(_ target: DisplayTarget, control: DisplayControl, percent: Double,
               cancellation: DDCCancellation) async -> DDCResult
    /// 显示链路可能已变化（屏幕配置变更、唤醒），丢弃已匹配的服务，下次读写重新匹配。
    func resetConnections()
}

/// EDID 基本块中的厂商、产品与序列号，与 CGDisplay*Number 同源，用于确认 DDC 服务属于目标显示器。
struct EDIDSignature: Equatable, Sendable {
    let vendor: UInt32
    let product: UInt32
    let serial: UInt32

    init(vendor: UInt32, product: UInt32, serial: UInt32) {
        self.vendor = vendor
        self.product = product
        self.serial = serial
    }

    init?(_ bytes: [UInt8]) {
        guard bytes.count >= 128, bytes.prefix(8) == [0x00, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x00] else { return nil }
        vendor = UInt32(bytes[8]) << 8 | UInt32(bytes[9])
        product = UInt32(bytes[10]) | UInt32(bytes[11]) << 8
        serial = UInt32(bytes[12]) | UInt32(bytes[13]) << 8 | UInt32(bytes[14]) << 16 | UInt32(bytes[15]) << 24
    }

    /// 读不到 EDID 时无法确认 proxy 归属：只有一台外接屏时不存在错写对象，多屏则拒绝。
    static func verifies(_ observed: EDIDSignature?, expected: EDIDSignature, externalDisplays: Int) -> Bool {
        guard let observed else { return externalDisplays == 1 }
        return observed.matches(expected)
    }

    /// 序列号为 0 表示 EDID 未提供，此时只比较厂商与产品。
    func matches(_ other: EDIDSignature) -> Bool {
        vendor == other.vendor && product == other.product
            && (serial == 0 || other.serial == 0 || serial == other.serial)
    }
}

/// 写前重新确认范围，写后读取真实值；发送成功本身不等于显示器已应用。
/// 闭包在同一串行工作线程同步执行，便于独立验证错误路径而不改动真实显示器。
enum DDCWriteTransaction {
    static func apply(percent: Double, cancellation: DDCCancellation, isCurrent: () -> Bool,
                      read: () -> DDCResult, send: (UInt16) -> Bool) -> DDCResult {
        guard percent.isFinite, (0...100).contains(percent) else { return .unavailable }
        guard !cancellation.isCancelled, isCurrent() else { return .cancelled }
        let before = read()
        guard case .value(let value) = before else { return before }
        guard let raw = value.rawValue(for: percent) else { return .unavailable }
        guard !cancellation.isCancelled, isCurrent() else { return .cancelled }
        guard send(raw) else { return .unavailable }
        Thread.sleep(forTimeInterval: 0.05)
        guard !cancellation.isCancelled, isCurrent() else { return .cancelled }
        guard case .value(let confirmed) = read() else { return .unconfirmed(nil) }
        let tolerance = max(1, Int(confirmed.maximum) / 100)
        guard confirmed.maximum == value.maximum,
              abs(Int(confirmed.current) - Int(raw)) <= tolerance else { return .unconfirmed(confirmed) }
        return .value(confirmed)
    }
}
