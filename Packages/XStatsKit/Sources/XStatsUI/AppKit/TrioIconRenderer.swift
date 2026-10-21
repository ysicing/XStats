// SPDX-License-Identifier: AGPL-3.0-or-later
import AppKit

/// 用原生路径和 SF Symbols 绘制固定大小的单图标；没有常驻动画或独立刷新循环。
@MainActor
enum TrioIconRenderer {
  /// 程序坞沿用菜单栏的矢量内容，用固定浅色底保持不同桌面背景下的可读性。
  static func dockImage(reading: TrioReading, configuration: TrioConfiguration) -> NSImage {
    let content = image(reading: reading, configuration: configuration, dark: false)
    content.isTemplate = false
    let image = NSImage(size: NSSize(width: 256, height: 256), flipped: false) { _ in
      let tile = NSBezierPath(
        roundedRect: NSRect(x: 16, y: 16, width: 224, height: 224), xRadius: 48, yRadius: 48)
      NSColor.white.setFill()
      tile.fill()
      NSColor.black.withAlphaComponent(0.08).setStroke()
      tile.lineWidth = 1
      tile.stroke()
      content.draw(in: NSRect(x: 32, y: 40, width: 192, height: 176))
      return true
    }
    image.accessibilityDescription = content.accessibilityDescription
    return image
  }

  static func image(reading: TrioReading, configuration: TrioConfiguration, dark: Bool) -> NSImage {
    let outerColor = color(for: configuration.outer, reading: reading, configuration: configuration)
    let footerColor = color(
      for: configuration.footer.source, reading: reading, configuration: configuration)
    let colored =
      configuration.footer == .aiUsage
      || outerColor != nil || footerColor != nil
      || (configuration.sources.contains(.audio)
        || (configuration.center == .network
          && configuration.bluetoothDeviceID == nil
          && reading.bluetoothReplacementSymbol(configuration) != nil))
        && reading.usesBlueVolume(configuration)
    let foreground: NSColor = colored && dark ? .white : .black
    let image = NSImage(size: NSSize(width: 24, height: 22), flipped: false) { _ in
      drawOuter(reading, configuration, foreground: foreground, active: outerColor ?? foreground)
      drawCenter(reading, configuration, foreground: foreground)
      drawFooter(reading, configuration, foreground: foreground, active: footerColor ?? foreground)
      if reading.keepAwake {
        symbol(
          "cup.and.saucer.fill", in: NSRect(x: 20, y: 18, width: 4, height: 4), color: foreground)
      }
      return true
    }
    image.isTemplate = !colored
    image.accessibilityDescription = reading.tooltip(configuration)
    return image
  }

  private static func color(
    for source: TrioSource, reading: TrioReading, configuration: TrioConfiguration
  ) -> NSColor? {
    if source == .audio, reading.usesBlueVolume(configuration) { return .systemBlue }
    guard configuration.statusColors else { return nil }
    if let level = reading.usageLevel(source) {
      switch level {
      case .normal: return .systemGreen
      case .warning: return .systemOrange
      case .critical: return .systemRed
      }
    }
    guard source == .battery, let level = reading.values[.battery], level.isFinite else {
      return nil
    }
    switch LoadLevel.remaining(level) {
    case .critical: return .systemRed
    case .warning: return .systemOrange
    case .normal: break
    }
    if reading.lowPower { return .systemYellow }
    if reading.charging || reading.pluggedIn { return .systemGreen }
    return nil
  }

  private static func arc(
    center: NSPoint, radius: CGFloat, start: CGFloat, end: CGFloat, color: NSColor, width: CGFloat
  ) {
    guard abs(start - end) > 0.01 else { return }
    let path = NSBezierPath()
    path.lineWidth = width
    path.lineCapStyle = .round
    path.appendArc(
      withCenter: center, radius: radius, startAngle: start, endAngle: end, clockwise: true)
    color.setStroke()
    path.stroke()
  }

  private static func drawOuter(
    _ reading: TrioReading, _ config: TrioConfiguration, foreground: NSColor, active: NSColor
  ) {
    let source = config.outer
    guard source != .none else { return }
    let center = NSPoint(x: 12, y: 10.5)
    let radius: CGFloat = 9
    let powerSymbol = reading.batteryPowerSymbol(config)
    let topScale: CGFloat = source == .battery ? config.effectiveBatteryTopScale : 1
    let value = reading.shortValue(source)
    let fontSize: CGFloat = (value.count > 2 ? 7 : 8) * topScale
    let font = NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .bold)
    // 缺口按实际文字宽度留白，避免两位数和 100 与圆弧相交；没有顶部内容时连接整段圆环。
    let labelWidth: CGFloat =
      if powerSymbol != nil { 7 * topScale } else if config.showsValue {
        min(18, (value as NSString).size(withAttributes: [.font: font]).width)
      } else { 0 }
    let angle: CGFloat =
      labelWidth > 0
      ? acos(min(1, (labelWidth / 2 + 1) / radius)) * 180 / .pi : 90
    let sweep = 30 + angle
    for (start, end): (CGFloat, CGFloat) in [(210, 180 - angle), (angle, -30)] {
      arc(
        center: center, radius: radius, start: start, end: end,
        color: foreground.withAlphaComponent(0.28), width: 1.9)
    }
    if let fraction = reading.outerFraction(source) {
      let degrees = fraction * sweep * 2
      arc(
        center: center, radius: radius, start: 210, end: 210 - min(sweep, degrees), color: active,
        width: 1.9)
      if degrees > sweep {
        arc(
          center: center, radius: radius, start: angle, end: angle - (degrees - sweep),
          color: active,
          width: 1.9)
      }
    }
    if let powerSymbol {
      symbol(
        powerSymbol,
        in: NSRect(
          x: 12 - 3.5 * topScale, y: 22 - 6.5 * topScale,
          width: 7 * topScale, height: 6.5 * topScale),
        color: active)
    } else if config.showsValue {
      if source == .network {
        symbol(
          reading.networkSymbol(config), in: NSRect(x: 8.5, y: 16.5, width: 7, height: 5),
          color: foreground)
      } else {
        text(
          value, in: NSRect(x: 3, y: 14, width: 18, height: 8), size: fontSize,
          color: foreground)
      }
    }
  }

  private static func drawCenter(
    _ reading: TrioReading, _ config: TrioConfiguration, foreground: NSColor
  ) {
    let source = config.center
    guard source != .none else { return }
    var rect = NSRect(x: 6, y: 5.5, width: 12, height: 10)
    if source == .network || source == .audio {
      let replacement = reading.bluetoothReplacementSymbol(config) != nil
      let name = reading.centerSymbol(config)
      let scale: Double =
        if replacement {
          config.effectiveBluetoothIconScale
        } else if source == .network && name.hasPrefix("wifi") {
          config.effectiveWiFiIconScale
        } else { 1 }
      if scale != 1 {
        // 顶边固定，缩放限制在外环内，避免向上侵入顶部数值。
        rect = NSRect(
          x: 12 - 6 * scale, y: 15.5 - 10 * scale, width: 12 * scale, height: 10 * scale)
      }
      let isAudio = source == .audio || (replacement && config.bluetoothDeviceID == nil)
      let color: NSColor = isAudio && reading.usesBlueVolume(config) ? .systemBlue : foreground
      var opacity: CGFloat = 1
      var variable: Double?
      if source == .network, !replacement {
        if case .wifi(let bars) = reading.connection { variable = Double(bars) / 3 }
        if reading.connection == .unassociated { variable = 0 }
        if reading.connection == .unknown { opacity = 0.4 }
      }
      symbol(
        name, in: rect, color: color.withAlphaComponent(opacity),
        variable: variable)
    } else if source == .display {
      symbol(source.item!.symbol, in: rect, color: foreground)
    } else {
      text(reading.shortValue(source), in: rect, size: 8, color: foreground)
    }
  }

  private static func drawFooter(
    _ reading: TrioReading, _ config: TrioConfiguration, foreground: NSColor, active: NSColor
  ) {
    if config.footer == .aiUsage {
      drawAIDots(reading.aiDots, foreground: foreground)
      return
    }
    let value = reading.footerFraction(config)
    if config.footerStyle == .arc {
      let center = NSPoint(x: 12, y: 10.5)
      arc(
        center: center, radius: 9, start: -62, end: -118,
        color: foreground.withAlphaComponent(0.28), width: 1.9)
      if let value {
        arc(
          center: center, radius: 9, start: -62, end: -62 - 56 * value, color: active, width: 1.9
        )
      }
    } else {
      let points: [NSPoint] = [
        NSPoint(x: 6.8, y: 3.1), NSPoint(x: 10.3, y: 1.9), NSPoint(x: 13.7, y: 1.9),
        NSPoint(x: 17.2, y: 3.1),
      ]
      let count = value.map { $0 > 0 ? Int(ceil($0 * 4)) : 0 } ?? 0
      for (index, point) in points.enumerated() {
        (index < count ? active : foreground.withAlphaComponent(0.28)).setFill()
        NSBezierPath(ovalIn: NSRect(x: point.x - 1.15, y: point.y - 1.15, width: 2.3, height: 2.3))
          .fill()
      }
    }
    if value == nil {
      text("—", in: NSRect(x: 8, y: 0, width: 8, height: 5), size: 5, color: foreground)
    } else if config.footer == .audio, reading.muted {
      // 静音与音量为零保持不同的图形，避免只依赖悬停提示区分。
      let path = NSBezierPath()
      path.move(to: NSPoint(x: 8.8, y: 0.5))
      path.line(to: NSPoint(x: 15, y: 4))
      path.lineWidth = 0.8
      foreground.setStroke()
      path.stroke()
    }
  }

  /// 固定保留四个位置，扇形面积和颜色表示剩余额度；未启用或未知额度为灰色空心。
  private static func drawAIDots(_ dots: [TrioReading.AIDot], foreground: NSColor) {
    for index in 0..<4 {
      let fraction = dots.indices.contains(index) ? dots[index].imageFraction : nil
      let x = 12 + (CGFloat(index) - 1.5) * 3.4
      let y: CGFloat = index == 0 || index == 3 ? 3.1 : 1.9
      let center = NSPoint(x: x, y: y)
      let radius: CGFloat = 1.25
      let circle = NSBezierPath(
        ovalIn: NSRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2))
      foreground.withAlphaComponent(0.18).setFill()
      circle.fill()
      if let fraction, fraction.isFinite {
        let color: NSColor =
          switch fraction {
          case ..<0.1: .systemRed
          case ..<0.2: .systemOrange
          case ..<0.5: .systemBlue
          default: .systemGreen
          }
        color.setFill()
        if fraction >= 1 {
          circle.fill()
        } else if fraction > 0 {
          let progress = NSBezierPath()
          progress.move(to: center)
          progress.appendArc(
            withCenter: center, radius: radius, startAngle: 90, endAngle: 90 - 360 * fraction,
            clockwise: true)
          progress.close()
          progress.fill()
        }
        color.setStroke()
      } else {
        foreground.withAlphaComponent(0.35).setStroke()
      }
      circle.lineWidth = 0.5
      circle.stroke()
    }
  }

  private static func text(_ value: String, in rect: NSRect, size: CGFloat, color: NSColor) {
    let font = NSFont.monospacedDigitSystemFont(ofSize: size, weight: .bold)
    let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
    let string = value as NSString
    let measured = string.size(withAttributes: attributes)
    // 阿拉伯数字和三位数可稍收紧，但不改变整个图标宽度。
    let scale = min(1, rect.width / max(1, measured.width))
    NSGraphicsContext.saveGraphicsState()
    let transform = AffineTransform(
      translationByX: (rect.midX - measured.width * scale / 2).rounded(.toNearestOrEven),
      byY: (rect.midY - measured.height * scale / 2).rounded(.toNearestOrEven))
    (transform as NSAffineTransform).concat()
    let scaling = NSAffineTransform()
    scaling.scale(by: scale)
    scaling.concat()
    string.draw(at: .zero, withAttributes: attributes)
    NSGraphicsContext.restoreGraphicsState()
  }

  private static func symbol(
    _ name: String, in rect: NSRect, color: NSColor, variable: Double? = nil
  ) {
    let image =
      variable.flatMap {
        NSImage(systemSymbolName: name, variableValue: $0, accessibilityDescription: nil)
      }
      ?? NSImage(systemSymbolName: name, accessibilityDescription: nil)
      ?? NSImage(systemSymbolName: "questionmark", accessibilityDescription: nil)
    guard let image else { return }
    let configured =
      image.withSymbolConfiguration(.init(pointSize: rect.height, weight: .semibold)) ?? image
    let scale = min(rect.width / configured.size.width, rect.height / configured.size.height)
    let size = NSSize(width: configured.size.width * scale, height: configured.size.height * scale)
    let target = NSRect(
      x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width,
      height: size.height)
    let tinted = NSImage(size: configured.size, flipped: false) { bounds in
      configured.draw(in: bounds)
      color.setFill()
      bounds.fill(using: .sourceIn)
      return true
    }
    tinted.draw(in: target)
  }
}
