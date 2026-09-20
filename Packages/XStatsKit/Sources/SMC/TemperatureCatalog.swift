import Foundation
import Localization

public enum TemperatureGroup: String, Sendable, CaseIterable, Codable {
    case cpu, gpu, memory, battery, palmRest

    public var title: String {
        switch self {
        case .cpu: "CPU"
        case .gpu: "GPU"
        case .memory: tr("内存")
        case .battery: tr("电池")
        case .palmRest: tr("掌托")
        }
    }
}

/// 不按芯片型号硬编码键名：启动时枚举一次 SMC，按前缀归类温度键。
public enum TemperatureCatalog {
    public static let plausibleRange: ClosedRange<Double> = 5...130

    public static func group(for key: String) -> TemperatureGroup? {
        guard key.utf8.count == 4, key.hasPrefix("T") else { return nil }
        switch key {
        case "Ts0P", "Ts1P": return .palmRest
        default: break
        }
        switch String(key.prefix(2)) {
        case "Tp", "Te": return .cpu       // Apple Silicon CPU 核心
        case "Tg": return .gpu             // Apple Silicon GPU
        case "Tm": return .memory
        case "TB": return .battery
        case "TC": return key.hasSuffix("P") || key.hasSuffix("D") ? .cpu : nil   // Intel
        case "TG": return key.hasSuffix("P") || key.hasSuffix("D") ? .gpu : nil   // Intel
        default: return nil
        }
    }

    /// 每组最多读取的传感器数量。M5 Max 仅 GPU 就有 84 个键，全部每秒读取没有必要
    public static let maxKeysPerGroup = 12

    /// 返回每组可用的键（首次读数合理的才保留），数量过多时均匀抽样
    public static func discover(using smc: SMCConnection) -> [TemperatureGroup: [SMCKey]] {
        var result: [TemperatureGroup: [SMCKey]] = [:]
        for key in smc.allKeys() {
            guard let group = group(for: key.description),
                  let value = smc.double(key),
                  plausibleRange.contains(value) else { continue }
            result[group, default: []].append(key)
        }
        return result.mapValues(sample)
    }

    static func sample(_ keys: [SMCKey]) -> [SMCKey] {
        guard keys.count > maxKeysPerGroup else { return keys }
        let step = Double(keys.count) / Double(maxKeysPerGroup)
        return (0..<maxKeysPerGroup).map { keys[Int(Double($0) * step)] }
    }
}
