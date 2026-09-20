//
//  SMCConnection.swift
//  XStats
//
//  与 AppleSMC 用户客户端通信。结构体布局与读写流程移植自 exelban/stats (MIT)：
//  Copyright © 2021 Serhiy Mytrovtsiy. All rights reserved.
//

import Foundation
import IOKit
import Localization

public struct SMCKey: Hashable, Sendable, CustomStringConvertible {
    public let code: UInt32

    public init(_ string: String) {
        precondition(string.utf8.count == 4, "SMC key must be 4 chars")
        code = string.utf8.reduce(0) { $0 << 8 | UInt32($1) }
    }

    init(code: UInt32) { self.code = code }

    public var description: String {
        let bytes = [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: code >> $0) }
        return String(decoding: bytes, as: UTF8.self)
    }
}

public struct SMCKeyInfo: Sendable, Equatable {
    public let size: UInt32
    public let type: String
}

public enum SMCError: Error, Sendable, CustomStringConvertible {
    case serviceNotFound
    case openFailed(kern_return_t)
    case callFailed(SMCKey, kern_return_t)
    case firmwareRejected(SMCKey, UInt8)
    case unsupportedType(SMCKey, String)

    public var description: String {
        switch self {
        case .serviceNotFound: tr("未找到 AppleSMC 服务")
        case .openFailed(let kr): tr("打开 SMC 失败 (\(Self.message(kr)))")
        case .callFailed(let key, let kr): tr("SMC [\(key)] 调用失败 (\(Self.message(kr)))")
        case .firmwareRejected(let key, let code): tr("SMC [\(key)] 被固件拒绝 (0x\(String(code, radix: 16)))")
        case .unsupportedType(let key, let type): tr("SMC [\(key)] 不支持的数据类型 \(type)")
        }
    }

    private static func message(_ kr: kern_return_t) -> String {
        String(cString: mach_error_string(kr))
    }
}

/// 与内核 `SMCParamStruct` 等长（80 字节），字段顺序不可调整。
struct SMCParam {
    typealias Bytes = (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                       UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                       UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                       UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8)

    struct Version { var major: UInt8 = 0, minor: UInt8 = 0, build: UInt8 = 0, reserved: UInt8 = 0, release: UInt16 = 0 }
    struct PLimit { var version: UInt16 = 0, length: UInt16 = 0, cpu: UInt32 = 0, gpu: UInt32 = 0, mem: UInt32 = 0 }
    struct KeyInfo { var dataSize: UInt32 = 0, dataType: UInt32 = 0, dataAttributes: UInt8 = 0 }

    var key: UInt32 = 0
    var vers = Version()
    var pLimit = PLimit()
    var keyInfo = KeyInfo()
    var padding: UInt16 = 0
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: Bytes = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
}

private enum SMCSelector: UInt8 {
    case kernelIndex = 2
    case readBytes = 5
    case writeBytes = 6
    case readIndex = 8
    case readKeyInfo = 9
}

/// 非线程安全：请在单一 actor / 串行队列内使用。
public final class SMCConnection {
    private var connection: io_connect_t = 0
    private var infoCache: [SMCKey: SMCKeyInfo] = [:]

    public init() throws {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { throw SMCError.serviceNotFound }
        defer { IOObjectRelease(service) }
        let kr = IOServiceOpen(service, mach_task_self_, 0, &connection)
        guard kr == KERN_SUCCESS else { throw SMCError.openFailed(kr) }
    }

    deinit {
        IOServiceClose(connection)
    }

    // MARK: 读取

    public func info(_ key: SMCKey) throws -> SMCKeyInfo {
        if let cached = infoCache[key] { return cached }
        var input = SMCParam()
        input.key = key.code
        input.data8 = SMCSelector.readKeyInfo.rawValue
        let output = try call(key, &input)
        let info = SMCKeyInfo(size: output.keyInfo.dataSize, type: SMCKey(code: output.keyInfo.dataType).description)
        infoCache[key] = info
        return info
    }

    public func bytes(_ key: SMCKey) throws -> (SMCKeyInfo, [UInt8]) {
        let info = try info(key)
        var input = SMCParam()
        input.key = key.code
        input.keyInfo.dataSize = info.size
        input.data8 = SMCSelector.readBytes.rawValue
        var output = try call(key, &input)
        let count = min(Int(info.size), 32)
        let bytes = withUnsafeBytes(of: &output.bytes) { Array($0.prefix(count)) }
        return (info, bytes)
    }

    /// 读取数值型键，失败或类型不支持时返回 nil。
    public func double(_ key: SMCKey) -> Double? {
        guard let (info, bytes) = try? bytes(key) else { return nil }
        return SMCDecoder.decode(type: info.type, bytes: bytes)
    }

    public func keyCount() -> Int {
        Int(double(SMCKey("#KEY")) ?? 0)
    }

    public func key(at index: Int) -> SMCKey? {
        var input = SMCParam()
        input.data8 = SMCSelector.readIndex.rawValue
        input.data32 = UInt32(index)
        guard let output = try? call(SMCKey(code: 0), &input) else { return nil }
        return SMCKey(code: output.key)
    }

    public func allKeys() -> [SMCKey] {
        (0..<keyCount()).compactMap { key(at: $0) }
    }

    // MARK: 写入（需要 root）

    public func write(_ key: SMCKey, bytes newBytes: [UInt8]) throws {
        let info = try info(key)
        var input = SMCParam()
        input.key = key.code
        input.data8 = SMCSelector.writeBytes.rawValue
        input.keyInfo.dataSize = info.size
        withUnsafeMutableBytes(of: &input.bytes) { buffer in
            for (i, byte) in newBytes.prefix(min(Int(info.size), 32)).enumerated() { buffer[i] = byte }
        }
        let output = try call(key, &input)
        // IOKit 返回成功时，SMC 固件仍可能拒绝写入
        guard output.result == 0 else { throw SMCError.firmwareRejected(key, output.result) }
    }

    public func write(_ key: SMCKey, value: Double) throws {
        let info = try info(key)
        guard let encoded = SMCDecoder.encode(type: info.type, value: value) else {
            throw SMCError.unsupportedType(key, info.type)
        }
        try write(key, bytes: encoded)
    }

    public func exists(_ key: SMCKey) -> Bool {
        guard let info = try? info(key) else { return false }
        return info.size > 0
    }

    private func call(_ key: SMCKey, _ input: inout SMCParam) throws -> SMCParam {
        var output = SMCParam()
        var outputSize = MemoryLayout<SMCParam>.stride
        let kr = IOConnectCallStructMethod(connection, UInt32(SMCSelector.kernelIndex.rawValue),
                                           &input, MemoryLayout<SMCParam>.stride, &output, &outputSize)
        guard kr == KERN_SUCCESS else { throw SMCError.callFailed(key, kr) }
        // result 0x84 表示键不存在
        if output.result == 0x84 { throw SMCError.callFailed(key, kIOReturnNotFound) }
        return output
    }
}

public enum SMCDecoder {
    public static func decode(type: String, bytes: [UInt8]) -> Double? {
        func be16() -> Double? { bytes.count >= 2 ? Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1])) : nil }
        func signed16() -> Double? { bytes.count >= 2 ? Double(Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1]))) : nil }

        switch type {
        case "flt ":
            guard bytes.count >= 4 else { return nil }
            return Double(bytes.withUnsafeBytes { $0.loadUnaligned(as: Float32.self) })
        case "ui8 ", "flag":
            return bytes.first.map(Double.init)
        case "ui16":
            return be16()
        case "ui32":
            guard bytes.count >= 4 else { return nil }
            return Double(bytes.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
        case "fpe2":
            return be16().map { $0 / 4 }
        case "sp78":
            return signed16().map { $0 / 256 }
        case "sp87":
            return signed16().map { $0 / 128 }
        case "sp96":
            return signed16().map { $0 / 64 }
        case "spb4":
            return signed16().map { $0 / 16 }
        case "spf0":
            return signed16()
        default:
            return nil
        }
    }

    public static func encode(type: String, value: Double) -> [UInt8]? {
        switch type {
        case "flt ":
            return withUnsafeBytes(of: Float32(value)) { Array($0) }
        case "ui8 ", "flag":
            return [UInt8(clamping: Int(value))]
        case "fpe2":
            let raw = UInt16(clamping: Int(value * 4))
            return [UInt8(raw >> 8), UInt8(raw & 0xff)]
        default:
            return nil
        }
    }
}
