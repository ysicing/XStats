// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later
import AppKit
import CaptureCore
import Localization
import SwiftUI

/// 独立版和内置版设置共用按需扫描入口，不依赖 Capture 是否启用。
public struct CaptureCacheSettingsView: View {
    @State private var usage: CaptureCache.Usage?
    @State private var working = true
    @State private var confirming = false
    @State private var feedback: String?
    @State private var failed = false
    @State private var request = Request()
    @State private var consumedCleanup: UUID?

    private struct Request: Equatable {
        var id = UUID()
        var clean = false
    }

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(tr("截图与录屏缓存")).font(.subheadline.weight(.medium))
                Spacer()
                if working { ProgressView().controlSize(.small).accessibilityLabel(tr("正在计算缓存占用…")) }
                Button { request = Request() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help(tr("刷新")).accessibilityLabel(tr("刷新"))
                    .disabled(working)
            }
            if let usage {
                Text(tr("缓存占用：{}").replacingOccurrences(of: "{}", with: byteText(usage.totalBytes)))
                    .monospacedDigit()
                Text(tr("可清理：{}").replacingOccurrences(of: "{}", with: byteText(usage.reclaimableBytes)))
                    .foregroundStyle(.secondary).monospacedDigit()
            }
            Text(tr("正在使用和最近 1 小时的素材会保留。截图在内存中处理，已保存的文件不受影响。"))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { actions }
                VStack(alignment: .leading, spacing: 8) { actions }
            }
            if let feedback {
                Text(feedback).font(.caption).foregroundStyle(failed ? Color.red : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task(id: request) {
            let current = request
            let clean = current.clean && consumedCleanup != current.id
            if clean { consumedCleanup = current.id }
            await refresh(current, clean: clean)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if !working { request = Request() }
        }
        .alert(tr("清理录屏残留？"), isPresented: $confirming) {
            Button(tr("清理"), role: .destructive) { request = Request(clean: true) }.disabled(working)
            Button(tr("取消"), role: .cancel) {}
        } message: {
            Text(tr("清理后无法恢复这些未保存的录制素材。正在使用、最近 1 小时的素材及已保存文件会保留。"))
        }
    }

    @ViewBuilder private var actions: some View {
        Button(tr("在访达中显示")) { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: CaptureCache.directory.path) }
            .disabled(usage == nil || usage?.totalBytes == 0)
        Button(tr("清理录屏残留")) { confirming = true }
            .disabled(working || (usage?.reclaimableSessions ?? 0) == 0)
    }

    private func byteText(_ bytes: Int64) -> String {
        bytes.formatted(.byteCount(style: .file).locale(L10n.locale))
    }

    @MainActor private func refresh(_ currentRequest: Request, clean: Bool) async {
        working = true
        failed = false
        feedback = nil
        defer { if request == currentRequest { working = false } }
        do {
            if clean {
                let report = try await CaptureCache.cleanUnusedRecordings()
                try Task.checkCancellation()
                feedback = tr("已清理 {} 缓存。").replacingOccurrences(of: "{}", with: byteText(report.removedBytes))
            }
            let current = try await CaptureCache.usage()
            try Task.checkCancellation()
            usage = current
        } catch is CancellationError { }
        catch {
            guard !Task.isCancelled else { return }
            usage = nil
            failed = true
            feedback = tr(clean ? "缓存未能完全清理，请刷新后重试。" : "无法读取缓存占用，请重试。")
            CaptureCache.logger.error("Capture cache operation failed; cleanup: \(clean)")
        }
    }
}
