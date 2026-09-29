import Foundation
import SMC

/// 温度与风扇（只读，普通权限即可）。
public final class SensorSampler {
    private let smc: SMCConnection?
    private let fans: FanControl?
    private var detectedFanCount: Int?
    private lazy var catalog: [TemperatureGroup: [SMCKey]] = smc.map(TemperatureCatalog.discover) ?? [:]

    public init() {
        smc = try? SMCConnection()
        fans = smc.map(FanControl.init)
    }

    public func sample(groups: Set<TemperatureGroup> = Set(TemperatureGroup.allCases), includeFans: Bool = true) -> SensorReadings? {
        guard let smc else { return nil }
        // 硬件数量成功读到后复用；未知时随既有采样重试，不新增轮询。
        if detectedFanCount == nil, let raw = smc.double(SMCKey("FNum")),
           let count = Int(exactly: raw), count >= 0 {
            detectedFanCount = count
        }
        var summaries: [TemperatureSummary] = []
        for group in TemperatureGroup.allCases where groups.contains(group) {
            let values = (catalog[group] ?? []).compactMap(smc.double).filter(TemperatureCatalog.plausibleRange.contains)
            guard !values.isEmpty else { continue }
            summaries.append(TemperatureSummary(group: group,
                                                average: values.reduce(0, +) / Double(values.count),
                                                maximum: values.max() ?? 0,
                                                sensorCount: values.count))
        }
        return SensorReadings(temperatures: summaries, fans: includeFans && detectedFanCount != 0 ? (fans?.read() ?? []) : [],
                              fanCount: detectedFanCount)
    }
}
