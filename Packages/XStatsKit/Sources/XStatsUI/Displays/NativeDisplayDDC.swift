// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import CoreGraphics
import Foundation
import IOKit
import Darwin

/// Apple Silicon 的 DDC/CI 传输。CF 服务只在串行 I/O 队列内创建、使用和释放。
/// 不提供软件调光或任意 VCP 写入；系统缺少 IOAV 符号时保持信息可读、控制不可用。
final class NativeDisplayDDC: DisplayDDCBackend, @unchecked Sendable {
    private let queue = DispatchQueue(label: "work.12306.xstats.display-ddc", qos: .userInitiated)
    private let lock = NSLock()
    private var running = false
    /// 只在 queue 内读写：注册表遍历成本高，按连接缓存匹配结果（含未找到），
    /// 由 resetConnections() 在链路变化时清空，条目数不超过当前连接的外接屏。
    private var services: [DisplayTarget: Service?] = [:]

    func resetConnections() {
        queue.async { [self] in services.removeAll() }
    }

    func read(_ target: DisplayTarget, cancellation: DDCCancellation) async -> [DisplayControl: DDCResult] {
        let failed = Dictionary(uniqueKeysWithValues: DisplayControl.allCases.map { ($0, DDCResult.unavailable) })
        return await execute(timeout: failed.mapValues { _ in .timedOut }, busy: failed.mapValues { _ in .busy },
                             cancellation: cancellation) {
            guard !cancellation.isCancelled, let api = Functions.shared,
                  let service = self.service(for: target, api: api) else { return failed }
            var values: [DisplayControl: DDCResult] = [:]
            for control in DisplayControl.allCases {
                guard !cancellation.isCancelled else { values[control] = .cancelled; continue }
                values[control] = Self.read(service, control: control, api: api, cancellation: cancellation)
            }
            return values
        }
    }

    func write(_ target: DisplayTarget, control: DisplayControl, percent: Double,
               cancellation: DDCCancellation) async -> DDCResult {
        guard percent.isFinite, (0...100).contains(percent) else { return .unavailable }
        return await execute(timeout: .timedOut, busy: .busy, cancellation: cancellation) {
            guard !cancellation.isCancelled, let api = Functions.shared,
                  let service = self.service(for: target, api: api) else { return .unavailable }
            return DDCWriteTransaction.apply(percent: percent, cancellation: cancellation,
                isCurrent: { Self.identity(for: target.id) == target.identity },
                read: { Self.read(service, control: control, api: api, cancellation: cancellation) },
                send: { raw in
                    var packet = DDCProtocol.set(control, value: raw)
                    return packet.withUnsafeMutableBytes {
                        api.write(service.value, service.address, 0x51, $0.baseAddress!, UInt32($0.count)) == KERN_SUCCESS
                    }
                })
        }
    }

    /// 超时只结束等待，不能终止内核调用。因此在旧调用真正返回前保留 running，
    /// 后续请求立即返回 busy，不积累排队任务或为每次超时再开一个线程。
    func execute<Value: Sendable>(timeout: Value, busy: Value, cancellation: DDCCancellation,
                                          operation: @escaping @Sendable () -> Value) async -> Value {
        let accepted = lock.withLock {
            guard !running else { return false }
            running = true
            return true
        }
        guard accepted else { return busy }
        return await withCheckedContinuation { continuation in
            let completion = Completion(continuation)
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
                completion.finish(timeout, beforeResume: { cancellation.cancel() })
            }
            queue.async { [self] in
                let result = operation()
                lock.withLock { running = false }
                completion.finish(result)
            }
        }
    }

    private final class Completion<Value: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Value, Never>?
        init(_ continuation: CheckedContinuation<Value, Never>) { self.continuation = continuation }
        func finish(_ value: Value, beforeResume: () -> Void = {}) {
            let pending = lock.withLock {
                let pending = continuation
                continuation = nil
                return pending
            }
            guard let pending else { return }
            beforeResume()
            pending.resume(returning: value)
        }
    }

    static func identity(for id: UInt32) -> String? {
        guard CGDisplayIsOnline(id) != 0, let api = Functions.shared,
              let info = api.info(id)?.takeRetainedValue() as? [String: Any],
              let location = info["IODisplayLocation"] as? String, !location.isEmpty else { return nil }
        return "\(CGDisplayVendorNumber(id)):\(CGDisplayModelNumber(id)):\(CGDisplaySerialNumber(id)):\(location)"
    }

    private struct Service {
        let value: CFTypeRef
        let address: UInt32
    }

    /// 在 queue 内调用；命中缓存时仍校验连接身份，显示器下线或编号复用时不使用旧服务。
    private func service(for target: DisplayTarget, api: Functions) -> Service? {
        guard Self.identity(for: target.id) == target.identity else { return nil }
        if let cached = services[target] { return cached }
        let found = Self.matchService(for: target, api: api)
        services[target] = found
        return found
    }

    /// 通过 CoreDisplay 的注册表位置匹配 framebuffer；只接受一个明确对应的外接服务。
    /// proxy 不在 framebuffer 子树下，只能按遍历顺序归属，因此再用服务自身的 EDID 排除其他显示器的 proxy。
    /// 不用型号名、枚举序号或相近 EDID 猜测目标，以免同型号多屏发生错写。
    private static func matchService(for target: DisplayTarget, api: Functions) -> Service? {
        guard identity(for: target.id) == target.identity, CGDisplayIsBuiltin(target.id) == 0,
              let info = api.info(target.id)?.takeRetainedValue() as? [String: Any],
              let location = info["IODisplayLocation"] as? String, !location.isEmpty else { return nil }
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        guard root != 0 else { return nil }
        defer { IOObjectRelease(root) }
        var iterator: io_iterator_t = 0
        guard IORegistryEntryCreateIterator(root, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        let expected = EDIDSignature(vendor: CGDisplayVendorNumber(target.id), product: CGDisplayModelNumber(target.id),
                                     serial: CGDisplaySerialNumber(target.id))
        var online = [CGDirectDisplayID](repeating: 0, count: 16)
        var onlineCount: UInt32 = 0
        guard CGGetOnlineDisplayList(UInt32(online.count), &online, &onlineCount) == .success else { return nil }
        let externalDisplays = online.prefix(Int(onlineCount)).filter { CGDisplayIsBuiltin($0) == 0 }.count
        var matchingFramebuffer = false
        var candidates: [Service] = []
        for _ in 0..<20_000 {
            let entry = IOIteratorNext(iterator)
            if entry == 0 { break }
            defer { IOObjectRelease(entry) }
            var name = [CChar](repeating: 0, count: 128)
            guard IORegistryEntryGetName(entry, &name) == KERN_SUCCESS else { continue }
            let label = String(decoding: name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            if label.contains("AppleCLCD2") || label.contains("IOMobileFramebufferShim") {
                var path = [CChar](repeating: 0, count: 1024)
                matchingFramebuffer = IORegistryEntryGetPath(entry, kIOServicePlane, &path) == KERN_SUCCESS
                    && String(decoding: path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self) == location
            } else if matchingFramebuffer && label == "DCPAVServiceProxy" {
                let kind = IORegistryEntryCreateCFProperty(entry, "Location" as CFString, nil, 0)?.takeRetainedValue() as? String
                guard kind == "External", let service = api.create(nil, entry)?.takeRetainedValue(),
                      EDIDSignature.verifies(edid(of: service, api: api), expected: expected,
                                             externalDisplays: externalDisplays) else { continue }
                let provider = IORegistryEntrySearchCFProperty(entry, kIOServicePlane, "EPICProviderClass" as CFString,
                    nil, IOOptionBits(kIORegistryIterateParents | kIORegistryIterateRecursively)) as? String
                // 部分 M1/M2 HDMI 桥使用另一条路由地址；协议校验和仍使用标准 DDC 地址。
                candidates.append(Service(value: service, address: provider == "AppleDCPMCDP29XX" ? 0xb7 : 0x37))
            }
        }
        guard candidates.count == 1, identity(for: target.id) == target.identity else { return nil }
        return candidates[0]
    }

    /// 读不到 EDID（符号缺失或链路不提供）时返回 nil，由 EDIDSignature.verifies 决定是否接受。
    private static func edid(of service: CFTypeRef, api: Functions) -> EDIDSignature? {
        guard let copyEDID = api.copyEDID else { return nil }
        var data: Unmanaged<CFData>?
        guard copyEDID(service, &data) == KERN_SUCCESS, let bytes = data?.takeRetainedValue() as Data? else { return nil }
        return EDIDSignature([UInt8](bytes))
    }

    private static func read(_ service: Service, control: DisplayControl, api: Functions,
                             cancellation: DDCCancellation) -> DDCResult {
        for _ in 0..<2 {
            guard !cancellation.isCancelled else { return .cancelled }
            var request = DDCProtocol.get(control)
            let sent = request.withUnsafeMutableBytes {
                api.write(service.value, service.address, 0x51, $0.baseAddress!, UInt32($0.count))
            }
            guard sent == KERN_SUCCESS else { continue }
            Thread.sleep(forTimeInterval: 0.05)
            guard !cancellation.isCancelled else { return .cancelled }
            var reply = [UInt8](repeating: 0, count: 11)
            let received = reply.withUnsafeMutableBytes {
                api.read(service.value, service.address, 0, $0.baseAddress!, UInt32($0.count))
            }
            guard received == KERN_SUCCESS else { continue }
            let parsed = DDCProtocol.parse(reply, control: control)
            if parsed != .unavailable { return parsed }
        }
        return .unavailable
    }

    /// 不可变 C 函数指针；动态库在进程存续期间保持加载，任何线程均可读取。
    private struct Functions: @unchecked Sendable {
        typealias Create = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?
        typealias Transfer = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn
        typealias Info = @convention(c) (UInt32) -> Unmanaged<CFDictionary>?
        typealias CopyEDID = @convention(c) (CFTypeRef, UnsafeMutablePointer<Unmanaged<CFData>?>) -> IOReturn
        let create: Create
        let read: Transfer
        let write: Transfer
        let info: Info
        let copyEDID: CopyEDID?
        static let shared: Functions? = {
            guard let io = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY),
                  let cd = dlopen("/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay", RTLD_LAZY),
                  let create = dlsym(io, "IOAVServiceCreateWithService"),
                  let read = dlsym(io, "IOAVServiceReadI2C"),
                  let write = dlsym(io, "IOAVServiceWriteI2C"),
                  let info = dlsym(cd, "CoreDisplay_DisplayCreateInfoDictionary") else { return nil }
            return Functions(create: unsafeBitCast(create, to: Create.self), read: unsafeBitCast(read, to: Transfer.self),
                             write: unsafeBitCast(write, to: Transfer.self), info: unsafeBitCast(info, to: Info.self),
                             copyEDID: dlsym(io, "IOAVServiceCopyEDID").map { unsafeBitCast($0, to: CopyEDID.self) })
        }()
    }
}
