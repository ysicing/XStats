import AppKit
import AIUsage
import Localization
import Metrics

struct MenuBarQuota {
  let provider: AIProviderID?
  let window: AIQuotaWindow
  let fetchedAt: Date
  let isStale: Bool
  var magpieName: String? = nil
  var magpieWindow: String? = nil

  var remainingPercent: Int { Int(window.remainingPercent.rounded()) }
  var sourceName: String { magpieName ?? (provider == .codex ? "Codex" : "Claude") }
  var shortWindowName: String {
    if let magpieWindow { return magpieWindow }
    return switch window.kind {
    case .session: "5h"
    default: "7d"
    }
  }

  var resetText: String {
    guard let reset = window.resetsAt else { return "—" }
    return reset.formatted(
      .dateTime.month(.defaultDigits).day().hour().minute().locale(L10n.locale))
  }
}

/// 菜单栏上要画的读数，与数据来源解耦，设置页预览可以用示例数据绘制
struct MenuBarReading {
  var displayCount = 0
  var audioVolume: Double?
  var audioMuted = false
  var audioDeviceName: String?
  var audioSymbol = "speaker.wave.2"
  var cpu: Double?
  var cpuHistory: [Double] = []
  var gpu: Double?
  var gpuHistory: [Double] = []
  var memory: Double?
  var memoryHistory: [Double] = []
  /// 启动磁盘已用占比；用量几乎不变，柱状 / 折线风格画成一条平线
  var disk: Double?
  var diskHistory: [Double] = []
  var upload: Double?
  var download: Double?
  var networkLocationStyle: NetworkLocationStyle = .off
  var networkCountryCode: String?
  var temperature: Double?
  var fanRPM: Double?
  var battery: Double?
  var batteryHistory: [Double] = []
  /// Magpie 今日 Token 总量；统计关闭或还没有数据时为 nil
  var aiTokens: Int?
  var aiUsageShowsLocalUsage = true
  var aiQuotaShowsRemaining = true
  var aiUsageWesternUnits = false
  /// 只有可显示额度的来源才占用菜单栏读数；本机 Token 统计独立于订阅额度。
  var aiQuotas: [MenuBarQuota] = []
  var batteryCharging = false
  /// 附在电池项旁的蓝牙设备：电量低的那一个，或没有电池的 Mac 上电量最低的那一个
  var bluetoothDevice: (symbol: String, percent: Int)?
  var keepAwake = false

  /// 蓝牙设备电量低于这个百分比才在菜单栏提示
  static let lowBluetoothPercent = 20

  /// 只读取展示项目所需的指标，避免单项预览观察无关采样并重复栅格化。
  /// 默认仍提供全部读数，供完整读数调用方使用；防休眠标记与项目无关，始终保留。
  @MainActor
  init(model: AppModel, items: [MenuBarItem] = MenuBarItem.allCases) {
    let store = model.store
    for item in items {
      switch item {
      case .display: displayCount = model.displays.catalog.count
      case .audio:
        audioVolume = model.audio.output?.outputVolume
        audioMuted = model.audio.output?.outputMuted == true
        audioDeviceName = model.audio.output?.name
        audioSymbol = AudioControlPresentation.outputSymbol(model.audio.output, muted: audioMuted)
      case .cpu:
        cpu = store.cpu?.total
        cpuHistory = store.cpuTotal.elements
      case .gpu:
        gpu = store.gpu?.utilization
        gpuHistory = store.gpuHistory.elements
      case .memory:
        memory = store.memory?.usedFraction
        memoryHistory = store.memoryHistory.elements
      case .disk:
        disk = store.disk?.usedFraction
        diskHistory = disk.map { Array(repeating: $0, count: 30) } ?? []
      case .network:
        upload = store.network?.uploadBytesPerSecond
        download = store.network?.downloadBytesPerSecond
        networkLocationStyle =
          model.settings.publicIPLookup ? model.settings.networkLocationStyle : .off
        networkCountryCode = model.network.publicAddresses?.countryCode
      case .temperature:
        temperature = store.sensors?.temperature(.cpu)?.maximum
      case .fan:
        fanRPM = store.fastestFan?.current
      case .battery:
        battery = store.battery?.level
        batteryHistory = battery.map { Array(repeating: $0, count: 30) } ?? []
        batteryCharging = store.battery?.isCharging ?? false
        if let lowest = model.bluetooth.lowest,
          battery == nil
            || (model.settings.bluetoothLowBatteryInMenuBar
              && lowest.percent <= Self.lowBluetoothPercent)
        {
          bluetoothDevice = (lowest.device.kind.symbol, lowest.percent)
        }
      case .aiUsage:
        aiTokens = model.aiUsage.todayTokens
        aiUsageShowsLocalUsage = model.settings.aiUsageShowsLocalUsage
        aiQuotaShowsRemaining = model.settings.aiQuotaShowsRemaining
        aiUsageWesternUnits = model.settings.aiUsageWesternUnits
        aiQuotas = model.aiUsage.menuBarMagpieQuotas()
      }
    }
    keepAwake = model.keepAwake.isActive
  }

  init() {}

  /// 设置页预览用的示例读数：历史给 30 个点，柱状风格取最后 10 个，折线风格用全部
  static let sample: MenuBarReading = {
    var reading = MenuBarReading()
    reading.audioVolume = 0.6
    reading.cpu = 0.34
    reading.cpuHistory = [
      0.12, 0.15, 0.11, 0.20, 0.33, 0.27, 0.19, 0.24, 0.45, 0.38,
      0.30, 0.26, 0.22, 0.35, 0.58, 0.49, 0.41, 0.37, 0.30, 0.25,
      0.18, 0.22, 0.41, 0.36, 0.28, 0.52, 0.47, 0.31, 0.29, 0.34,
    ]
    reading.gpu = 0.22
    reading.gpuHistory = [
      0.02, 0.04, 0.03, 0.08, 0.15, 0.12, 0.09, 0.11, 0.24, 0.20,
      0.14, 0.10, 0.08, 0.17, 0.35, 0.28, 0.22, 0.19, 0.14, 0.10,
      0.05, 0.12, 0.30, 0.18, 0.10, 0.26, 0.40, 0.21, 0.15, 0.22,
    ]
    reading.memory = 0.68
    reading.memoryHistory = Array(repeating: 0.68, count: 30)
    reading.disk = 0.58
    reading.diskHistory = Array(repeating: 0.58, count: 30)
    reading.upload = 12 * 1024
    reading.download = 1.4 * 1024 * 1024
    reading.temperature = 52
    reading.fanRPM = 1840
    reading.battery = 0.82
    reading.batteryHistory = Array(repeating: 0.82, count: 30)
    reading.aiTokens = 1_284_000
    return reading
  }()

  func percent(_ item: MenuBarItem) -> (value: Double?, history: [Double]) {
    switch item {
    case .cpu: (cpu, cpuHistory)
    case .gpu: (gpu, gpuHistory)
    case .memory: (memory, memoryHistory)
    case .disk: (disk, diskHistory)
    case .battery: (battery, batteryHistory)
    default: (nil, [])
    }
  }

  /// 仅比较该项绘图实际使用的读数。历史曲线必须跟随历史更新，静态风格忽略历史变化。
  /// 使用原始数值保守失效，避免颜色阈值、细小图形变化被错误复用。
  func hasSameImage(as previous: Self, item: MenuBarItem, style: MenuBarStyle) -> Bool {
    guard keepAwake == previous.keepAwake else { return false }
    switch item {
    case .display: return displayCount == previous.displayCount
    case .audio:
      return audioVolume == previous.audioVolume && audioMuted == previous.audioMuted
        && (style != .icon || audioSymbol == previous.audioSymbol)
    case .cpu, .gpu, .memory, .disk:
      let current = percent(item)
      let old = previous.percent(item)
      return current.value == old.value
        && (style != .history && style != .line || current.history == old.history)
    case .network:
      return upload == previous.upload && download == previous.download
        && networkLocationStyle == previous.networkLocationStyle
        && (networkLocationStyle == .off || networkCountryCode == previous.networkCountryCode)
    case .temperature:
      return temperature == previous.temperature
    case .fan:
      return fanRPM == previous.fanRPM
    case .battery:
      return battery == previous.battery && batteryCharging == previous.batteryCharging
        && bluetoothDevice?.symbol == previous.bluetoothDevice?.symbol
        && bluetoothDevice?.percent == previous.bluetoothDevice?.percent
        && (style != .history && style != .line || batteryHistory == previous.batteryHistory)
    case .aiUsage:
      guard aiQuotas.isEmpty == previous.aiQuotas.isEmpty else { return false }
      if aiQuotas.isEmpty {
        return aiTokens == previous.aiTokens && aiUsageWesternUnits == previous.aiUsageWesternUnits
      }
      guard aiQuotaShowsRemaining == previous.aiQuotaShowsRemaining else { return false }
      return aiQuotas.elementsEqual(previous.aiQuotas) {
        $0.sourceName == $1.sourceName && $0.shortWindowName == $1.shortWindowName
          && $0.window.remainingPercent == $1.window.remainingPercent
      }
    }
  }

  /// 鼠标悬停时的完整读数
  func tooltip(items: [MenuBarItem], fahrenheit: Bool) -> String {
    items.compactMap { item -> String? in
      switch item {
      case .display: tr("显示器 \(displayCount.formatted(.number.locale(L10n.locale))) 台")
      case .audio:
        [audioDeviceName, audioMuted ? tr("静音") : audioVolume.map { Format.percent($0) }].compactMap
        { $0 }.joined(separator: " · ")
      case .cpu: cpu.map { "CPU \(Format.percent($0))" }
      case .gpu: gpu.map { "GPU \(Format.percent($0))" }
      case .memory: memory.map { tr("内存 \(Format.percent($0))") }
      case .disk: disk.map { tr("磁盘已用 \(Format.percent($0))") }
      case .network:
        [
          upload.flatMap { up in
            download.map { tr("上传 \(Format.menuBarRate(up)) · 下载 \(Format.menuBarRate($0))") }
          },
          networkLocationStyle != .off
            ? networkCountryCode.map {
              tr("IP 归属地") + " · " + (L10n.locale.localizedString(forRegionCode: $0) ?? $0)
            } : nil,
        ].compactMap { $0 }.joined(separator: "\n")
      case .temperature:
        temperature.map { tr("CPU 温度 \(Format.temperature($0, fahrenheit: fahrenheit))") }
      case .fan: fanRPM.map { tr("风扇 \(Format.rpm($0))") }
      case .battery:
        battery.map { tr("电池 \(Format.percent($0))") + (batteryCharging ? tr("，充电中") : "") }
          ?? bluetoothDevice.map { tr("蓝牙设备电量 \($0.percent)%") }
      // 没有订阅额度时仍解释本机 Token 读数。
      case .aiUsage:
        if !aiQuotas.isEmpty {
          aiQuotas.map { quota in
            let previous = quota.isStale ? "\(tr("上次额度")) · " : ""
            let checked =
              quota.isStale
              ? " · \(tr("上次成功：\(quota.fetchedAt.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, locale: L10n.locale)))"))"
              : ""
            return
              "\(previous)\(quota.sourceName) · \(quota.shortWindowName) · \(tr(aiQuotaShowsRemaining ? "剩余" : "已用")) \(AIUsageFormat.quotaPercent(remainingPercent: quota.window.remainingPercent, showsRemaining: aiQuotaShowsRemaining, locale: L10n.locale)) · \(tr("重置：")) \(quota.resetText)\(checked)"
          }.joined(separator: "\n")
        } else {
          aiTokens.map { "AI · \(UsageNumber.exact($0)) Tokens" }
            ?? ("AI · " + tr(aiUsageShowsLocalUsage ? "暂无数据" : "暂无额度数据"))
        }
      }
    }
    .joined(separator: "\n")
  }
}

/// 菜单栏图标自绘：每次刷新只生成一张小图，避免在菜单栏里重建 SwiftUI 视图
@MainActor
enum MenuBarRenderer {
  private static func tokenText(_ value: Int, westernUnits: Bool) -> String {
    AIUsageFormat.tokens(value, westernUnits: westernUnits, locale: L10n.locale)
  }
  /// 菜单栏只有 22pt 高。额度读数单独使用更清晰的字号，其余指标保持紧凑排版。
  private enum Metrics {
    @MainActor static let labelFont = NSFont.systemFont(ofSize: 9, weight: .medium)
    @MainActor static let stackedValueFont = NSFont.monospacedDigitSystemFont(
      ofSize: 11, weight: .semibold)
    @MainActor static let inlineLabelFont = NSFont.systemFont(ofSize: 10, weight: .medium)
    @MainActor static let inlineValueFont = NSFont.monospacedDigitSystemFont(
      ofSize: 11, weight: .medium)
    @MainActor static let networkFont = NSFont.monospacedDigitSystemFont(
      ofSize: 9, weight: .regular)
    @MainActor static let quotaLabelFont = NSFont.systemFont(ofSize: 8, weight: .medium)
    @MainActor static let quotaValueFont = NSFont.monospacedDigitSystemFont(
      ofSize: 12, weight: .semibold)
    static let barHeight: CGFloat = 22
    static let upperBaseline: CGFloat = 13
    static let lowerBaseline: CGFloat = 3
    static let stackedUpperBaseline: CGFloat = 12
    static let stackedLowerBaseline: CGFloat = 1
    static let symbolSize: CGFloat = 11
    static let innerGap = DS.Space.s1
    static let aiServiceGap: CGFloat = 6
    static let aiIconValueGap: CGFloat = 3
    static let historyCount = 10
    static let historyBarWidth: CGFloat = 2
    static let historyBarGap: CGFloat = 1
    static let lineCount = 30
    static let lineWidth: CGFloat = 30
    static let chartHeight: CGFloat = 13
    static let gaugeDiameter: CGFloat = 13
    static let ringWidth: CGFloat = 2
    static let meterSize = NSSize(width: 5, height: 13)
    static let dotSize: CGFloat = 5
    static let trackAlpha: CGFloat = 0.25
  }

  private struct Segment {
    let width: CGFloat
    /// 是否含有彩色元素（需要非模板图）
    var colored = false
    let draw: (NSRect) -> Void
  }

  static func image(for model: AppModel) -> NSImage {
    let settings = model.settings
    if settings.menuBarLayout == .iconOnly {
      let dark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
      return TrioIconRenderer.image(
        reading: TrioReading(model: model), configuration: settings.trio, dark: dark)
    }
    let items = model.drawnMenuBarItems
    return image(
      reading: MenuBarReading(model: model, items: items),
      items: items,
      style: { settings.style(for: $0) },
      networkStyle: settings.networkStyle,
      colorizeHighLoad: settings.colorizeHighLoad,
      fahrenheit: settings.useFahrenheit,
      itemGap: CGFloat(settings.menuBarItemSpacing), valueOnTop: settings.menuBarValueOnTop,
      loadSensitivity: settings.loadSensitivity)
  }

  static func image(
    reading: MenuBarReading,
    items: [MenuBarItem],
    style: (MenuBarItem) -> MenuBarStyle,
    networkStyle: NetworkMenuStyle,
    colorizeHighLoad: Bool,
    fahrenheit: Bool,
    itemGap: CGFloat = 8,
    valueOnTop: Bool = false,
    loadSensitivity: LoadSensitivity = .standard
  ) -> NSImage {
    var segments: [Segment] = []
    if reading.keepAwake { segments.append(symbolSegment("cup.and.saucer.fill")) }
    for item in items {
      segments.append(
        segment(
          for: item, reading: reading, style: style(item), networkStyle: networkStyle,
          colorizeHighLoad: colorizeHighLoad, fahrenheit: fahrenheit, valueOnTop: valueOnTop,
          loadSensitivity: loadSensitivity))
    }
    // 即使防休眠标记存在，空项目布局也保留 XStats 的主入口图标。
    if items.isEmpty { segments.append(symbolSegment("waveform.path.ecg")) }

    let width = segments.reduce(0) { $0 + $1.width } + CGFloat(segments.count - 1) * itemGap
    let image = NSImage(size: NSSize(width: ceil(width), height: Metrics.barHeight), flipped: false)
    { rect in
      var x: CGFloat = 0
      for segment in segments {
        segment.draw(NSRect(x: x, y: rect.minY, width: segment.width, height: rect.height))
        x += segment.width + itemGap
      }
      return true
    }
    // 模板图自动适配浅色 / 深色菜单栏；含彩色元素时保留真实颜色，文字仍用动态的 labelColor
    image.isTemplate = !segments.contains(where: \.colored)
    return image
  }

  /// 设置页预览：按指定外观栅格化，透明区域由界面叠加底色。
  /// 绘制回调型图像每次布局或重绘都会重跑文字排版，因此栅格化一次，SwiftUI 之后只复用位图。
  static func preview(_ image: NSImage, dark: Bool, backingScale: CGFloat? = nil) -> NSImage {
    let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    let draw = { (rect: NSRect) in
      let content = {
        image.draw(in: rect)
        if image.isTemplate {
          (dark ? NSColor.white : NSColor.black).set()
          rect.fill(using: .sourceAtop)
        }
      }
      if let appearance { appearance.performAsCurrentDrawingAppearance(content) } else { content() }
    }
    let scale = backingScale ?? NSScreen.main?.backingScaleFactor ?? 2
    let rep = NSBitmapImageRep(
      bitmapDataPlanes: nil,
      pixelsWide: Int(ceil(image.size.width * scale)),
      pixelsHigh: Int(ceil(image.size.height * scale)),
      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
    // 逻辑尺寸决定上下文的点到像素缩放，必须在创建上下文前设置。
    rep?.size = image.size
    guard let rep, let context = NSGraphicsContext(bitmapImageRep: rep) else {
      return NSImage(size: image.size, flipped: false) {
        draw($0)
        return true
      }
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    draw(NSRect(origin: .zero, size: image.size))
    NSGraphicsContext.restoreGraphicsState()
    let result = NSImage(size: image.size)
    result.addRepresentation(rep)
    return result
  }

  // MARK: 各指标

  private static func segment(
    for item: MenuBarItem, reading: MenuBarReading, style: MenuBarStyle,
    networkStyle: NetworkMenuStyle, colorizeHighLoad: Bool, fahrenheit: Bool, valueOnTop: Bool,
    loadSensitivity: LoadSensitivity
  ) -> Segment {
    switch item {
    case .cpu, .gpu, .memory, .disk:
      let (value, history) = reading.percent(item)
      return percentSegment(
        item: item, value: value, history: history, style: style,
        colorizeHighLoad: colorizeHighLoad,
        valueOnTop: valueOnTop, loadSensitivity: loadSensitivity
      )
    case .network:
      let speed = networkSegment(
        upload: reading.upload, download: reading.download, style: networkStyle)
      guard reading.networkLocationStyle != .off, let code = reading.networkCountryCode else {
        return speed
      }
      return combine(
        [speed, networkLocationSegment(code: code, style: reading.networkLocationStyle)],
        gap: Metrics.innerGap * 2)
    case .temperature:
      let text =
        reading.temperature.map { celsius -> String in
          let degrees = fahrenheit ? celsius * 9 / 5 + 32 : celsius
          return "\(Int(degrees.rounded()))°"
        } ?? "—"
      return textSegment(
        item: item, value: text, sample: "100°", style: style, valueOnTop: valueOnTop)
    case .audio:
      let value =
        reading.audioMuted ? tr("已静音") : reading.audioVolume.map { Format.percent($0) } ?? "—"
      if style == .icon {
        return combine([
          symbolSegment(reading.audioMuted ? "speaker.slash" : reading.audioSymbol),
          inlineValue(value, sample: "100%", color: nil),
        ])
      }
      return textSegment(
        item: item, value: value, sample: "100%", style: style, valueOnTop: valueOnTop)
    case .display:
      return textSegment(
        item: item, value: reading.displayCount.formatted(.number.locale(L10n.locale)), sample: "8",
        style: style, valueOnTop: valueOnTop)
    case .fan:
      return textSegment(
        item: item, value: reading.fanRPM.map { "\(Int($0))" } ?? "—", sample: "8888", style: style,
        valueOnTop: valueOnTop)
    case .battery:
      return batterySegment(
        reading: reading, style: style, colorizeHighLoad: colorizeHighLoad,
        valueOnTop: valueOnTop)
    case .aiUsage:
      return aiUsageSegment(reading: reading, style: style, valueOnTop: valueOnTop)
    }
  }

  private static func aiUsageSegment(
    reading: MenuBarReading, style: MenuBarStyle, valueOnTop: Bool
  ) -> Segment {
    guard !reading.aiQuotas.isEmpty else {
      return textSegment(
        item: .aiUsage,
        value: reading.aiTokens.map { tokenText($0, westernUnits: reading.aiUsageWesternUnits) }
          ?? "—",
        sample: "999.9M", style: style, valueOnTop: valueOnTop)
    }
    // 额度组内采用紧凑间距；外部“项目间距”只分隔 AI 与其他监控项目。
    let iconSample = AIUsageFormat.quotaPercent(
      remainingPercent: 99, showsRemaining: true, locale: L10n.locale, compact: true)
    let status = combine(
      reading.aiQuotas.map { quota in
        let name = quota.sourceName
        let label = "\(name) · \(quota.shortWindowName)"
        let value = AIUsageFormat.quotaPercent(
          remainingPercent: quota.window.remainingPercent,
          showsRemaining: reading.aiQuotaShowsRemaining, locale: L10n.locale, compact: true)
        let stacked = aiQuotaText(
          label: name, value: value, centered: style != .stacked,
          valueOnTop: valueOnTop)
        let fraction =
          (AIUsageFormat.quotaValue(
            remainingPercent: quota.window.remainingPercent,
            showsRemaining: reading.aiQuotaShowsRemaining) ?? 0) / 100
        let color = aiQuotaColor(quota.remainingPercent)
        switch style {
        case .stacked, .stackedCenter: return stacked
        case .inline: return inlineText(label: label, value: value, sample: "100%", color: nil)
        case .icon:
          return combine(
            [
              aiProviderLogo(quota.magpieName ?? quota.provider?.rawValue ?? ""),
              inlineValue(value, sample: iconSample, color: nil, leadingAligned: true),
            ],
            gap: Metrics.aiIconValueGap)
        case .ring, .history, .line:
          return combine([
            ring(fraction: fraction, color: color, diameter: 15, lineWidth: 2.5),
            stacked,
          ])
        case .pie: return combine([pie(fraction: fraction, color: color), stacked])
        case .meter:
          return combine([meter(fraction: fraction, color: color), stacked])
        case .dot: return combine([dot(color: color), stacked])
        }
      }, gap: Metrics.aiServiceGap)
    return status
  }

  private static func aiProviderLogo(_ provider: String) -> Segment {
    guard let name = AIServiceBrand.logoName(provider),
      let logo = LogoCache.shared.image(named: name, template: true)
    else {
      return symbolSegment(MenuBarItem.aiUsage.symbol)
    }
    let size: CGFloat = 14
    return Segment(width: size, colored: true) { rect in
      let frame = NSRect(x: rect.minX, y: rect.midY - size / 2, width: size, height: size)
      logo.draw(in: frame)
      // 使用不透明填色覆盖 SVG 原色；图标自身的透明度由 sourceAtop 保留。
      NSColor.labelColor.withAlphaComponent(1).setFill()
      frame.fill(using: .sourceAtop)
    }
  }

  /// 额度越少越需要关注；颜色仅辅助，旁边的百分比始终提供明确数值。
  private static func aiQuotaColor(_ remainingPercent: Int) -> NSColor {
    switch remainingPercent {
    case ...10: NSColor(DS.Palette.critical)
    case ...20: NSColor(DS.Palette.error)
    case ...39: NSColor(DS.Palette.warning)
    case ...79: NSColor(DS.Palette.primary)
    default: NSColor(DS.Palette.success)
    }
  }

  /// 额度是常驻读数：来源和百分比都用主文字色，时间窗及重置时间由悬停提示承载。
  private static func aiQuotaText(
    label: String, value: String, centered: Bool, valueOnTop: Bool
  ) -> Segment {
    let labelAttributes: [NSAttributedString.Key: Any] = [
      .font: Metrics.quotaLabelFont, .foregroundColor: NSColor.labelColor,
    ]
    let valueAttributes: [NSAttributedString.Key: Any] = [
      .font: Metrics.quotaValueFont, .foregroundColor: NSColor.labelColor,
    ]
    let width = ceil(
      max(
        textWidth(label, labelAttributes), textWidth(value, valueAttributes),
        textWidth("100%", valueAttributes)))
    return Segment(width: width) { rect in
      let base = baselineOrigin(in: rect)
      // 来源名可能包含 g、p 等下伸字母；放在下方时多留 1pt，避免被 22pt 画布裁切。
      let labelBaseline =
        base + (valueOnTop ? Metrics.stackedLowerBaseline + 1 : Metrics.stackedUpperBaseline)
      let valueBaseline =
        base + (valueOnTop ? Metrics.stackedUpperBaseline : Metrics.stackedLowerBaseline)
      if centered {
        drawText(label, labelAttributes, centerX: rect.midX, baseline: labelBaseline)
        drawText(value, valueAttributes, centerX: rect.midX, baseline: valueBaseline)
      } else {
        drawText(label, labelAttributes, rightEdge: rect.maxX, baseline: labelBaseline)
        drawText(value, valueAttributes, rightEdge: rect.maxX, baseline: valueBaseline)
      }
    }
  }

  /// 电池：按电量画图形，电量低时着色为警示；充电中在前面加一道闪电。
  /// 没有电池的 Mac 显示电量最低的蓝牙设备；开了提示且某个设备电量低时，附在电池后面
  private static func batterySegment(
    reading: MenuBarReading, style: MenuBarStyle, colorizeHighLoad: Bool, valueOnTop: Bool
  ) -> Segment {
    let bluetooth = reading.bluetoothDevice.map { device -> Segment in
      let value = "\(device.percent)%"
      let color = loadWarningColor(
        Double(device.percent) / 100, lowIsWarning: true, enabled: colorizeHighLoad)
      // 蓝牙回退与低电量提示也遵循文字排版；BT 区分外设电量与本机 BAT。
      switch style {
      case .stacked, .stackedCenter:
        return stackedText(
          label: "BT", value: value, sample: "100%", color: color,
          centered: style == .stackedCenter, valueOnTop: valueOnTop)
      case .inline:
        return inlineText(label: "BT", value: value, sample: "100%", color: color)
      default:
        return combine([
          symbolSegment(device.symbol), inlineValue(value, sample: "100%", color: color),
        ])
      }
    }
    guard let level = reading.battery else {
      return bluetooth
        ?? textSegment(
          item: .battery, value: "—", sample: "100%", style: style, valueOnTop: valueOnTop)
    }
    let fraction = min(1, max(0, level))
    let text = Format.percent(fraction)
    let color = loadWarningColor(level, lowIsWarning: true, enabled: colorizeHighLoad)
    // 零电量没有填充区域，用底槽保留警示；仅电池启用，避免改变 AI 额度的空图形。
    let emptyTrackColor = fraction == 0 ? color : nil
    let label = MenuBarItem.battery.menuBarLabel
    let stacked = stackedText(
      label: label, value: text, sample: "100%",
      color: style == .stacked || style == .stackedCenter ? color : nil,
      centered: style != .stacked, valueOnTop: valueOnTop)
    var segment: Segment
    switch style {
    case .stacked, .stackedCenter: segment = stacked
    case .inline: segment = inlineText(label: label, value: text, sample: "100%", color: color)
    case .icon:
      let symbol = reading.batteryCharging ? "battery.100.bolt" : batterySymbol(fraction)
      segment = combine([symbolSegment(symbol), inlineValue(text, sample: "100%", color: color)])
    case .ring:
      segment = combine([
        ring(fraction: fraction, color: color, emptyTrackColor: emptyTrackColor), stacked,
      ])
    case .pie:
      segment = combine([
        pie(fraction: fraction, color: color, emptyTrackColor: emptyTrackColor), stacked,
      ])
    case .history:
      segment = combine([
        historyBars(reading.batteryHistory, color: color, emptyTrackColor: emptyTrackColor),
        stacked,
      ])
    case .line: segment = combine([historyLine(reading.batteryHistory, color: color), stacked])
    case .meter:
      segment = combine([
        meter(fraction: fraction, color: color, emptyTrackColor: emptyTrackColor), stacked,
      ])
    case .dot: segment = combine([dot(color: color), stacked])
    }
    if reading.batteryCharging && style != .icon {
      segment = combine([symbolSegment("bolt.fill"), segment])
    }
    if let bluetooth {
      segment = combine([segment, bluetooth], gap: DS.Space.s2)
    }
    return segment
  }

  private static func batterySymbol(_ fraction: Double) -> String {
    switch fraction {
    case ..<0.125: "battery.0"
    case ..<0.375: "battery.25"
    case ..<0.625: "battery.50"
    case ..<0.875: "battery.75"
    default: "battery.100"
    }
  }

  private static func percentSegment(
    item: MenuBarItem, value: Double?, history: [Double],
    style: MenuBarStyle, colorizeHighLoad: Bool, valueOnTop: Bool, loadSensitivity: LoadSensitivity
  ) -> Segment {
    let fraction = min(1, max(0, value ?? 0))
    let text = value.map { Format.percent($0) } ?? "—"
    let color = loadWarningColor(value, sensitivity: loadSensitivity, enabled: colorizeHighLoad)
    let sample = "100%"
    // 有负载图形时由图形承担警示，文字保持系统前景色，避免重复强调。
    let stacked = stackedText(
      label: item.menuBarLabel, value: text, sample: sample,
      color: style == .stacked || style == .stackedCenter ? color : nil,
      centered: style != .stacked, valueOnTop: valueOnTop)

    switch style {
    case .stacked, .stackedCenter:
      return stacked
    case .inline:
      return inlineText(label: item.menuBarLabel, value: text, sample: sample, color: color)
    case .icon:
      return combine([symbolSegment(item.symbol), inlineValue(text, sample: sample, color: color)])
    case .ring:
      return combine([ring(fraction: fraction, color: color), stacked])
    case .pie:
      return combine([pie(fraction: fraction, color: color), stacked])
    case .history:
      return combine([historyBars(history, color: color), stacked])
    case .line:
      return combine([historyLine(history, color: color), stacked])
    case .meter:
      return combine([meter(fraction: fraction, color: color), stacked])
    case .dot:
      return combine([dot(color: color), stacked])
    }
  }

  /// 温度、风扇没有百分比图形：两行风格用标签 + 数值，单行风格与图标风格保持单行
  private static func textSegment(
    item: MenuBarItem, value: String, sample: String, style: MenuBarStyle, valueOnTop: Bool
  ) -> Segment {
    switch style {
    case .inline: inlineText(label: item.menuBarLabel, value: value, sample: sample, color: nil)
    case .icon:
      combine([symbolSegment(item.symbol), inlineValue(value, sample: sample, color: nil)])
    default:
      stackedText(
        label: item.menuBarLabel, value: value, sample: sample, color: nil,
        centered: style != .stacked, valueOnTop: valueOnTop)
    }
  }

  // MARK: 文字

  /// 使用率与剩余电量方向相反；只在用户开启着色且读数有效时提示。
  private static func loadWarningColor(
    _ value: Double?, lowIsWarning: Bool = false, sensitivity: LoadSensitivity = .standard,
    enabled: Bool
  ) -> NSColor? {
    guard enabled, let value, value.isFinite else { return nil }
    switch lowIsWarning
      ? LoadLevel.remaining(value) : LoadLevel.usage(value, sensitivity: sensitivity)
    {
    case .normal: return nil
    case .warning: return .systemOrange
    case .critical: return .systemRed
    }
  }

  /// 文字色在绘制时按菜单栏外观解析；小标签也用主文字色，避免深色菜单栏里变得过淡。
  /// 双行风格共用宽度计算；居中时让标签和数值分别按自己的宽度定位。
  /// 仅“双行文字”靠右对齐，图形样式搭配的双行文字默认居中。
  private static func stackedText(
    label: String, value: String, sample: String, color: NSColor?,
    centered: Bool = false, valueOnTop: Bool
  ) -> Segment {
    let labelAttributes: [NSAttributedString.Key: Any] = [
      .font: Metrics.labelFont, .foregroundColor: NSColor.labelColor,
    ]
    let valueAttributes: [NSAttributedString.Key: Any] = [
      .font: Metrics.stackedValueFont, .foregroundColor: (color ?? .labelColor),
    ]
    let width = ceil(
      max(
        textWidth(label, labelAttributes), textWidth(value, valueAttributes),
        textWidth(sample, valueAttributes)))
    return Segment(width: width, colored: color != nil) { rect in
      let base = baselineOrigin(in: rect)
      let labelBaseline =
        base + (valueOnTop ? Metrics.stackedLowerBaseline : Metrics.stackedUpperBaseline)
      let valueBaseline =
        base + (valueOnTop ? Metrics.stackedUpperBaseline : Metrics.stackedLowerBaseline)
      if centered {
        drawText(
          label, labelAttributes, centerX: rect.midX, baseline: labelBaseline)
        drawText(
          value, valueAttributes, centerX: rect.midX, baseline: valueBaseline)
      } else {
        drawText(
          label, labelAttributes, rightEdge: rect.maxX,
          baseline: labelBaseline)
        drawText(
          value, valueAttributes, rightEdge: rect.maxX,
          baseline: valueBaseline)
      }
    }
  }

  private static func inlineText(label: String, value: String, sample: String, color: NSColor?)
    -> Segment
  {
    let labelAttributes: [NSAttributedString.Key: Any] = [
      .font: Metrics.inlineLabelFont, .foregroundColor: NSColor.labelColor,
    ]
    let labelWidth = ceil(textWidth(label, labelAttributes))
    let valueSegment = inlineValue(value, sample: sample, color: color)
    return Segment(width: labelWidth + Metrics.innerGap + valueSegment.width, colored: color != nil)
    { rect in
      drawText(
        label, labelAttributes, rightEdge: rect.minX + labelWidth,
        baseline: rect.midY - Metrics.inlineLabelFont.capHeight / 2)
      valueSegment.draw(
        NSRect(
          x: rect.maxX - valueSegment.width, y: rect.minY, width: valueSegment.width,
          height: rect.height))
    }
  }

  private static func inlineValue(
    _ value: String, sample: String, color: NSColor?, leadingAligned: Bool = false
  ) -> Segment {
    let attributes: [NSAttributedString.Key: Any] = [
      .font: Metrics.inlineValueFont, .foregroundColor: (color ?? .labelColor),
    ]
    let valueWidth = textWidth(value, attributes)
    let width = ceil(max(valueWidth, textWidth(sample, attributes)))
    return Segment(width: width, colored: color != nil) { rect in
      // 额度图标与数值相邻；预留宽度留在数值之后，避免短百分比在图标旁留下空白。
      let rightEdge = leadingAligned ? rect.minX + valueWidth : rect.maxX
      drawText(
        value, attributes, rightEdge: rightEdge,
        baseline: rect.midY - Metrics.inlineValueFont.capHeight / 2)
    }
  }

  private static func textWidth(_ text: String, _ attributes: [NSAttributedString.Key: Any])
    -> CGFloat
  {
    (text as NSString).size(withAttributes: attributes).width
  }

  private static func drawText(
    _ text: String, _ attributes: [NSAttributedString.Key: Any], rightEdge: CGFloat,
    baseline: CGFloat
  ) {
    let string = NSAttributedString(string: text, attributes: attributes)
    let width = string.size().width
    string.draw(with: NSRect(x: rightEdge - width, y: baseline, width: width, height: 0))
  }

  private static func drawText(
    _ text: String, _ attributes: [NSAttributedString.Key: Any], centerX: CGFloat, baseline: CGFloat
  ) {
    let string = NSAttributedString(string: text, attributes: attributes)
    let width = string.size().width
    string.draw(
      with: NSRect(x: (centerX - width / 2).rounded(), y: baseline, width: width, height: 0))
  }

  /// 刘海屏的菜单栏更高，两行内容整体在按钮内垂直居中
  private static func baselineOrigin(in rect: NSRect) -> CGFloat {
    rect.midY - Metrics.barHeight / 2
  }

  // MARK: 图形

  private static func ring(
    fraction: Double, color: NSColor? = nil,
    emptyTrackColor: NSColor? = nil,
    diameter: CGFloat = Metrics.gaugeDiameter,
    lineWidth: CGFloat = Metrics.ringWidth
  ) -> Segment {
    Segment(width: diameter, colored: color != nil || emptyTrackColor != nil) { rect in
      let inset = lineWidth / 2
      let circle = NSRect(
        x: rect.minX + inset, y: rect.midY - diameter / 2 + inset,
        width: diameter - lineWidth, height: diameter - lineWidth)
      let track = NSBezierPath(ovalIn: circle)
      track.lineWidth = lineWidth
      (fraction > 0 ? NSColor.labelColor : emptyTrackColor ?? .labelColor)
        .withAlphaComponent(Metrics.trackAlpha).setStroke()
      track.stroke()
      guard fraction > 0 else { return }
      let arc = NSBezierPath()
      arc.appendArc(
        withCenter: NSPoint(x: circle.midX, y: circle.midY), radius: circle.width / 2,
        startAngle: 90, endAngle: 90 - 360 * fraction, clockwise: true)
      arc.lineWidth = lineWidth
      arc.lineCapStyle = .round
      (color ?? .labelColor).setStroke()
      arc.stroke()
    }
  }

  private static func pie(
    fraction: Double, color: NSColor? = nil, emptyTrackColor: NSColor? = nil
  ) -> Segment {
    Segment(width: Metrics.gaugeDiameter, colored: color != nil || emptyTrackColor != nil) { rect in
      let circle = NSRect(
        x: rect.minX, y: rect.midY - Metrics.gaugeDiameter / 2,
        width: Metrics.gaugeDiameter, height: Metrics.gaugeDiameter)
      (fraction > 0 ? NSColor.labelColor : emptyTrackColor ?? .labelColor)
        .withAlphaComponent(Metrics.trackAlpha).setFill()
      NSBezierPath(ovalIn: circle).fill()
      guard fraction > 0 else { return }
      let center = NSPoint(x: circle.midX, y: circle.midY)
      let wedge = NSBezierPath()
      wedge.move(to: center)
      wedge.appendArc(
        withCenter: center, radius: circle.width / 2,
        startAngle: 90, endAngle: 90 - 360 * fraction, clockwise: true)
      wedge.close()
      (color ?? .labelColor).setFill()
      wedge.fill()
    }
  }

  /// 最近 10 次采样的负载，每根柱子一次采样
  private static func historyBars(
    _ history: [Double], color: NSColor?, emptyTrackColor: NSColor? = nil
  ) -> Segment {
    let recent = Array(history.suffix(Metrics.historyCount))
    let padded = Array(repeating: 0, count: Metrics.historyCount - recent.count) + recent
    let width =
      CGFloat(Metrics.historyCount) * Metrics.historyBarWidth + CGFloat(Metrics.historyCount - 1)
      * Metrics.historyBarGap
    let trackColor =
      recent.contains(where: { $0 > 0 }) ? NSColor.labelColor : emptyTrackColor ?? .labelColor
    return Segment(width: width, colored: color != nil || emptyTrackColor != nil) { rect in
      let bottom = rect.midY - Metrics.chartHeight / 2
      // 不画满高的底槽，只留一条淡基线，柱子的起伏才看得清
      trackColor.withAlphaComponent(Metrics.trackAlpha).setFill()
      NSRect(x: rect.minX, y: bottom, width: width, height: 1).fill()
      for (index, value) in padded.enumerated() where value > 0 {
        let x = rect.minX + CGFloat(index) * (Metrics.historyBarWidth + Metrics.historyBarGap)
        (color ?? .labelColor).setFill()
        NSRect(
          x: x, y: bottom, width: Metrics.historyBarWidth,
          height: max(1, Metrics.chartHeight * min(1, value))
        ).fill()
      }
    }
  }

  /// 最近 30 次采样的折线，最新的点在右边，线下填淡色；数据不足时从右往左只画已有的部分
  private static func historyLine(_ history: [Double], color: NSColor?) -> Segment {
    let recent = Array(history.suffix(Metrics.lineCount))
    return Segment(width: Metrics.lineWidth, colored: color != nil) { rect in
      let bottom = rect.midY - Metrics.chartHeight / 2
      NSColor.labelColor.withAlphaComponent(Metrics.trackAlpha).setFill()
      NSRect(x: rect.minX, y: bottom, width: Metrics.lineWidth, height: 1).fill()
      guard recent.count > 1 else { return }

      let step = Metrics.lineWidth / CGFloat(Metrics.lineCount - 1)
      let startX = rect.maxX - CGFloat(recent.count - 1) * step
      let line = NSBezierPath()
      for (index, value) in recent.enumerated() {
        let point = NSPoint(
          x: startX + CGFloat(index) * step,
          y: bottom + 1 + (Metrics.chartHeight - 2) * CGFloat(min(1, max(0, value))))
        index == 0 ? line.move(to: point) : line.line(to: point)
      }
      let area = line.copy() as! NSBezierPath
      area.line(to: NSPoint(x: rect.maxX, y: bottom))
      area.line(to: NSPoint(x: startX, y: bottom))
      area.close()
      (color ?? .labelColor).withAlphaComponent(Metrics.trackAlpha).setFill()
      area.fill()

      line.lineWidth = 1
      line.lineJoinStyle = .round
      (color ?? .labelColor).setStroke()
      line.stroke()
    }
  }

  /// 竖向电量条
  private static func meter(
    fraction: Double, color: NSColor? = nil, emptyTrackColor: NSColor? = nil
  ) -> Segment {
    Segment(width: Metrics.meterSize.width, colored: color != nil || emptyTrackColor != nil) {
      rect in
      let frame = NSRect(
        x: rect.minX, y: rect.midY - Metrics.meterSize.height / 2,
        width: Metrics.meterSize.width, height: Metrics.meterSize.height)
      let radius = Metrics.meterSize.width / 3
      (fraction > 0 ? NSColor.labelColor : emptyTrackColor ?? .labelColor)
        .withAlphaComponent(Metrics.trackAlpha).setFill()
      let outline = NSBezierPath(roundedRect: frame, xRadius: radius, yRadius: radius)
      outline.fill()
      guard fraction > 0 else { return }
      NSGraphicsContext.saveGraphicsState()
      defer { NSGraphicsContext.restoreGraphicsState() }
      outline.addClip()
      let filled = NSRect(
        x: frame.minX, y: frame.minY, width: frame.width,
        height: frame.height * fraction)
      (color ?? .labelColor).setFill()
      filled.fill()
    }
  }

  private static func dot(color: NSColor?) -> Segment {
    Segment(width: Metrics.dotSize, colored: color != nil) { rect in
      (color ?? .labelColor).setFill()
      NSBezierPath(
        ovalIn: NSRect(
          x: rect.minX, y: rect.midY - Metrics.dotSize / 2,
          width: Metrics.dotSize, height: Metrics.dotSize)
      ).fill()
    }
  }

  private static func symbolSegment(_ name: String) -> Segment {
    let configuration = NSImage.SymbolConfiguration(pointSize: Metrics.symbolSize, weight: .medium)
      .applying(.init(paletteColors: [.labelColor]))
    let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
      .withSymbolConfiguration(configuration)
    let size = symbol?.size ?? NSSize(width: Metrics.symbolSize, height: Metrics.symbolSize)
    return Segment(width: ceil(size.width)) { rect in
      symbol?.draw(
        in: NSRect(
          x: rect.minX, y: rect.midY - size.height / 2, width: size.width, height: size.height))
    }
  }

  // MARK: 网速

  private static func networkLocationSegment(code: String, style: NetworkLocationStyle) -> Segment {
    if style == .flag, let flag = FlagCache.shared.image(for: code) {
      return Segment(width: 16, colored: true) { rect in
        let frame = NSRect(x: rect.minX, y: rect.midY - 6, width: 16, height: 12)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: frame, xRadius: 2, yRadius: 2).addClip()
        flag.draw(in: frame)
        NSGraphicsContext.restoreGraphicsState()
      }
    }
    let name = L10n.locale.localizedString(forRegionCode: code) ?? code
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineBreakMode = .byTruncatingTail
    paragraph.baseWritingDirection =
      L10n.locale.language.languageCode?.identifier == "ar" ? .rightToLeft : .leftToRight
    let attributes: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: 11, weight: .medium),
      .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph,
    ]
    let size = (name as NSString).size(withAttributes: attributes)
    return Segment(width: min(100, ceil(size.width))) { rect in
      (name as NSString).draw(
        in: NSRect(
          x: rect.minX, y: rect.midY - size.height / 2,
          width: rect.width, height: size.height), withAttributes: attributes)
    }
  }

  private static func networkSegment(upload: Double?, download: Double?, style: NetworkMenuStyle)
    -> Segment
  {
    let up = upload.map { Format.menuBarRate($0) } ?? "— KB/s"
    let down = download.map { Format.menuBarRate($0) } ?? "— KB/s"

    switch style {
    case .dots, .arrows:
      let attributes: [NSAttributedString.Key: Any] = [
        .font: Metrics.networkFont, .foregroundColor: NSColor.labelColor,
      ]
      let textWidth = ceil(
        [up, down, "999 KB/s"].map { self.textWidth($0, attributes) }.max() ?? 0)
      let markerWidth = style == .dots ? Metrics.dotSize : ceil(self.textWidth("↑", attributes))
      var segment = Segment(width: markerWidth + Metrics.innerGap + textWidth) { rect in
        let base = baselineOrigin(in: rect)
        let rows: [(String, String, NSColor, CGFloat)] = [
          (up, "↑", DS.NetworkPalette.upload, base + Metrics.upperBaseline - 1),
          (down, "↓", DS.NetworkPalette.download, base + Metrics.lowerBaseline),
        ]
        for (text, arrow, color, baseline) in rows {
          if style == .dots {
            color.setFill()
            let center = baseline + Metrics.networkFont.capHeight / 2
            NSBezierPath(
              ovalIn: NSRect(
                x: rect.minX, y: center - Metrics.dotSize / 2,
                width: Metrics.dotSize, height: Metrics.dotSize)
            ).fill()
          } else {
            drawText(
              arrow, [.font: Metrics.networkFont, .foregroundColor: NSColor.labelColor],
              rightEdge: rect.minX + markerWidth, baseline: baseline)
          }
          drawText(text, attributes, rightEdge: rect.maxX, baseline: baseline)
        }
      }
      segment.colored = style == .dots
      return segment
    case .inline:
      let upSegment = inlineText(label: "↑", value: up, sample: "999 KB/s", color: nil)
      let downSegment = inlineText(label: "↓", value: down, sample: "999 KB/s", color: nil)
      return combine([upSegment, downSegment], gap: Metrics.innerGap * 2)
    }
  }

  private static func combine(_ parts: [Segment], gap: CGFloat = Metrics.innerGap) -> Segment {
    let width = parts.reduce(0) { $0 + $1.width } + CGFloat(max(0, parts.count - 1)) * gap
    var segment = Segment(width: width) { rect in
      var x = rect.minX
      for part in parts {
        part.draw(NSRect(x: x, y: rect.minY, width: part.width, height: rect.height))
        x += part.width + gap
      }
    }
    segment.colored = parts.contains(where: \.colored)
    return segment
  }
}
