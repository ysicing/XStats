import AppKit
import Localization
import SwiftUI
import Updates

/// 新版本信息：版本号、日期、体积与更新摘要，升级提示窗口与“关于”页共用
struct ReleaseSummary: View {
    let release: UpdateRelease
    let currentVersion: String
    /// 升级提示窗口里限制摘要区高度，超出时滚动；关于页里完整展开
    var notesHeight: CGFloat?
    var showsHeader = true

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s3) {
            if showsHeader { header }

            Text(tr("更新内容")).dsFont(.xs, weight: .medium).foregroundStyle(DS.Palette.textSecondary)
            notes
        }
    }

    private var header: some View {
        HStack(spacing: DS.Space.s3) {
            AppGlyph(size: DS.Space.s12)
            VStack(alignment: .leading, spacing: DS.Space.s1) {
                Text(verbatim: tr("XStats \(release.version) 已发布"))
                    .dsFont(.lg, weight: .semibold)
                    .foregroundStyle(DS.Palette.textPrimary)
                Text(verbatim: tr("当前版本 \(currentVersion) · \(release.date) · \(ByteCountFormatter.string(fromByteCount: release.size, countStyle: .file))"))
                    .dsFont(.xs)
                    .foregroundStyle(DS.Palette.textSecondary)
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var notes: some View {
        let list = VStack(alignment: .leading, spacing: DS.Space.s2) {
            ForEach(Array(release.notes.enumerated()), id: \.offset) { _, note in
                HStack(alignment: .firstTextBaseline, spacing: DS.Space.s2) {
                    Circle().fill(DS.Palette.primary).frame(width: DS.Space.s1 + DS.Space.s1 / 2, height: DS.Space.s1 + DS.Space.s1 / 2)
                        .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + DS.Space.s1 }
                    Text(note).dsFont(.sm).foregroundStyle(DS.Palette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let changelog = release.changelog {
                Button { NSWorkspace.shared.open(changelog) } label: {
                    Text(tr("查看完整更新日志")).dsFont(.sm, weight: .medium).foregroundStyle(DS.Palette.primary)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)

        if let notesHeight {
            ViewThatFits(in: .vertical) {
                list.padding(DS.Space.s3)
                ScrollView { list.padding(DS.Space.s3).overlayScrollers() }
            }
            .frame(maxHeight: notesHeight)
            .background(DS.Palette.surface, in: RoundedRectangle(cornerRadius: DS.Radius.md))
        } else {
            list
        }
    }
}

/// 下载 / 校验 / 安装的进度与失败提示
struct UpdateProgress: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let updates = model.updates
        switch updates.phase {
        case .downloading(let fraction):
            VStack(alignment: .leading, spacing: DS.Space.s2) {
                HStack {
                    Text(tr("正在下载")).dsFont(.xs).foregroundStyle(DS.Palette.textSecondary)
                    Spacer()
                    Text(verbatim: "\(Int((fraction * 100).rounded()))%").dsFont(.xs, weight: .medium).monospacedDigit()
                        .foregroundStyle(DS.Palette.textPrimary)
                }
                ProgressTrack(fraction: fraction)
            }
        case .verifying:
            InfoBanner(icon: "checkmark.shield", text: tr("正在核对校验值、开发者签名与 Apple 公证…"))
        case .installing:
            InfoBanner(icon: "arrow.triangle.2.circlepath", text: tr("正在安装，完成后 XStats 会自动重启。"))
        case .failed(let message):
            InfoBanner(icon: "exclamationmark.triangle", text: message, tone: .error) {
                if updates.release != nil {
                    Button(tr("手动下载")) { updates.openManualDownload() }
                        .buttonStyle(DSButtonStyle(kind: .secondary))
                }
            }
        default:
            EmptyView()
        }
    }
}

/// 自动检查发现新版本时弹出的窗口
struct UpdatePromptView: View {
    @Environment(AppModel.self) private var model
    let close: () -> Void

    var body: some View {
        let updates = model.updates
        VStack(alignment: .leading, spacing: DS.Space.s4) {
            if let release = updates.release {
                ReleaseSummary(release: release, currentVersion: updates.currentVersion, notesHeight: DS.Size.updateNotesHeight)
            }
            UpdateProgress()
            HStack(spacing: DS.Space.s2) {
                if case .downloading = updates.phase {
                    Spacer()
                    Button(tr("取消")) { updates.cancel() }.buttonStyle(DSButtonStyle(kind: .secondary))
                } else {
                    Button(tr("跳过此版本")) {
                        updates.skipCurrentRelease()
                        close()
                    }
                    .buttonStyle(DSButtonStyle(kind: .ghost))
                    Spacer()
                    Button(tr("以后再说"), action: close).buttonStyle(DSButtonStyle(kind: .secondary))
                    Button(tr("一键安装")) { updates.install() }
                        .buttonStyle(DSButtonStyle(kind: .primary))
                        .keyboardShortcut(.defaultAction)
                }
            }
            .disabled(updates.phase == .verifying || updates.phase == .installing)
        }
        .padding(.horizontal, DS.Space.s6)
        .padding(.bottom, DS.Space.s6)
        .padding(.top, DS.Size.windowHeader)
        .frame(width: DS.Size.updateWindowWidth)
        .background(DS.Palette.background)
        .id(model.settings.language)
    }
}

/// 设置 · 关于 里的“软件更新”分组
struct UpdateSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        let updates = model.updates

        SettingsGroup(caption: tr("软件更新")) {
            GroupRow(showsDivider: false) {
                SettingRow(title: statusTitle, subtitle: statusSubtitle) {
                    Button(updates.phase == .checking ? tr("正在检查…") : tr("检查更新")) { updates.check(userInitiated: true) }
                        .buttonStyle(DSButtonStyle(kind: .secondary))
                        .disabled(updates.isBusy)
                }
            }
            GroupRow {
                SettingRow(title: tr("自动检查更新"), subtitle: tr("启动时和之后每天检查一次，发现新版本时显示更新摘要")) {
                    DSToggle(isOn: $settings.autoCheckUpdates, label: tr("自动检查更新"))
                }
            }
            if let release = updates.release {
                GroupRow {
                    VStack(alignment: .leading, spacing: DS.Space.s3) {
                        ReleaseSummary(release: release, currentVersion: updates.currentVersion, showsHeader: false)
                        UpdateProgress()
                        HStack {
                            Spacer()
                            if case .downloading = updates.phase {
                                Button(tr("取消")) { updates.cancel() }.buttonStyle(DSButtonStyle(kind: .secondary))
                            } else {
                                Button(tr("一键安装")) { updates.install() }
                                    .buttonStyle(DSButtonStyle(kind: .primary))
                                    .disabled(updates.isBusy)
                            }
                        }
                    }
                }
            } else if case .failed = updates.phase {
                GroupRow { UpdateProgress() }
            }
        }
    }

    private var statusTitle: String {
        let updates = model.updates
        switch updates.phase {
        case .checking: return tr("正在检查更新")
        case .upToDate: return tr("已是最新版本")
        case .failed where updates.release == nil: return tr("检查更新失败")
        default: return updates.release.map { tr("发现新版本 \($0.version)") } ?? tr("当前版本 \(updates.currentVersion)")
        }
    }

    private var statusSubtitle: String {
        let checked = model.updates.lastChecked.map { tr("上次检查：\($0.formatted(.relative(presentation: .named).locale(L10n.locale)))") } ?? tr("尚未检查")
        guard let release = model.updates.release else { return checked }
        let size = ByteCountFormatter.string(fromByteCount: release.size, countStyle: .file)
        return tr("当前 \(model.updates.currentVersion) · 发布于 \(release.date) · \(size) · \(checked)")
    }
}
