import Foundation
import IOKit.pwr_mgt
import Localization
import Metrics
import Observation

@MainActor
@Observable
public final class KeepAwakeController {
    public enum Mode: String, CaseIterable, Identifiable {
        case display, system

        public var id: String { rawValue }

        var title: String {
            switch self {
            case .display: tr("屏幕保持常亮")
            case .system: tr("仅系统不休眠")
            }
        }

        var subtitle: String {
            switch self {
            case .display: tr("屏幕和系统都不会因闲置而关闭或休眠")
            case .system: tr("屏幕可按设置关闭，下载、编译等后台任务继续运行")
            }
        }

        /// IOPMLib 中的 CFSTR 宏无法直接导入 Swift，这里使用其字符串值
        var assertionType: String {
            switch self {
            case .display: "PreventUserIdleDisplaySleep"
            case .system: "PreventUserIdleSystemSleep"
            }
        }
    }

    public enum Duration: Int, CaseIterable, Identifiable {
        case minutes15 = 15, hour1 = 60, hours2 = 120, hours5 = 300, unlimited = 0

        public var id: Int { rawValue }

        var title: String {
            switch self {
            case .minutes15: tr("15 分钟")
            case .hour1: tr("1 小时")
            case .hours2: tr("2 小时")
            case .hours5: tr("5 小时")
            case .unlimited: tr("不限")
            }
        }
    }

    public private(set) var isActive = false
    public private(set) var mode: Mode = .display
    public private(set) var duration: Duration = .unlimited
    public private(set) var endDate: Date?
    /// 用户是否希望合盖后继续运行
    public private(set) var lidClosedRequested = false
    /// 辅助工具是否已实际关闭系统睡眠
    public private(set) var lidClosedActive = false
    public private(set) var notice: String?
    public private(set) var noticeIsError = false

    @ObservationIgnored private var assertionID: IOPMAssertionID = 0
    @ObservationIgnored private var expiryTask: Task<Void, Never>?
    @ObservationIgnored private let helper: HelperClient
    @ObservationIgnored private let settings: AppSettings

    init(helper: HelperClient, settings: AppSettings) {
        self.helper = helper
        self.settings = settings
    }

    func setActive(_ active: Bool) async {
        active ? await start() : await stop(reason: nil)
    }

    func setMode(_ newMode: Mode) {
        mode = newMode
        if isActive { takeAssertion() }
    }

    func setDuration(_ newDuration: Duration) {
        duration = newDuration
        if isActive { scheduleExpiry() }
    }

    func setLidClosed(_ requested: Bool) async {
        lidClosedRequested = requested
        guard isActive else { return }
        await applyLidMode()
    }

    func start() async {
        isActive = true
        notice = nil
        takeAssertion()
        scheduleExpiry()
        if lidClosedRequested { await applyLidMode() }
    }

    func stop(reason: String?) async {
        isActive = false
        endDate = nil
        expiryTask?.cancel()
        releaseAssertion()
        if lidClosedActive {
            if let error = await helper.setSleepDisabled(false) {
                show(tr("恢复系统睡眠失败：\(error)"), isError: true)
                return
            }
            lidClosedActive = false
        }
        if let reason { show(reason, isError: false) }
    }

    /// 连接恢复后重新下发合盖设置
    func reapply() async {
        guard isActive, lidClosedRequested else { return }
        await applyLidMode()
    }

    /// 电池电量保护：使用电池供电且电量低于下限时关闭合盖运行
    func evaluateBattery(_ battery: BatteryStatus?) {
        guard lidClosedActive, let battery, !battery.isPluggedIn,
              battery.level * 100 < Double(settings.lidModeBatteryFloor) else { return }
        Task {
            lidClosedRequested = false
            await applyLidMode()
            show(tr("电量低于 \(settings.lidModeBatteryFloor)%，已关闭合盖运行"), isError: false)
        }
    }

    /// 退出应用时释放电源断言（合盖设置由 HelperClient 同步恢复）
    func releaseForTermination() {
        releaseAssertion()
    }

    private func applyLidMode() async {
        let wanted = isActive && lidClosedRequested
        guard wanted != lidClosedActive else { return }
        if let error = await helper.setSleepDisabled(wanted) {
            lidClosedRequested = lidClosedActive
            show(error, isError: true)
            return
        }
        lidClosedActive = wanted
    }

    private func takeAssertion() {
        releaseAssertion()
        var id: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(mode.assertionType as CFString,
                                                 IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                 tr("XStats 防休眠") as CFString,
                                                 &id)
        if result == kIOReturnSuccess {
            assertionID = id
        } else {
            show(tr("无法创建电源断言（\(result)）"), isError: true)
        }
    }

    private func releaseAssertion() {
        guard assertionID != 0 else { return }
        IOPMAssertionRelease(assertionID)
        assertionID = 0
    }

    private func scheduleExpiry() {
        expiryTask?.cancel()
        guard duration != .unlimited else {
            endDate = nil
            return
        }
        let end = Date().addingTimeInterval(TimeInterval(duration.rawValue * 60))
        endDate = end
        expiryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(end.timeIntervalSinceNow))
            guard !Task.isCancelled else { return }
            await self?.stop(reason: tr("已到设定时间，防休眠已关闭"))
        }
    }

    private func show(_ message: String, isError: Bool) {
        if isError { Log.power.error("\(message, privacy: .public)") } else { Log.power.info("\(message, privacy: .public)") }
        notice = message
        noticeIsError = isError
    }
}
