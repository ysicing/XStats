// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Cleaner
import Localization
import Metrics

/// 只汇总当前选中的候选，删除方式直接复用执行引擎的规则。
struct CleanerConfirmation {
  enum Kind { case trashOnly, permanent, recoverable, mixed }
  let kind: Kind
  let permanentCount: Int
  let recoverableCount: Int
  let permanentBytes: UInt64
  let recoverableBytes: UInt64
  let includesHomebrew: Bool
  /// 执行时才会重新检查运行中的应用；数量只是上限，需要在提示中说明。
  let mayBeSkippedWhileAppRunning: Bool

  init(scans: [RuleScan], preferTrash: Bool) {
    let selected = scans.filter { $0.isCleanable }
    let permanent = selected.filter { $0.rule.deletesPermanently(preferTrash: preferTrash) }
    let recoverable = selected.filter { !$0.rule.deletesPermanently(preferTrash: preferTrash) }
    permanentCount = permanent.reduce(0) { $0 + $1.items.count }
    recoverableCount = recoverable.reduce(0) { $0 + $1.items.count }
    permanentBytes = permanent.reduce(0) { $0 + $1.totalSize }
    recoverableBytes = recoverable.reduce(0) { $0 + $1.totalSize }
    includesHomebrew = selected.contains { $0.id == "developer.homebrew" }
    mayBeSkippedWhileAppRunning = selected.contains { $0.rule.mayBeSkippedWhileAppRunning }
    if !selected.isEmpty && selected.allSatisfy({ $0.id == "trash" }) {
      kind = .trashOnly
    } else if permanent.isEmpty {
      kind = .recoverable
    } else if recoverable.isEmpty {
      kind = .permanent
    } else {
      kind = .mixed
    }
  }

  var title: String {
    switch kind {
    case .trashOnly, .permanent: tr("永久删除所选项目？")
    case .recoverable: tr("将所选项目移到废纸篓？")
    case .mixed: tr("确认清理所选项目？")
    }
  }

  var buttonTitle: String {
    switch kind {
    case .trashOnly, .permanent: tr("永久删除")
    case .recoverable: tr("移到废纸篓")
    case .mixed: tr("确认清理")
    }
  }

  var message: String {
    let count = permanentCount.formatted(.number.locale(L10n.locale))
    let size = Format.bytes(permanentBytes, base: .decimal)
    let keptCount = recoverableCount.formatted(.number.locale(L10n.locale))
    let keptSize = Format.bytes(recoverableBytes, base: .decimal)
    let permanent = tr("将永久删除 \(count) 个所选项目，共 \(size)。此操作无法撤销。")
    let recoverable = tr("将把 \(keptCount) 个所选项目移到废纸篓，共 \(keptSize)。需要时可从废纸篓放回。")
    var text: String
    switch kind {
    case .trashOnly:
      text = tr("将永久删除废纸篓中选中的 \(count) 个项目，共 \(size)。此操作无法撤销。")
    case .permanent: text = permanent
    case .recoverable: text = recoverable
    case .mixed: text = permanent + "\n\n" + recoverable
    }
    if includesHomebrew {
      text += "\n\n" + tr("Homebrew 将按执行时的状态清理旧版本与缓存，不自动移除依赖。")
    }
    if mayBeSkippedWhileAppRunning {
      text += "\n\n" + tr("正在运行的应用对应的项目会被跳过，实际处理数量可能少于上述数量。")
    }
    return text
  }
}
