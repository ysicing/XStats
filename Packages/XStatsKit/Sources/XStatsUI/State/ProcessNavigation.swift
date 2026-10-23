// SPDX-License-Identifier: AGPL-3.0-or-later

import Cleaner
import Foundation
import Metrics

enum ProcessNavigationTarget: Equatable {
  case portOwner(PortSocket)
  case application(String)

  var title: String {
    switch self {
    case .portOwner(let socket): "PID \(socket.pid)"
    case .application(let path):
      URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
    }
  }

  var selection: String? {
    if case .portOwner(let socket) = self { return "pid-\(socket.pid)" }
    return nil
  }

  func matches(_ process: ProcessUsage) -> Bool {
    switch self {
    case .portOwner(let socket):
      // 不把 PID 当作模糊搜索，也不把明显已复用给其他程序的 PID 当成原目标。
      process.pid == socket.pid && process.uid == socket.uid && process.name == socket.name
        && process.appBundlePath == socket.appBundlePath
    case .application(let path):
      process.appBundlePath == path
    }
  }
}

extension AppModel {
  static func supportsApplicationNavigation(_ path: String?, home: String = NSHomeDirectory())
    -> Bool
  {
    guard let path else { return false }
    let url = URL(fileURLWithPath: path).standardizedFileURL
    guard url.pathExtension == "app" else { return false }
    // 与应用清单保持相同的目录深度，不为一次跳转扩大扫描范围。
    return AppUninstaller.applicationDirectories(home: home).contains { directory in
      let prefix = directory.standardizedFileURL.path + "/"
      guard url.path.hasPrefix(prefix) else { return false }
      let components = url.path.dropFirst(prefix.count).split(separator: "/")
      guard (1...2).contains(components.count),
        components.allSatisfy({ !$0.hasPrefix(".") })
      else { return false }
      return components.count == 1 || !components[0].hasSuffix(".app")
    }
  }

  func showProcesses(_ target: ProcessNavigationTarget) {
    isPortsSheetPresented = false
    processNavigationTarget = settings.processesEnabled ? target : nil
    if !settings.processesEnabled { featureSettingsTab = .optional }
    settings.panelTab = settings.processesEnabled ? .processes : .settingsFeatures
    if !isMainWindowVisible { openMainWindow(settings.panelTab) }
  }

  func showApplication(_ path: String) {
    guard Self.supportsApplicationNavigation(path) else { return }
    applicationNavigationPath = URL(fileURLWithPath: path).standardizedFileURL.path
    settings.appServicesSection = .apps
    settings.panelTab = .uninstaller
    if !isMainWindowVisible { openMainWindow(.uninstaller) }
  }
}
