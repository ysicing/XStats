// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit

/// 仅覆盖菜单栏圆点；nil 保留随外观变化的默认色，不把当前外观的颜色固化到偏好。
public struct NetworkMenuColors: Codable, Equatable, Sendable {
  public var upload: UInt32?
  public var download: UInt32?

  public init(upload: UInt32? = nil, download: UInt32? = nil) {
    self.upload = upload
    self.download = download
  }

  var normalized: Self {
    Self(
      upload: upload.flatMap { $0 <= 0xFFFFFF ? $0 : nil },
      download: download.flatMap { $0 <= 0xFFFFFF ? $0 : nil })
  }

  var uploadColor: NSColor {
    normalized.upload.map { NSColor(hex: $0) } ?? DS.NetworkPalette.upload
  }

  var downloadColor: NSColor {
    normalized.download.map { NSColor(hex: $0) } ?? DS.NetworkPalette.download
  }

  /// 统一转为不透明 sRGB，避免设备色彩空间或透明度随备份带到其他机器。
  static func rgb(_ color: NSColor) -> UInt32? {
    guard let rgb = color.usingColorSpace(.sRGB) else { return nil }
    let red = UInt32((min(1, max(0, rgb.redComponent)) * 255).rounded())
    let green = UInt32((min(1, max(0, rgb.greenComponent)) * 255).rounded())
    let blue = UInt32((min(1, max(0, rgb.blueComponent)) * 255).rounded())
    return (red << 16) | (green << 8) | blue
  }
}
