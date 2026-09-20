import Foundation
import Localization
import Metrics
import Observation
import SMC

@MainActor
@Observable
public final class FanController {
    public enum Mode: String, CaseIterable, Identifiable {
        case automatic, cooling, maximum, custom

        public var id: String { rawValue }

        var title: String {
            switch self {
            case .automatic: tr("自动")
            case .cooling: tr("降温")
            case .maximum: tr("强冷")
            case .custom: tr("自定义")
            }
        }

        /// “降温”档位于最低与最高转速之间的 60%
        static let coolingLevel = 0.6
    }

    public private(set) var mode: Mode = .automatic
    /// 自定义档位：0 为最低转速，1 为最高转速
    public var customLevel: Double = 0.5
    public private(set) var isApplying = false
    public private(set) var notice: String?
    public private(set) var noticeIsError = false

    @ObservationIgnored private let helper: HelperClient
    @ObservationIgnored private let store: MetricsStore
    @ObservationIgnored private let settings: AppSettings

    init(helper: HelperClient, store: MetricsStore, settings: AppSettings) {
        self.helper = helper
        self.store = store
        self.settings = settings
    }

    func select(_ newMode: Mode) async {
        guard newMode != mode || newMode == .custom else { return }
        let previous = mode
        mode = newMode
        if let error = await apply() {
            mode = previous
            show(error, isError: true)
        } else {
            clearNotice()
        }
    }

    func commitCustomLevel() async {
        guard mode == .custom else { return }
        if let error = await apply() { show(error, isError: true) }
    }

    /// 连接恢复或唤醒后重新下发
    func reapply() async {
        guard mode != .automatic else { return }
        if let error = await apply() { show(error, isError: true) }
    }

    /// 每次收到新指标时检查温度，自定义档位过低且 CPU 过热时交还系统控制
    func evaluateSafety() {
        guard mode == .custom, customLevel < 1,
              let hottest = store.sensors?.temperature(.cpu)?.maximum,
              hottest >= Double(settings.fanSafetyTemperature) else { return }
        Task {
            mode = .automatic
            _ = await apply()
            show(tr("CPU 温度达到 \(Format.temperature(hottest, fahrenheit: settings.useFahrenheit))，已恢复系统自动控制"), isError: false)
        }
    }

    func targetRPM(for fan: FanState) -> Double {
        switch mode {
        case .automatic: fan.target
        case .cooling: fan.minimum + (fan.maximum - fan.minimum) * Mode.coolingLevel
        case .maximum: fan.maximum
        case .custom: fan.minimum + (fan.maximum - fan.minimum) * customLevel
        }
    }

    private func apply() async -> String? {
        let fans = store.sensors?.fans ?? []
        guard !fans.isEmpty else { return tr("未检测到可调节的风扇") }
        isApplying = true
        defer { isApplying = false }

        if mode == .automatic {
            return await helper.resetAllFans()
        }
        for fan in fans {
            if let error = await helper.setFanTarget(fan: fan.id, rpm: targetRPM(for: fan)) {
                _ = await helper.resetAllFans()
                return error
            }
        }
        return nil
    }

    private func show(_ message: String, isError: Bool) {
        if isError { Log.fans.error("\(message, privacy: .public)") } else { Log.fans.info("\(message, privacy: .public)") }
        notice = message
        noticeIsError = isError
    }

    private func clearNotice() {
        notice = nil
        noticeIsError = false
    }
}
