// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Testing
@testable import Localization

struct NetworkPresentationLocalizationTests {
  @Test func trioBatteryOptionsHaveExplicitTranslations() throws {
    let keys = [
      "电池图标", "显示顶部内容", "电源状态显示", "始终显示电量",
      "充电时显示闪电，其余显示电量", "充电时显示闪电，接电时显示插头",
      "电量数字与符号大小",
    ]
    for language in AppLanguage.allCases where language != .system && language != .chinese {
      let table = try #require(Translations.catalog(for: language))
      for key in keys {
        #expect(table.sourceKeys.contains(key), "\(language): \(key)")
        #expect(table.translate(key)?.isEmpty == false, "\(language): \(key)")
      }
    }
  }

  @Test func trioNetworkIconOptionsHaveExplicitTranslations() throws {
    let keys = [
      "网络图标", "蓝牙图标", "Wi-Fi 图标大小", "临时连接使用 Wi-Fi 图标", "互联网共享使用 Wi-Fi 图标",
    ]
    for language in AppLanguage.allCases where language != .system && language != .chinese {
      let table = try #require(Translations.catalog(for: language))
      for key in keys {
        #expect(table.sourceKeys.contains(key), "\(language): \(key)")
        #expect(table.translate(key)?.isEmpty == false, "\(language): \(key)")
      }
    }
  }

  @Test func wirelessDetailsAndOrderingHaveExplicitTranslations() throws {
    let keys = [
      "自定义弹窗内容", "选择各指标弹窗显示的内容，并调整排列顺序。", "弹窗内容", "恢复默认顺序", "拖动以调整顺序", "已显示 {} / {} 项", "链路速率",
      "频段 / 信道", "无线详情", "接入点地址",
      "信道宽度", "无线协议", "安全方式", "噪声", "信噪比", "开放网络", "已展开", "已收起",
      "检测说明", "出口概览",
      "检测 XStats 内 WebKit 暴露的地址，不代表其他浏览器。开始后连接 Cloudflare、Google、BlackBerry、Twilio STUN 与 ipify。",
      "通过 bash.ws 观察本次请求的 DNS 解析服务器；结果受系统代理与分流影响。",
      "点击开始检测，结果仅保留在当前窗口。",
      "检测未完成，请检查网络或稍后重试。",
      "检测已取消",
      "与 HTTP 出口一致",
      "与 HTTP 出口不同，请核对代理路线",
      "未取得 STUN 公网地址，无法判断是否存在泄漏。",
      "检测超时，以下仅为已收到的部分结果。",
      "仅比较同一地址族；地址不同可能来自分流，不直接代表泄漏。",
      "检测服务看到的出口",
      "实际解析服务器",
      "请核对解析服务器是否符合你的 VPN 或 DNS 配置；多个服务器不代表泄漏。",
      "未获取到地址",
      "开始检测",
      "正在检测…",
      "检测完成",
      "系统未提供网络名称或接入点地址，可能受定位权限限制。", "无线链路协商速率，不代表实际下载速度。",
    ]
    for language in AppLanguage.allCases where language != .system && language != .chinese {
      let table = try #require(Translations.catalog(for: language))
      for key in keys {
        #expect(table.sourceKeys.contains(key), "\(language): \(key)")
        #expect(table.translate(key)?.isEmpty == false, "\(language): \(key)")
      }
    }
  }
}
