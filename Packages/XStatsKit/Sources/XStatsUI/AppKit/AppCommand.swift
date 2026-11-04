// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Localization

/// 只描述应用内已有入口；执行仍由原有路由负责功能开关、权限和忙碌保护。
struct AppCommand: Identifiable {
  enum Action: Equatable {
    case route(AppDeepLink)
    case checkForUpdates
    case toggleMicrophoneMute
    case nextAudioOutput
    case toggleOutputMute
    case findPort(UInt16)
    case findPackage(String)
    case dnsBenchmark
  }

  let id: String
  let title: String
  let symbol: String
  let keywords: String
  let action: Action

  @MainActor static func catalog(supportsFans: Bool) -> [AppCommand] {
    let pages = (PanelTab.monitors + PanelTab.tools + PanelTab.settings).filter {
      $0 != .thermal || supportsFans
    }
    var commands = pages.map { tab in
      AppCommand(
        id: "page.\(tab.rawValue)", title: tab.headerTitle, symbol: tab.symbol,
        keywords: "\(tab.rawValue) \(aliases(for: tab))", action: .route(.open(tab)))
    }
    commands += [
      AppCommand(
        id: "audio.toggleOutputMute", title: tr("切换输出静音"), symbol: "speaker.slash",
        keywords: "output speaker headphones mute unmute 输出 扬声器 耳机 静音 取消静音",
        action: .toggleOutputMute),
      AppCommand(
        id: "audio.toggleMicrophoneMute", title: tr("切换麦克风静音"), symbol: "mic.slash",
        keywords: "microphone mic mute unmute 麦克风 静音 取消静音",
        action: .toggleMicrophoneMute),
      AppCommand(
        id: "audio.nextAudioOutput", title: tr("切换到下一个音频输出"), symbol: "speaker.wave.2",
        keywords: "next audio output device speaker headphones 下一个 音频 输出 设备 扬声器 耳机",
        action: .nextAudioOutput),
      AppCommand(
        id: "calendar", title: tr("打开日历"), symbol: "calendar",
        keywords: "calendar 日历", action: .route(.calendar)),
      AppCommand(
        id: "speedTest", title: tr("网络测速"), symbol: "speedometer",
        keywords: "speed test 测速", action: .route(.speedTest)),
      AppCommand(
        id: "dnsBenchmark", title: tr("DNS 测试"), symbol: "server.rack",
        keywords: "dns benchmark test 域名 解析 测试", action: .dnsBenchmark),
      AppCommand(
        id: "homebrew", title: "Homebrew", symbol: "shippingbox",
        keywords: "brew packages 软件包 包管理", action: .findPackage("")),
      AppCommand(
        id: "egress", title: tr("出口与分流"), symbol: "globe",
        keywords: "egress public ip dns webrtc 出口 公网 分流", action: .route(.egress)),
      AppCommand(
        id: "rest.start", title: tr("开始专注"), symbol: "play",
        keywords: "start focus pomodoro 番茄 开始专注", action: .route(.rest(.start))),
      AppCommand(
        id: "rest.pause", title: tr("暂停专注"), symbol: "pause",
        keywords: "pause focus pomodoro 番茄 暂停专注", action: .route(.rest(.pause))),
      AppCommand(
        id: "keepAwake.start", title: tr("开启防休眠"), symbol: "cup.and.saucer",
        keywords: "start keep awake caffeine 开启防休眠", action: .route(.keepAwake(.start))),
      AppCommand(
        id: "keepAwake.stop", title: tr("停止防休眠"), symbol: "moon",
        keywords: "stop keep awake caffeine 停止防休眠", action: .route(.keepAwake(.stop))),
      AppCommand(
        id: "updates", title: tr("检查更新…"), symbol: "arrow.triangle.2.circlepath",
        keywords: "check updates 检查更新", action: .checkForUpdates),
    ]
    return commands
  }

  private static func aliases(for tab: PanelTab) -> String {
    switch tab {
    case .overview: "dashboard 仪表盘 总览"
    case .system: "hardware display 本机信息 显示器 硬件"
    case .history: "history 历史"
    case .aiUsage: "ai usage tokens AI用量"
    case .cpu: "processor 处理器"
    case .gpu: "graphics 显卡"
    case .memory: "ram 内存"
    case .disk: "storage 磁盘 硬盘"
    case .network: "network 网络"
    case .thermal: "fans 风扇 散热"
    case .battery: "battery energy temperature 电池 能耗 温度"
    case .processes: "processes 进程"
    case .ports: "port ports 端口"
    case .keepAwake: "keep awake caffeine 防休眠"
    case .rest: "timer countdown stopwatch pomodoro 计时 倒计时 秒表 番茄"
    case .cleaner: "clean optimize 清理 优化"
    case .uninstaller, .startupItems: "apps services homebrew startup 应用服务 卸载 启动项 服务"
    case .audio: "audio sound volume 音频 音量"
    case .connections: "network monitor connections 网络监视器 连接"
    case .settingsGeneral: "settings general shortcuts 设置 通用 快捷键"
    case .settingsFeatures: "settings features 设置 功能"
    case .settingsMenuBar: "settings menu bar 设置 菜单栏"
    case .settingsNotifications: "settings notifications 设置 通知"
    case .settingsAccount: "settings sync 设置 同步"
    case .settingsHelper: "settings helper 设置 辅助工具"
    case .settingsAbout: "settings about version 设置 关于 版本"
    }
  }
}

/// 索引仅随面板存活；固定数量的应用命令无需磁盘索引、后台任务或防抖计时器。
struct CommandBarSearch {
  private struct Entry {
    let command: AppCommand
    let title: String
    let text: String
    let pinyin: [String]
  }
  private let entries: [Entry]

  init(commands: [AppCommand]) {
    entries = commands.map {
      let text = "\($0.title) \($0.keywords)"
      return Entry(
        command: $0, title: Self.fold($0.title), text: Self.fold(text),
        pinyin: Self.pinyinTerms(text))
    }
  }

  func results(for query: String) -> [AppCommand] {
    // 大段粘贴不参与搜索，避免在每次输入时处理无界文本。
    guard query.utf8.prefix(2049).count <= 2048 else { return [] }
    let bounded = String(query.prefix(257))
    guard bounded.count <= 256 else { return [] }
    let query = Self.fold(bounded).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return entries.map(\.command) }
    let words = query.split(whereSeparator: \.isWhitespace)
    if let command = words.first, command == "port" || command == "brew" || query == "dns" {
      return parameterResults(command: command, arguments: words.dropFirst())
    }
    return entries.enumerated().compactMap { index, entry -> (Int, Int, AppCommand)? in
      guard
        words.allSatisfy({ word in
          entry.text.contains(word) || entry.pinyin.contains { $0.contains(word) }
        })
      else { return nil }
      let rank: Int
      if entry.title == query {
        rank = 0
      } else if entry.title.hasPrefix(query) {
        rank = 1
      } else if words.allSatisfy({ entry.text.contains($0) }) {
        rank = 2
      } else {
        rank = 3
      }
      return (rank, index, entry.command)
    }
    .sorted { ($0.0, $0.1) < ($1.0, $1.1) }
    .map(\.2)
  }

  private func parameterResults(command: Substring, arguments: ArraySlice<Substring>)
    -> [AppCommand]
  {
    switch command {
    case "port":
      guard let base = entries.first(where: { $0.command.id == "page.ports" })?.command else {
        return []
      }
      guard !arguments.isEmpty else { return [base] }
      guard arguments.count == 1, let argument = arguments.first,
        argument.utf8.allSatisfy({ (48...57).contains($0) }),
        let port = UInt16(argument), port > 0
      else { return [] }
      return [
        AppCommand(
          id: "port.\(port)", title: tr("查询端口：\(port)"), symbol: base.symbol,
          keywords: "", action: .findPort(port))
      ]
    case "brew":
      guard let base = entries.first(where: { $0.command.id == "homebrew" })?.command else {
        return []
      }
      guard !arguments.isEmpty else { return [base] }
      guard arguments.count == 1, let argument = arguments.first,
        let first = argument.utf8.first, (97...122).contains(first) || (48...57).contains(first),
        argument.utf8.allSatisfy({
          (97...122).contains($0) || (48...57).contains($0) || "-_+@./".utf8.contains($0)
        })
      else { return [] }
      let name = String(argument)
      return [
        AppCommand(
          id: "brew.\(name)", title: tr("查找软件包：\(name)"), symbol: base.symbol,
          keywords: "", action: .findPackage(name))
      ]
    case "dns" where arguments.isEmpty:
      return entries.filter { $0.command.id == "dnsBenchmark" }.map(\.command)
    default:
      return []
    }
  }

  private static func pinyinTerms(_ text: String) -> [String] {
    var terms = Set<String>()
    for word in Set(text.split(whereSeparator: \.isWhitespace).map(String.init)) {
      guard word.range(of: #"\p{Han}"#, options: .regularExpression) != nil,
        let latin = word.applyingTransform(.mandarinToLatin, reverse: false)
      else { continue }
      let syllables = fold(latin).split(whereSeparator: \.isWhitespace)
      terms.insert(syllables.joined())
      terms.insert(String(syllables.compactMap(\.first)))
    }
    return terms.sorted()
  }

  private static func fold(_ value: String) -> String {
    value.folding(
      options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
      locale: Locale(identifier: "en_US_POSIX"))
  }
}
