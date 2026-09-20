import Localization
import Metrics
import SwiftUI

struct KeepAwakePage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        PageScroll {
            HeroCard()
            HStack(alignment: .top, spacing: DS.Space.s3) {
                VStack(spacing: DS.Space.s3) {
                    ModeCard()
                    DurationCard()
                }
                .frame(maxWidth: .infinity)
                LidCard().frame(maxWidth: .infinity)
            }
            .fixedSize(horizontal: false, vertical: true)
            LidBatterySettings()
        }
    }
}

private struct HeroCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let keepAwake = model.keepAwake

        Card {
            HStack(spacing: DS.Space.s3) {
                RoundedRectangle(cornerRadius: DS.Radius.md)
                    .fill(keepAwake.isActive ? DS.Palette.primary : DS.Palette.track)
                    .frame(width: DS.Space.s12 - DS.Space.s2, height: DS.Space.s12 - DS.Space.s2)
                    .overlay {
                        Image(systemName: keepAwake.isActive ? "cup.and.saucer.fill" : "cup.and.saucer")
                            .font(.system(size: DS.TextSize.lg.rawValue, weight: .medium))
                            .foregroundStyle(keepAwake.isActive ? DS.Palette.onPrimary : DS.Palette.textSecondary)
                    }
                VStack(alignment: .leading, spacing: DS.Space.s1 / 2) {
                    Text(tr("防休眠"))
                        .dsFont(.lg, weight: .semibold)
                        .foregroundStyle(DS.Palette.textPrimary)
                    StatusLine()
                }
                Spacer()
                DSToggle(isOn: Binding(get: { keepAwake.isActive },
                                       set: { value in Task { await keepAwake.setActive(value) } }),
                         label: tr("防休眠"))
            }

            if let notice = keepAwake.notice {
                InfoBanner(icon: keepAwake.noticeIsError ? "exclamationmark.triangle.fill" : "info.circle.fill",
                           text: notice,
                           tone: keepAwake.noticeIsError ? .error : .primary)
            }
        }
    }
}

private struct StatusLine: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let keepAwake = model.keepAwake
        TimelineView(.periodic(from: .now, by: 30)) { context in
            Text(text(now: context.date))
                .dsFont(.sm)
                .foregroundStyle(keepAwake.isActive ? DS.Palette.primary : DS.Palette.textSecondary)
                .monospacedDigit()
        }
    }

    private func text(now: Date) -> String {
        let keepAwake = model.keepAwake
        guard keepAwake.isActive else { return tr("未开启，Mac 按系统设置休眠") }
        var parts = [keepAwake.mode.title]
        if keepAwake.lidClosedActive { parts.append(tr("合盖运行")) }
        if let end = keepAwake.endDate {
            let minutes = max(1, Int(ceil(end.timeIntervalSince(now) / 60)))
            parts.append(tr("剩余 \(Format.duration(minutes: minutes))"))
        } else {
            parts.append(tr("不限时"))
        }
        return parts.joined(separator: " · ")
    }
}

private struct ModeCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Card {
            Text(tr("模式")).dsFont(.sm, weight: .semibold).foregroundStyle(DS.Palette.textPrimary)
            ForEach(Array(KeepAwakeController.Mode.allCases.enumerated()), id: \.element) { index, mode in
                if index > 0 { HairlineDivider() }
                RadioRow(title: mode.title, subtitle: mode.subtitle, isSelected: model.keepAwake.mode == mode) {
                    model.keepAwake.setMode(mode)
                }
            }
        }
    }
}

private struct LidCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let keepAwake = model.keepAwake

        Card {
            SettingRow(title: tr("合盖后继续运行"),
                       subtitle: tr("合上屏幕时 Mac 不进入睡眠，下载、渲染、远程连接不中断。")) {
                DSToggle(isOn: Binding(get: { keepAwake.lidClosedRequested },
                                       set: { value in Task { await keepAwake.setLidClosed(value) } }),
                         label: tr("合盖后继续运行"))
                    .disabled(!model.helper.isReady)
            }

            if model.helper.needsAttention {
                HelperRequiredBanner(text: tr("合盖运行需要修改系统睡眠设置，需安装辅助工具（管理员授权一次）。"))
            }

            InfoBanner(icon: "exclamationmark.triangle",
                       text: tr("合盖运行时散热变差，请勿放入包中。使用电池且电量低于 \(model.settings.lidModeBatteryFloor)% 时会自动关闭。"),
                       tone: .warning)
        }
    }
}

private struct DurationCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Card {
            Text(tr("持续时间")).dsFont(.sm, weight: .semibold).foregroundStyle(DS.Palette.textPrimary)
            SegmentedControl(selection: Binding(get: { model.keepAwake.duration },
                                                set: { model.keepAwake.setDuration($0) }),
                             options: KeepAwakeController.Duration.allCases.map { ($0, $0.title) })
            Text(tr("到时后自动恢复系统默认的睡眠行为。"))
                .dsFont(.xs)
                .foregroundStyle(DS.Palette.textTertiary)
        }
    }
}
