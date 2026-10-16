// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import Cleaner
import Localization
import Metrics
import SwiftUI

/// 完整审阅仍以目录候选为单位，工具托管的缓存保持整条规则清理。
struct CleanerReviewSheet: View {
  let scan: RuleScan
  let cleaner: CleanerController
  @Environment(\.dismiss) private var dismiss
  @State private var query = ""

  var body: some View {
    let selected = Set(cleaner.selectedItems(in: scan).map(\.id))
    VStack(alignment: .leading, spacing: DS.Space.s3) {
      HStack {
        Text(scan.rule.title).dsFont(.lg, weight: .semibold)
        Spacer()
        MiniIconButton(systemName: "xmark", help: tr("关闭")) { dismiss() }
      }
      if scan.rule.usesToolCleaner {
        Text(tr("由对应工具整体清理，不支持逐项勾选；保留其中任一项目会跳过整条规则。"))
          .dsFont(.sm).foregroundStyle(DS.Palette.textSecondary).fixedSize(
            horizontal: false, vertical: true)
      }
      TextField(tr("搜索名称或路径"), text: $query).textFieldStyle(.roundedBorder)
      ScrollView {
        LazyVStack(alignment: .leading, spacing: DS.Space.s3) {
          ForEach(
            scan.items.filter {
              query.isEmpty || $0.url.path.localizedCaseInsensitiveContains(query)
            }
          ) { item in
            HStack(alignment: .top, spacing: DS.Space.s2) {
              CleanupCheckbox(title: item.url.path, selected: selected.contains(item.id) ? 1 : 0) {
                cleaner.toggle(item, in: scan)
              }
              .frame(width: 24, height: 24)
              .disabled(cleaner.isBusy || scan.rule.usesToolCleaner)
              VStack(alignment: .leading, spacing: DS.Space.s1 / 2) {
                Text(verbatim: item.url.lastPathComponent).dsFont(.sm)
                Text(verbatim: item.url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                  .dsFont(.xs).foregroundStyle(DS.Palette.textSecondary).lineLimit(2)
                  .truncationMode(.middle)
              }
              Spacer(minLength: DS.Space.s2)
              Text(
                verbatim: scan.toolPreview != nil && item.size == 0
                  ? "—" : Format.bytes(item.size, base: .decimal)
              ).dsFont(.xs).monospacedDigit()
              Menu {
                Button(tr("在访达中显示")) { cleaner.reveal(item) }
                Button(tr("始终保留此项目")) { if cleaner.exclude(item.url) { dismiss() } }
                  .disabled(cleaner.isBusy || cleaner.exclusionLimitReached)
                if cleaner.exclusionLimitReached { Text(tr("保留项目已达 50 项上限，请先移除不再需要的保留项。")) }
              } label: {
                Image(systemName: "ellipsis")
              }
              .menuStyle(.borderlessButton).fixedSize().accessibilityLabel(tr("更多操作"))
            }
          }
        }
      }
      .frame(height: 350)
      Text(tr("已选 \(selected.count) 项"))
        .dsFont(.xs).foregroundStyle(DS.Palette.textSecondary)
      if cleaner.exclusionLimitReached {
        Text(tr("保留项目已达 50 项上限，请先移除不再需要的保留项。"))
          .dsFont(.xs).foregroundStyle(DS.Palette.textSecondary).fixedSize(
            horizontal: false, vertical: true)
      }
    }
    .padding(DS.Space.s6).frame(width: 680).appLanguageEnvironment()
  }
}

struct CleanerExclusionsSheet: View {
  let cleaner: CleanerController
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(alignment: .leading, spacing: DS.Space.s3) {
      HStack {
        Text(tr("保留项目")).dsFont(.lg, weight: .semibold)
        Spacer()
        MiniIconButton(systemName: "xmark", help: tr("关闭")) { dismiss() }
      }
      Text(tr("这些项目及其父目录不会被清理；仅保存在这台 Mac。"))
        .dsFont(.sm).foregroundStyle(DS.Palette.textSecondary).fixedSize(
          horizontal: false, vertical: true)
      ScrollView {
        LazyVStack(alignment: .leading, spacing: DS.Space.s3) {
          if cleaner.excludedPaths.isEmpty {
            Text(tr("暂无保留项目")).dsFont(.sm).foregroundStyle(DS.Palette.textSecondary)
          }
          ForEach(cleaner.excludedPaths, id: \.self) { path in
            HStack {
              Text(verbatim: path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                .dsFont(.sm).lineLimit(2).truncationMode(.middle)
              Spacer()
              Button(tr("取消保留")) { cleaner.removeExclusion(path) }
                .buttonStyle(.borderless).disabled(cleaner.isBusy)
            }
          }
        }
      }.frame(height: 240)
      Button(tr("添加保留目录")) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { cleaner.exclude(url) }
      }.buttonStyle(.bordered).disabled(cleaner.isBusy || cleaner.exclusionLimitReached)
      if cleaner.exclusionLimitReached {
        Text(tr("保留项目已达 50 项上限，请先移除不再需要的保留项。"))
          .dsFont(.xs).foregroundStyle(DS.Palette.textSecondary).fixedSize(
            horizontal: false, vertical: true)
      }
    }
    .padding(DS.Space.s6).frame(width: 600).appLanguageEnvironment()
  }
}
