// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import Localization
import OSLog
import SwiftUI

enum ManualBreakKind: CaseIterable {
  case eye, short, long
  var title: String {
    switch self {
    case .eye: tr("护眼休息")
    case .short: tr("短休息")
    case .long: tr("长休息")
    }
  }
  @MainActor func duration(settings: AppSettings) -> TimeInterval {
    switch self {
    case .eye: Double(settings.wellnessPreferences.normalized.breakSeconds)
    case .short: Double(settings.restBreakMinutes * 60)
    case .long: Double(settings.restLongBreakMinutes * 60)
    }
  }
  @MainActor func menuTitle(settings: AppSettings) -> String {
    title + " · " + WellnessFormat.duration(duration(settings: settings))
  }
}

/// 所有休息入口共用相同操作，避免页面、菜单栏与快捷键出现不同语义。
struct RestActionsMenu: View {
  @Environment(AppModel.self) private var model
  var beforeAction: () -> Void = {}
  var body: some View {
    Menu {
      if model.wellness.isEyeRestActive {
        Button(tr("结束休息")) { model.wellness.finishEyeRest(completed: false) }
      } else {
        ForEach(ManualBreakKind.allCases, id: \.self) { kind in
          Button(kind.menuTitle(settings: model.settings)) {
            beforeAction()
            model.wellness.startBreak(kind)
          }
        }
      }
      Divider()
      Button(tr("关闭显示器")) {
        beforeAction()
        model.wellness.onSleepDisplay?()
      }
    } label: {
      Text(
        tr(model.wellness.isEyeRestActive ? "休息中" : model.wellness.pausesFocus ? "暂停专注并休息" : "开始休息")
      )
    }
    .menuStyle(.borderlessButton).fixedSize()
  }
}

/// 使用系统自带的显示器休眠命令，不更改电源配置、不锁屏、不安排强制唤醒。
@MainActor final class DisplaySleepController {
  private var process: Process?
  private let logger = Logger(subsystem: "work.12306.xstats", category: "DisplaySleep")
  var onFailure: (() -> Void)?
  func sleep() {
    guard process == nil else { return }
    let command = Process()
    command.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
    command.arguments = ["displaysleepnow"]
    command.standardOutput = FileHandle.nullDevice
    command.standardError = FileHandle.nullDevice
    command.terminationHandler = { [weak self] command in
      let status = command.terminationStatus
      Task { @MainActor in
        guard let self else { return }
        self.process = nil
        if status != 0 {
          self.logger.error("Display sleep failed: \(status)")
          self.onFailure?()
        } else {
          self.logger.info("Display sleep requested")
        }
      }
    }
    process = command
    do { try command.run() } catch {
      process = nil
      logger.error("Could not launch display sleep command")
      onFailure?()
    }
  }
}
