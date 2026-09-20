import Localization
import Metrics
import SMC
import SwiftUI

struct ThermalPage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        PageScroll {
            HStack(alignment: .top, spacing: DS.Space.s3) {
                TemperatureCard().frame(maxWidth: .infinity)
                FanCard().frame(maxWidth: .infinity)
            }
            .fixedSize(horizontal: false, vertical: true)
            PowerCard()
            FanSafetySettings()
        }
    }
}

private struct TemperatureCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let summaries = model.store.sensors?.temperatures ?? []
        let sensorCount = summaries.reduce(0) { $0 + $1.sensorCount }

        Card {
            CardHeader(icon: "thermometer.medium", title: tr("温度"),
                       detail: summaries.isEmpty ? tr("读取中") : tr("\(sensorCount) 个传感器"))
            if summaries.isEmpty {
                PlaceholderLine()
            } else {
                ForEach(summaries) { summary in
                    TemperatureRow(summary: summary, fahrenheit: model.settings.useFahrenheit)
                }
            }
        }
    }
}

private struct TemperatureRow: View {
    let summary: TemperatureSummary
    let fahrenheit: Bool

    var body: some View {
        let tone = Tone.forTemperature(summary.maximum)
        VStack(alignment: .leading, spacing: DS.Space.s1) {
            HStack(spacing: DS.Space.s3) {
                Text(summary.group.title)
                    .dsFont(.sm, weight: .medium)
                    .foregroundStyle(DS.Palette.textPrimary)
                    .frame(width: DS.Size.labelColumn, alignment: .leading)
                ProgressTrack(fraction: summary.maximum / DS.Thermal.scaleMax, color: tone.color)
                Text(Format.temperature(summary.maximum, fahrenheit: fahrenheit))
                    .dsFont(.sm, weight: .semibold)
                    .monospacedDigit()
                    .foregroundStyle(DS.Palette.textPrimary)
                    .frame(width: DS.Size.valueColumn, alignment: .trailing)
            }
            if summary.sensorCount > 1 {
                Text(tr("平均 \(Format.temperature(summary.average, fahrenheit: fahrenheit)) · 最高 \(Format.temperature(summary.maximum, fahrenheit: fahrenheit))"))
                    .dsFont(.xs)
                    .foregroundStyle(DS.Palette.textTertiary)
                    .padding(.leading, DS.Size.labelColumn + DS.Space.s3)
            }
        }
    }
}

private struct PowerCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let power = model.store.power
        Card {
            CardHeader(icon: "bolt", title: tr("功耗"), detail: power?.system.map { tr("整机 \(Format.watts($0))") } ?? tr("读取中"))
            PowerRows(power: power, history: model.store.powerHistory.elements)
        }
    }
}

private struct FanCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let fans = model.store.sensors?.fans ?? []
        let controller = model.fans

        Card {
            CardHeader(icon: "fan", title: tr("风扇")) {
                if !fans.isEmpty {
                    StatusBadge(text: fans.contains(where: \.isManual)
                                    ? (controller.mode == .automatic ? tr("其他程序控制") : tr("XStats 控制"))
                                    : tr("系统自动"),
                                tone: fans.contains(where: \.isManual) ? .primary : .neutral)
                }
            }

            if fans.isEmpty {
                Text(model.store.sensors == nil ? tr("正在读取风扇…") : tr("此设备没有可调节的风扇"))
                    .dsFont(.sm)
                    .foregroundStyle(DS.Palette.textSecondary)
            } else {
                ForEach(fans) { fan in
                    FanRow(fan: fan, name: name(for: fan, count: fans.count))
                }

                HairlineDivider()

                Text(tr("调速模式"))
                    .dsFont(.sm, weight: .semibold)
                    .foregroundStyle(DS.Palette.textPrimary)

                SegmentedControl(selection: modeBinding, options: FanController.Mode.allCases.map { ($0, $0.title) })
                    .disabled(!model.helper.isReady || controller.isApplying)

                if controller.mode == .custom {
                    CustomLevelControl(fans: fans)
                }

                if model.helper.needsAttention {
                    HelperRequiredBanner(text: tr("调节风扇需要安装辅助工具，仅需管理员授权一次。"))
                }

                if let notice = controller.notice {
                    InfoBanner(icon: controller.noticeIsError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill",
                               text: notice,
                               tone: controller.noticeIsError ? .error : .success)
                }

                Text(verbatim: tr("自定义模式下 CPU 达到 \(model.settings.fanSafetyTemperature)°C 会自动交还系统控制；退出应用时风扇恢复自动。"))
                    .dsFont(.xs)
                    .foregroundStyle(DS.Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var modeBinding: Binding<FanController.Mode> {
        Binding(get: { model.fans.mode },
                set: { mode in Task { await model.fans.select(mode) } })
    }

    private func name(for fan: FanState, count: Int) -> String {
        guard count == 2 else { return tr("风扇 \(fan.id + 1)") }
        return fan.id == 0 ? tr("左侧风扇") : tr("右侧风扇")
    }
}

private struct FanRow: View {
    let fan: FanState
    let name: String

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s1) {
            HStack {
                Text(name).dsFont(.sm, weight: .medium).foregroundStyle(DS.Palette.textPrimary)
                Spacer()
                Text(Format.rpm(fan.current))
                    .dsFont(.sm, weight: .semibold)
                    .monospacedDigit()
                    .foregroundStyle(DS.Palette.textPrimary)
            }
            ProgressTrack(fraction: fan.fraction, color: DS.Palette.secondary)
            Text(verbatim: tr("最低 \(Int(fan.minimum)) · 最高 \(Int(fan.maximum)) · 目标 \(Int(fan.target)) RPM"))
                .dsFont(.xs)
                .monospacedDigit()
                .foregroundStyle(DS.Palette.textTertiary)
        }
    }
}

private struct CustomLevelControl: View {
    @Environment(AppModel.self) private var model
    let fans: [FanState]

    var body: some View {
        @Bindable var controller = model.fans
        let reference = fans.first
        let rpm = reference.map { model.fans.targetRPM(for: $0) } ?? 0

        VStack(alignment: .leading, spacing: DS.Space.s2) {
            HStack {
                Text(tr("目标转速")).dsFont(.xs).foregroundStyle(DS.Palette.textSecondary)
                Spacer()
                Text(tr("\(Format.percent(controller.customLevel)) · 约 \(Format.rpm(rpm))"))
                    .dsFont(.xs, weight: .semibold)
                    .monospacedDigit()
                    .foregroundStyle(DS.Palette.textPrimary)
            }
            DSSlider(value: $controller.customLevel) {
                Task { await model.fans.commitCustomLevel() }
            }
            HStack {
                Text(tr("安静")).dsFont(.xs).foregroundStyle(DS.Palette.textTertiary)
                Spacer()
                Text(tr("最强")).dsFont(.xs).foregroundStyle(DS.Palette.textTertiary)
            }
        }
    }
}

struct HelperRequiredBanner: View {
    @Environment(AppModel.self) private var model
    let text: String

    var body: some View {
        InfoBanner(icon: "lock.shield", text: bannerText, tone: .warning) {
            switch model.helper.status {
            case .notInstalled:
                Button(tr("安装")) { model.helper.install() }
                    .buttonStyle(DSButtonStyle(kind: .primary))
                    .disabled(model.helper.isWorking)
            case .requiresApproval:
                Button(tr("去批准")) { model.helper.openLoginItemsSettings() }
                    .buttonStyle(DSButtonStyle(kind: .primary))
            case .enabled where model.helper.isOutdated:
                Button(tr("重新安装")) { Task { await model.helper.reinstall() } }
                    .buttonStyle(DSButtonStyle(kind: .primary))
                    .disabled(model.helper.isWorking)
            case .enabled, .unavailable:
                EmptyView()
            }
        }
    }

    private var bannerText: String {
        switch model.helper.status {
        case .requiresApproval: tr("请在“系统设置 › 通用 › 登录项”中允许 XStats 的后台项目。")
        case .unavailable(let reason): reason
        case .enabled where model.helper.isOutdated: HelperClient.outdatedMessage
        default: text
        }
    }
}
