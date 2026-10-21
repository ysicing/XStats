// SPDX-License-Identifier: AGPL-3.0-or-later
import AppKit

/// 用原生路径和 SF Symbols 绘制固定大小的单图标；没有常驻动画或独立刷新循环。
@MainActor
enum TrioIconRenderer {
  static func image(reading: TrioReading, configuration: TrioConfiguration, dark: Bool) -> NSImage {
    let colored =
      configuration.footer == .aiUsage
      || configuration.statusColors && configuration.sources.contains(.battery)
        && (reading.charging || reading.pluggedIn || reading.lowPower
          || (reading.values[.battery] ?? 1) <= 0.2)
      || (configuration.sources.contains(.audio)
        || (configuration.center == .network
          && reading.centerSymbol(configuration) == reading.audioSymbol))
        && reading.usesBlueVolume(configuration)
    let foreground: NSColor = colored && dark ? .white : .black
    let image = NSImage(size: NSSize(width: 24, height: 22), flipped: false) { _ in
      let outerColor = color(
        for: configuration.outer, reading: reading, configuration: configuration,
        foreground: foreground)
      let footerColor = color(
        for: configuration.footer.source, reading: reading, configuration: configuration,
        foreground: foreground)
      drawOuter(reading, configuration, foreground: foreground, active: outerColor)
      drawCenter(reading, configuration, foreground: foreground)
      drawFooter(reading, configuration, foreground: foreground, active: footerColor)
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
    for source: TrioSource, reading: TrioReading, configuration: TrioConfiguration,
    foreground: NSColor
  ) -> NSColor {
    if source == .audio, reading.usesBlueVolume(configuration) { return .systemBlue }
    guard configuration.statusColors, source == .battery, reading.values[.battery] != nil else {
      return foreground
    }
    if reading.values[.battery]! < 0.2 { return .systemRed }
    if reading.lowPower { return .systemYellow }
    if reading.charging || reading.pluggedIn { return .systemGreen }
    return foreground
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

  private static func fraction(_ source: TrioSource, reading: TrioReading) -> Double? {
    if source == .network {
      if reading.connection == .unknown { return nil }
      return reading.connection.isError ? 0 : 1
    }
    guard reading.isProportional(source), let value = reading.values[source], value.isFinite else {
      return nil
    }
    return min(1, max(0, value))
  }

  private static func drawOuter(
    _ reading: TrioReading, _ config: TrioConfiguration, foreground: NSColor, active: NSColor
  ) {
    let source = config.outer
    guard source != .none else { return }
    let center = NSPoint(x: 11.8, y: 10.6)
    for (start, end): (CGFloat, CGFloat) in [(210, 112), (68, -30)] {
      arc(
        center: center, radius: 8.7, start: start, end: end,
        color: foreground.withAlphaComponent(0.23), width: 1.65)
    }
    if let fraction = fraction(source, reading: reading) {
      let degrees = fraction * 196
      arc(
        center: center, radius: 8.7, start: 210, end: 210 - min(98, degrees), color: active,
        width: 1.65)
      if degrees > 98 {
        arc(
          center: center, radius: 8.7, start: 68, end: 68 - (degrees - 98), color: active,
          width: 1.65)
      }
    }
    if source == .battery, reading.values[source] != nil,
      reading.charging || reading.pluggedIn, !config.showsValueWhenPluggedIn
    {
      symbol(
        reading.charging ? "bolt.fill" : "powerplug.fill",
        in: NSRect(x: 9, y: 16.5, width: 6, height: 5.5), color: active)
    } else if config.showsValue {
      if source == .network {
        symbol(
          reading.networkSymbol(config), in: NSRect(x: 8.5, y: 16.5, width: 7, height: 5),
          color: foreground)
      } else {
        text(
          reading.shortValue(source), in: NSRect(x: 5, y: 15.3, width: 14, height: 7), size: 7,
          color: foreground)
      }
    }
  }

  private static func drawCenter(
    _ reading: TrioReading, _ config: TrioConfiguration, foreground: NSColor
  ) {
    let source = config.center
    guard source != .none else { return }
    let rect = NSRect(x: 6.8, y: 6.7, width: 10, height: 9)
    if source == .network || source == .audio {
      let isBluetooth = source == .audio || reading.centerSymbol(config) == reading.audioSymbol
      let color: NSColor = isBluetooth && reading.usesBlueVolume(config) ? .systemBlue : foreground
      var opacity: CGFloat = 1
      var variable: Double?
      if source == .network, !isBluetooth {
        if case .wifi(let bars) = reading.connection { variable = Double(bars) / 3 }
        if reading.connection == .unassociated { variable = 0 }
        if reading.connection == .unknown { opacity = 0.4 }
      }
      symbol(
        reading.centerSymbol(config), in: rect, color: color.withAlphaComponent(opacity),
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
    let value =
      config.footer == .fan
      ? reading.fanFraction : (reading.muted ? 0 : fraction(.audio, reading: reading))
    if config.footerStyle == .arc {
      let center = NSPoint(x: 11.8, y: 10.6)
      arc(
        center: center, radius: 8.7, start: -62, end: -118,
        color: foreground.withAlphaComponent(0.23), width: 1.65)
      if let value {
        arc(
          center: center, radius: 8.7, start: -62, end: -62 - 56 * value, color: active, width: 1.65
        )
      }
    } else {
      let points: [NSPoint] = [
        NSPoint(x: 7, y: 3.1), NSPoint(x: 10.2, y: 1.9), NSPoint(x: 13.5, y: 1.9),
        NSPoint(x: 16.7, y: 3.1),
      ]
      let count = value.map { $0 > 0 ? Int(ceil($0 * 4)) : 0 } ?? 0
      for (index, point) in points.enumerated() {
        (index < count ? active : foreground.withAlphaComponent(0.23)).setFill()
        NSBezierPath(ovalIn: NSRect(x: point.x - 0.9, y: point.y - 0.9, width: 1.8, height: 1.8))
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

  /// 一点对应一个服务，扇形面积表示剩余额度；零额度留原色边框，未知额度为灰色空心。
  private static func drawAIDots(_ dots: [TrioReading.AIDot], foreground: NSColor) {
    guard !dots.isEmpty else {
      foreground.withAlphaComponent(0.23).setStroke()
      let empty = NSBezierPath(ovalIn: NSRect(x: 10.65, y: 0.75, width: 2.3, height: 2.3))
      empty.lineWidth = 0.4
      empty.stroke()
      return
    }
    let visible = Array(dots.prefix(4))
    for (index, dot) in visible.enumerated() {
      let x = 11.8 + (CGFloat(index) - CGFloat(visible.count - 1) / 2) * 3.3
      let y: CGFloat = visible.count >= 3 && (index == 0 || index == visible.count - 1) ? 3.1 : 1.9
      let center = NSPoint(x: x, y: y)
      let radius: CGFloat = 1.15
      let circle = NSBezierPath(
        ovalIn: NSRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2))
      let color = AIServiceBrand.dotColor(dot.name, foreground: foreground)
      foreground.withAlphaComponent(0.18).setFill()
      circle.fill()
      if let fraction = dot.fraction, fraction.isFinite {
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
      circle.lineWidth = 0.4
      circle.stroke()
    }
  }

  private static func text(_ value: String, in rect: NSRect, size: CGFloat, color: NSColor) {
    let font = NSFont.monospacedDigitSystemFont(ofSize: size, weight: .semibold)
    let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
    let string = value as NSString
    let measured = string.size(withAttributes: attributes)
    // 阿拉伯数字和三位数可稍收紧，但不改变整个图标宽度。
    let scale = min(1, rect.width / max(1, measured.width))
    NSGraphicsContext.saveGraphicsState()
    let transform = AffineTransform(
      translationByX: rect.midX - measured.width * scale / 2,
      byY: rect.midY - measured.height * scale / 2)
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
