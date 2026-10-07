// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Localization
import Metrics
import AppKit
import SwiftUI

/// 设备摘要不受诊断采集影响；点击详情时才创建只读任务。
struct AppleIntelligenceStatusRow: View {
    let status: AppleIntelligenceCompatibility

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.s3) {
            HStack(spacing: DS.Space.s1) {
                Text(tr("Apple 智能")).foregroundStyle(DS.Palette.textSecondary)
                AppleIntelligenceDetailsButton()
            }
            Spacer(minLength: 0)
            Text(status.localizedDescription).fontWeight(.medium)
                .help(tr("仅显示本机模型当前是否可用；设备兼容不代表当前可用。"))
        }
        .dsFont(.xs)
        .appLanguageEnvironment()
    }
}

/// 系统信息与进程解释共用同一详情入口，查询只随浮层生命周期运行。
struct AppleIntelligenceDetailsButton: View {
    @State private var showsDetails = false
    @State private var isHovering = false

    var body: some View {
        Button {
            showsDetails = true
        } label: {
            // 内联提示只保留符号，24pt 点击区不画底色或玻璃外圈。
            Image(systemName: "exclamationmark.circle")
                .font(.system(size: DS.TextSize.xs.rawValue, weight: .regular))
                .foregroundStyle(isHovering || showsDetails ? DS.Palette.textPrimary : DS.Palette.textSecondary)
                .frame(width: DS.Size.segmentHeight, height: DS.Size.segmentHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(tr("查看 Apple 智能功能与模型占用"))
        .accessibilityLabel(tr("查看 Apple 智能功能与模型占用"))
        .popover(isPresented: $showsDetails, arrowEdge: .top) {
            AppleIntelligenceDetailsPopover()
        }
    }
}

struct AppleIntelligenceDetailsPopover: View {
    @State private var report: AppleIntelligenceDiagnostics.Report?
    @State private var refreshID = 0
    @State private var isLoading = false
    private let previewReport: AppleIntelligenceDiagnostics.Report?

    init(report: AppleIntelligenceDiagnostics.Report? = nil) {
        previewReport = report
        _report = State(initialValue: report)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s3) {
            HStack {
                Label(tr("Apple 智能详情"), systemImage: "sparkles")
                    .dsFont(.sm, weight: .semibold)
                Spacer()
                Button { refreshID += 1 } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: DS.TextSize.xs.rawValue, weight: .regular))
                        .foregroundStyle(DS.Palette.textSecondary)
                        .frame(width: DS.Size.segmentHeight, height: DS.Size.segmentHeight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(tr("刷新"))
                .accessibilityLabel(tr("刷新"))
                .disabled(isLoading)
            }
            if let report {
                detailRow(tr("本机模型可用性"), value: modelAvailabilityDescription(report.reason))
                ScrollView {
                    VStack(alignment: .leading, spacing: DS.Space.s3) {
                        VStack(alignment: .leading, spacing: DS.Space.s2) {
                            Text(tr("功能配置状态")).dsFont(.xs, weight: .semibold)
                                .help(tr("按设置和限制判断，开启不代表本机模型已就绪"))
                            ForEach(report.features) { feature in
                                detailRow(tr(feature.title), value: tr(feature.state.title), muted: feature.state == .unknown)
                            }
                        }
                        Divider()
                        VStack(alignment: .leading, spacing: DS.Space.s2) {
                            Text(tr("磁盘上的模型")).dsFont(.xs, weight: .semibold)
                            ForEach(report.models) { model in
                                detailRow(tr(model.title), value: sizeDescription(model.bytes), muted: model.bytes == nil)
                            }
                            Divider()
                            detailRow(tr("模型总计"), value: AppleIntelligenceDiagnostics.total(report.models.map(\.bytes))
                                      .map { Format.bytes(UInt64($0), base: .decimal) } ?? tr("无法检测"))
                        }
                        if let issue = report.inventoryIssue {
                            Text(tr(issue)).dsFont(.xs).foregroundStyle(DS.Palette.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                // 原生 Popover 以理想尺寸布局；只有最大高度时，加载后的滚动区会被压到零。
                .frame(height: maximumContentHeight)
            } else {
                HStack(spacing: DS.Space.s2) {
                    ProgressView().controlSize(.small)
                    Text(tr("正在读取…")).dsFont(.xs).foregroundStyle(DS.Palette.textSecondary)
                }
                .frame(height: 80)
            }
        }
        .padding(DS.Space.s4)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
        .appLanguageEnvironment()
        .task(id: refreshID) {
            guard previewReport == nil else { return }
            isLoading = true
            do {
                let result = try await AppleIntelligenceDiagnostics.load()
                try Task.checkCancellation()
                report = result
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                report = .unreadable
            }
            isLoading = false
        }
    }

    private func detailRow(_ title: String, value: String, muted: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.s3) {
            Text(title).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: DS.Space.s2)
            Text(value).monospacedDigit().fixedSize()
                .foregroundStyle(muted ? DS.Palette.textTertiary : DS.Palette.textPrimary)
        }
        .dsFont(.xs)
    }

    private var maximumContentHeight: CGFloat {
        let screen = NSApp.keyWindow?.screen ?? NSScreen.main
        return min(520, max(220, (screen?.visibleFrame.height ?? 780) - 120))
    }

    private func sizeDescription(_ bytes: Int64?) -> String {
        guard let bytes, bytes >= 0 else { return tr("无法检测") }
        return bytes == 0 ? tr("未安装") : Format.bytes(UInt64(bytes), base: .decimal)
    }

    private func modelAvailabilityDescription(_ reason: String) -> String {
        switch reason {
        case "本机模型已就绪": tr("可用")
        case "Apple 智能本机模型当前不可用。", "Apple 智能暂时不可用。": tr("不可用")
        case "请先在“系统设置 → Apple 智能与 Siri”中开启 Apple 智能。": tr("未开启")
        case "Apple 智能模型还在下载或准备中，请稍后再试。": tr("模型未就绪")
        default: tr(reason)
        }
    }
}

extension AppleIntelligenceDiagnostics.FeatureState {
    var title: String {
        switch self {
        case .on: "已开启"
        case .off: "已关闭"
        case .lockedOff: "已关闭（受管理）"
        case .unknown: "无法检测"
        }
    }
}
