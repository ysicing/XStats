import AppKit
import Localization
import Metrics

/// 菜单栏上要画的读数，与数据来源解耦，设置页预览可以用示例数据绘制
struct MenuBarReading {
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
    var temperature: Double?
    var fanRPM: Double?
    var battery: Double?
    var batteryHistory: [Double] = []
    var aiUsage: AIUsageMenuBarReading?
    var batteryCharging = false
    /// 附在电池项旁的蓝牙设备：电量低的那一个，或没有电池的 Mac 上电量最低的那一个
    var bluetoothDevice: (symbol: String, percent: Int)?
    var keepAwake = false

    /// 蓝牙设备电量低于这个百分比才在菜单栏提示
    static let lowBluetoothPercent = 20

    @MainActor
    init(model: AppModel) {
        let store = model.store
        cpu = store.cpu?.total
        cpuHistory = store.cpuTotal.elements
        gpu = store.gpu?.utilization
        gpuHistory = store.gpuHistory.elements
        memory = store.memory?.usedFraction
        memoryHistory = store.memoryHistory.elements
        disk = store.disk?.usedFraction
        diskHistory = disk.map { Array(repeating: $0, count: 30) } ?? []
        upload = store.network?.uploadBytesPerSecond
        download = store.network?.downloadBytesPerSecond
        temperature = store.sensors?.temperature(.cpu)?.maximum
        fanRPM = store.fastestFan?.current
        battery = store.battery?.level
        batteryHistory = battery.map { Array(repeating: $0, count: 30) } ?? []
        aiUsage = model.aiUsage.menuBarReading
        batteryCharging = store.battery?.isCharging ?? false
        if let lowest = model.bluetooth.lowest,
           battery == nil || (model.settings.bluetoothLowBatteryInMenuBar && lowest.percent <= Self.lowBluetoothPercent) {
            bluetoothDevice = (lowest.device.kind.symbol, lowest.percent)
        }
        keepAwake = model.keepAwake.isActive
    }

    init() {}

    /// 设置页预览用的示例读数：历史给 30 个点，柱状风格取最后 10 个，折线风格用全部
    static let sample: MenuBarReading = {
        var reading = MenuBarReading()
        reading.cpu = 0.34
        reading.cpuHistory = [0.12, 0.15, 0.11, 0.20, 0.33, 0.27, 0.19, 0.24, 0.45, 0.38,
                              0.30, 0.26, 0.22, 0.35, 0.58, 0.49, 0.41, 0.37, 0.30, 0.25,
                              0.18, 0.22, 0.41, 0.36, 0.28, 0.52, 0.47, 0.31, 0.29, 0.34]
        reading.gpu = 0.22
        reading.gpuHistory = [0.02, 0.04, 0.03, 0.08, 0.15, 0.12, 0.09, 0.11, 0.24, 0.20,
                              0.14, 0.10, 0.08, 0.17, 0.35, 0.28, 0.22, 0.19, 0.14, 0.10,
                              0.05, 0.12, 0.30, 0.18, 0.10, 0.26, 0.40, 0.21, 0.15, 0.22]
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
        reading.aiUsage = AIUsageMenuBarReading(provider: .codex, kind: .weekly,
                                                displayedFraction: 0.42, usedFraction: 0.58, isStale: false)
        return reading
    }()

    func percent(_ item: MenuBarItem) -> (value: Double?, history: [Double]) {
        switch item {
        case .cpu: (cpu, cpuHistory)
        case .gpu: (gpu, gpuHistory)
        case .memory: (memory, memoryHistory)
        case .disk: (disk, diskHistory)
        case .battery: (battery, batteryHistory)
        case .aiUsage: (aiUsage?.displayedFraction, [])
        default: (nil, [])
        }
    }

    /// 鼠标悬停时的完整读数
    func tooltip(items: [MenuBarItem], fahrenheit: Bool) -> String {
        items.compactMap { item -> String? in
            switch item {
            case .cpu: cpu.map { "CPU \(Format.percent($0))" }
            case .gpu: gpu.map { "GPU \(Format.percent($0))" }
            case .memory: memory.map { tr("内存 \(Format.percent($0))") }
            case .disk: disk.map { tr("磁盘已用 \(Format.percent($0))") }
            case .network:
                upload.flatMap { up in download.map { tr("上传 \(Format.menuBarRate(up)) · 下载 \(Format.menuBarRate($0))") } }
            case .temperature: temperature.map { tr("CPU 温度 \(Format.temperature($0, fahrenheit: fahrenheit))") }
            case .fan: fanRPM.map { tr("风扇 \(Format.rpm($0))") }
            case .battery:
                battery.map { tr("电池 \(Format.percent($0))") + (batteryCharging ? tr("，充电中") : "") }
                    ?? bluetoothDevice.map { tr("蓝牙设备电量 \($0.percent)%") }
            case .aiUsage:
                aiUsage.map { reading in
                    let suffix = reading.isStale ? tr("，数据已过期") : ""
                    return tr("AI 配额 \(Format.percent(reading.displayedFraction))") + suffix
                }
            }
        }
        .joined(separator: "\n")
    }
}

/// 菜单栏图标自绘：每次刷新只生成一张小图，避免在菜单栏里重建 SwiftUI 视图
@MainActor
enum MenuBarRenderer {
    /// 菜单栏只有 22pt 高，字号刻意小于面板的字号体系，与 Stats 等菜单栏工具同一量级。
    /// 每种风格内部只用这一套排版：两行布局是 7pt 标签 + 10pt 数值，单行布局 11pt，网速两行 9pt。
    private enum Metrics {
        @MainActor static let labelFont = NSFont.systemFont(ofSize: 7, weight: .medium)
        @MainActor static let stackedValueFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        @MainActor static let inlineLabelFont = NSFont.systemFont(ofSize: 10, weight: .regular)
        @MainActor static let inlineValueFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        @MainActor static let networkFont = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular)
        static let barHeight: CGFloat = 22
        static let upperBaseline: CGFloat = 13
        static let lowerBaseline: CGFloat = 3
        static let symbolSize: CGFloat = 11
        static let itemGap = DS.Space.s3
        static let innerGap = DS.Space.s1
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
        static let warningLevel = 0.6
        static let highLevel = 0.85
        /// 电量低于这个比例按警示着色
        static let lowBatteryLevel = 0.2
    }

    private struct Segment {
        let width: CGFloat
        /// 是否含有彩色元素（需要非模板图）
        var colored = false
        let draw: (NSRect) -> Void
    }

    static func image(for model: AppModel) -> NSImage {
        let settings = model.settings
        return image(reading: MenuBarReading(model: model),
                     items: settings.orderedMenuBarItems,
                     style: { settings.style(for: $0) },
                     networkStyle: settings.networkStyle,
                     colorizeHighLoad: settings.colorizeHighLoad,
                     fahrenheit: settings.useFahrenheit)
    }

    static func image(reading: MenuBarReading,
                      items: [MenuBarItem],
                      style: (MenuBarItem) -> MenuBarStyle,
                      networkStyle: NetworkMenuStyle,
                      colorizeHighLoad: Bool,
                      fahrenheit: Bool) -> NSImage {
        var segments: [Segment] = []
        if reading.keepAwake { segments.append(symbolSegment("cup.and.saucer.fill")) }
        for item in items {
            segments.append(segment(for: item, reading: reading, style: style(item), networkStyle: networkStyle,
                                    colorizeHighLoad: colorizeHighLoad, fahrenheit: fahrenheit))
        }
        if segments.isEmpty { segments.append(symbolSegment("waveform.path.ecg")) }

        let width = segments.reduce(0) { $0 + $1.width } + CGFloat(segments.count - 1) * Metrics.itemGap
        let image = NSImage(size: NSSize(width: ceil(width), height: Metrics.barHeight), flipped: false) { rect in
            var x: CGFloat = 0
            for segment in segments {
                segment.draw(NSRect(x: x, y: rect.minY, width: segment.width, height: rect.height))
                x += segment.width + Metrics.itemGap
            }
            return true
        }
        // 模板图自动适配浅色 / 深色菜单栏；含彩色元素时保留真实颜色，文字仍用动态的 labelColor
        image.isTemplate = !segments.contains(where: \.colored)
        return image
    }

    /// 设置页预览：按指定外观绘制到不透明底色上
    static func preview(_ image: NSImage, dark: Bool) -> NSImage {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        return NSImage(size: image.size, flipped: false) { rect in
            let draw = {
                image.draw(in: rect)
                if image.isTemplate {
                    (dark ? NSColor.white : NSColor.black).set()
                    rect.fill(using: .sourceAtop)
                }
            }
            if let appearance { appearance.performAsCurrentDrawingAppearance(draw) } else { draw() }
            return true
        }
    }

    // MARK: 各指标

    private static func segment(for item: MenuBarItem, reading: MenuBarReading, style: MenuBarStyle,
                                networkStyle: NetworkMenuStyle, colorizeHighLoad: Bool, fahrenheit: Bool) -> Segment {
        switch item {
        case .cpu, .gpu, .memory, .disk:
            let (value, history) = reading.percent(item)
            return percentSegment(item: item, value: value, history: history, style: style, colorizeHighLoad: colorizeHighLoad)
        case .network:
            return networkSegment(upload: reading.upload, download: reading.download, style: networkStyle)
        case .temperature:
            let text = reading.temperature.map { celsius -> String in
                let degrees = fahrenheit ? celsius * 9 / 5 + 32 : celsius
                return "\(Int(degrees.rounded()))°"
            } ?? "—"
            return textSegment(item: item, value: text, sample: "100°", style: style)
        case .fan:
            return textSegment(item: item, value: reading.fanRPM.map { "\(Int($0))" } ?? "—", sample: "8888", style: style)
        case .battery:
            return batterySegment(reading: reading, style: style, colorizeHighLoad: colorizeHighLoad)
        case .aiUsage:
            let value = reading.aiUsage?.displayedFraction
            let used = reading.aiUsage?.usedFraction
            let resolved: MenuBarStyle = style == .history || style == .line ? .ring : style
            return percentSegment(item: item, value: value, history: [], style: resolved,
                                  colorizeHighLoad: colorizeHighLoad,
                                  riskFraction: used, stale: reading.aiUsage?.isStale ?? false)
        }
    }

    /// 电池：按电量画图形，电量低时着色为警示；充电中在前面加一道闪电。
    /// 没有电池的 Mac 显示电量最低的蓝牙设备；开了提示且某个设备电量低时，附在电池后面
    private static func batterySegment(reading: MenuBarReading, style: MenuBarStyle, colorizeHighLoad: Bool) -> Segment {
        let bluetooth = reading.bluetoothDevice.map { device in
            combine([symbolSegment(device.symbol),
                     inlineValue("\(device.percent)%", sample: "100%",
                                 alert: colorizeHighLoad && device.percent <= MenuBarReading.lowBluetoothPercent)])
        }
        guard let level = reading.battery else {
            return bluetooth ?? textSegment(item: .battery, value: "—", sample: "100%", style: style)
        }
        let fraction = min(1, max(0, level))
        let text = Format.percent(fraction)
        let alert = colorizeHighLoad && fraction <= Metrics.lowBatteryLevel
        let label = MenuBarItem.battery.menuBarLabel
        let stacked = stackedText(label: label, value: text, sample: "100%", alert: alert)
        var segment: Segment
        switch style {
        case .stacked: segment = stacked
        case .inline: segment = inlineText(label: label, value: text, sample: "100%", alert: alert)
        case .icon:
            let symbol = reading.batteryCharging ? "battery.100.bolt" : batterySymbol(fraction)
            segment = combine([symbolSegment(symbol), inlineValue(text, sample: "100%", alert: alert)])
        case .ring: segment = combine([ring(fraction: fraction, alert: alert), stacked])
        case .pie: segment = combine([pie(fraction: fraction, alert: alert), stacked])
        case .history: segment = combine([historyBars(reading.batteryHistory, alert: alert), stacked])
        case .line: segment = combine([historyLine(reading.batteryHistory, alert: alert), stacked])
        case .meter: segment = combine([meter(fraction: fraction, alert: alert), stacked])
        // 圆点的颜色档按“越满越危险”定义，电量正好相反
        case .dot: segment = combine([levelDot(fraction: 1 - fraction), stacked])
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

    private static func percentSegment(item: MenuBarItem, value: Double?, history: [Double],
                                       style: MenuBarStyle, colorizeHighLoad: Bool,
                                       riskFraction: Double? = nil, stale: Bool = false) -> Segment {
        let fraction = min(1, max(0, value ?? 0))
        let text = (value.map { Format.percent($0) } ?? "—") + (stale ? "⚠︎" : "")
        let alertFraction = riskFraction ?? fraction
        let alert = colorizeHighLoad && alertFraction >= Metrics.highLevel
        let sample = stale ? "100%⚠︎" : "100%"
        let stacked = stackedText(label: item.menuBarLabel, value: text, sample: sample, alert: alert)

        switch style {
        case .stacked:
            return stacked
        case .inline:
            return inlineText(label: item.menuBarLabel, value: text, sample: sample, alert: alert)
        case .icon:
            return combine([symbolSegment(item.symbol), inlineValue(text, sample: sample, alert: alert)])
        case .ring:
            return combine([ring(fraction: fraction, alert: alert), stacked])
        case .pie:
            return combine([pie(fraction: fraction, alert: alert), stacked])
        case .history:
            return combine([historyBars(history, alert: alert), stacked])
        case .line:
            return combine([historyLine(history, alert: alert), stacked])
        case .meter:
            return combine([meter(fraction: fraction, alert: alert), stacked])
        case .dot:
            return combine([levelDot(fraction: alertFraction), stacked])
        }
    }

    /// 温度、风扇没有百分比图形：两行风格用标签 + 数值，单行风格与图标风格保持单行
    private static func textSegment(item: MenuBarItem, value: String, sample: String, style: MenuBarStyle) -> Segment {
        switch style {
        case .inline: inlineText(label: item.menuBarLabel, value: value, sample: sample, alert: false)
        case .icon: combine([symbolSegment(item.symbol), inlineValue(value, sample: sample, alert: false)])
        default: stackedText(label: item.menuBarLabel, value: value, sample: sample, alert: false)
        }
    }

    // MARK: 文字

    private static func foreground(_ alert: Bool) -> NSColor {
        alert ? .systemRed : .labelColor
    }

    /// 颜色保持动态（labelColor / secondaryLabelColor），在绘制时才按菜单栏外观解析
    private static func stackedText(label: String, value: String, sample: String, alert: Bool) -> Segment {
        let labelAttributes: [NSAttributedString.Key: Any] = [.font: Metrics.labelFont, .foregroundColor: NSColor.secondaryLabelColor]
        let valueAttributes: [NSAttributedString.Key: Any] = [.font: Metrics.stackedValueFont, .foregroundColor: foreground(alert)]
        let width = ceil(max(textWidth(label, labelAttributes), textWidth(value, valueAttributes), textWidth(sample, valueAttributes)))
        return Segment(width: width) { rect in
            let base = baselineOrigin(in: rect)
            drawText(label, labelAttributes, rightEdge: rect.maxX, baseline: base + Metrics.upperBaseline)
            drawText(value, valueAttributes, rightEdge: rect.maxX, baseline: base + Metrics.lowerBaseline)
        }
    }

    private static func inlineText(label: String, value: String, sample: String, alert: Bool) -> Segment {
        let labelAttributes: [NSAttributedString.Key: Any] = [.font: Metrics.inlineLabelFont, .foregroundColor: NSColor.secondaryLabelColor]
        let labelWidth = ceil(textWidth(label, labelAttributes))
        let valueSegment = inlineValue(value, sample: sample, alert: alert)
        return Segment(width: labelWidth + Metrics.innerGap + valueSegment.width) { rect in
            drawText(label, labelAttributes, rightEdge: rect.minX + labelWidth,
                     baseline: rect.midY - Metrics.inlineLabelFont.capHeight / 2)
            valueSegment.draw(NSRect(x: rect.maxX - valueSegment.width, y: rect.minY, width: valueSegment.width, height: rect.height))
        }
    }

    private static func inlineValue(_ value: String, sample: String, alert: Bool) -> Segment {
        let attributes: [NSAttributedString.Key: Any] = [.font: Metrics.inlineValueFont, .foregroundColor: foreground(alert)]
        let width = ceil(max(textWidth(value, attributes), textWidth(sample, attributes)))
        return Segment(width: width) { rect in
            drawText(value, attributes, rightEdge: rect.maxX, baseline: rect.midY - Metrics.inlineValueFont.capHeight / 2)
        }
    }

    private static func textWidth(_ text: String, _ attributes: [NSAttributedString.Key: Any]) -> CGFloat {
        (text as NSString).size(withAttributes: attributes).width
    }

    private static func drawText(_ text: String, _ attributes: [NSAttributedString.Key: Any], rightEdge: CGFloat, baseline: CGFloat) {
        let string = NSAttributedString(string: text, attributes: attributes)
        let width = string.size().width
        string.draw(with: NSRect(x: rightEdge - width, y: baseline, width: width, height: 0))
    }

    /// 刘海屏的菜单栏更高，两行内容整体在按钮内垂直居中
    private static func baselineOrigin(in rect: NSRect) -> CGFloat {
        rect.midY - Metrics.barHeight / 2
    }

    // MARK: 图形

    private static func ring(fraction: Double, alert: Bool) -> Segment {
        Segment(width: Metrics.gaugeDiameter) { rect in
            let inset = Metrics.ringWidth / 2
            let circle = NSRect(x: rect.minX + inset, y: rect.midY - Metrics.gaugeDiameter / 2 + inset,
                                width: Metrics.gaugeDiameter - Metrics.ringWidth, height: Metrics.gaugeDiameter - Metrics.ringWidth)
            let track = NSBezierPath(ovalIn: circle)
            track.lineWidth = Metrics.ringWidth
            NSColor.labelColor.withAlphaComponent(Metrics.trackAlpha).setStroke()
            track.stroke()
            guard fraction > 0 else { return }
            let arc = NSBezierPath()
            arc.appendArc(withCenter: NSPoint(x: circle.midX, y: circle.midY), radius: circle.width / 2,
                          startAngle: 90, endAngle: 90 - 360 * fraction, clockwise: true)
            arc.lineWidth = Metrics.ringWidth
            arc.lineCapStyle = .round
            foreground(alert).setStroke()
            arc.stroke()
        }
    }

    private static func pie(fraction: Double, alert: Bool) -> Segment {
        Segment(width: Metrics.gaugeDiameter) { rect in
            let circle = NSRect(x: rect.minX, y: rect.midY - Metrics.gaugeDiameter / 2,
                                width: Metrics.gaugeDiameter, height: Metrics.gaugeDiameter)
            NSColor.labelColor.withAlphaComponent(Metrics.trackAlpha).setFill()
            NSBezierPath(ovalIn: circle).fill()
            guard fraction > 0 else { return }
            let center = NSPoint(x: circle.midX, y: circle.midY)
            let wedge = NSBezierPath()
            wedge.move(to: center)
            wedge.appendArc(withCenter: center, radius: circle.width / 2,
                            startAngle: 90, endAngle: 90 - 360 * fraction, clockwise: true)
            wedge.close()
            foreground(alert).setFill()
            wedge.fill()
        }
    }

    /// 最近 10 次采样的负载，每根柱子一次采样
    private static func historyBars(_ history: [Double], alert: Bool) -> Segment {
        let recent = Array(history.suffix(Metrics.historyCount))
        let padded = Array(repeating: 0, count: Metrics.historyCount - recent.count) + recent
        let width = CGFloat(Metrics.historyCount) * Metrics.historyBarWidth + CGFloat(Metrics.historyCount - 1) * Metrics.historyBarGap
        return Segment(width: width) { rect in
            let bottom = rect.midY - Metrics.chartHeight / 2
            // 不画满高的底槽，只留一条淡基线，柱子的起伏才看得清
            NSColor.labelColor.withAlphaComponent(Metrics.trackAlpha).setFill()
            NSRect(x: rect.minX, y: bottom, width: width, height: 1).fill()
            for (index, value) in padded.enumerated() where value > 0 {
                let x = rect.minX + CGFloat(index) * (Metrics.historyBarWidth + Metrics.historyBarGap)
                foreground(alert && value >= Metrics.highLevel).setFill()
                NSRect(x: x, y: bottom, width: Metrics.historyBarWidth,
                       height: max(1, Metrics.chartHeight * min(1, value))).fill()
            }
        }
    }

    /// 最近 30 次采样的折线，最新的点在右边，线下填淡色；数据不足时从右往左只画已有的部分
    private static func historyLine(_ history: [Double], alert: Bool) -> Segment {
        let recent = Array(history.suffix(Metrics.lineCount))
        return Segment(width: Metrics.lineWidth) { rect in
            let bottom = rect.midY - Metrics.chartHeight / 2
            NSColor.labelColor.withAlphaComponent(Metrics.trackAlpha).setFill()
            NSRect(x: rect.minX, y: bottom, width: Metrics.lineWidth, height: 1).fill()
            guard recent.count > 1 else { return }

            let step = Metrics.lineWidth / CGFloat(Metrics.lineCount - 1)
            let startX = rect.maxX - CGFloat(recent.count - 1) * step
            let line = NSBezierPath()
            for (index, value) in recent.enumerated() {
                let point = NSPoint(x: startX + CGFloat(index) * step,
                                    y: bottom + 1 + (Metrics.chartHeight - 2) * CGFloat(min(1, max(0, value))))
                index == 0 ? line.move(to: point) : line.line(to: point)
            }
            let area = line.copy() as! NSBezierPath
            area.line(to: NSPoint(x: rect.maxX, y: bottom))
            area.line(to: NSPoint(x: startX, y: bottom))
            area.close()
            foreground(alert).withAlphaComponent(Metrics.trackAlpha).setFill()
            area.fill()

            line.lineWidth = 1
            line.lineJoinStyle = .round
            foreground(alert).setStroke()
            line.stroke()
        }
    }

    /// 竖向电量条
    private static func meter(fraction: Double, alert: Bool) -> Segment {
        Segment(width: Metrics.meterSize.width) { rect in
            let frame = NSRect(x: rect.minX, y: rect.midY - Metrics.meterSize.height / 2,
                               width: Metrics.meterSize.width, height: Metrics.meterSize.height)
            let radius = Metrics.meterSize.width / 3
            NSColor.labelColor.withAlphaComponent(Metrics.trackAlpha).setFill()
            NSBezierPath(roundedRect: frame, xRadius: radius, yRadius: radius).fill()
            guard fraction > 0 else { return }
            let filled = NSRect(x: frame.minX, y: frame.minY, width: frame.width,
                                height: max(radius * 2, frame.height * fraction))
            foreground(alert).setFill()
            NSBezierPath(roundedRect: filled, xRadius: radius, yRadius: radius).fill()
        }
    }

    /// 按负载着色的状态点：绿色正常、橙色偏高、红色很高
    private static func levelDot(fraction: Double) -> Segment {
        var segment = Segment(width: Metrics.dotSize) { rect in
            let color: NSColor = fraction >= Metrics.highLevel ? .systemRed
                : fraction >= Metrics.warningLevel ? .systemOrange : .systemGreen
            color.setFill()
            NSBezierPath(ovalIn: NSRect(x: rect.minX, y: rect.midY - Metrics.dotSize / 2,
                                        width: Metrics.dotSize, height: Metrics.dotSize)).fill()
        }
        segment.colored = true
        return segment
    }

    private static func symbolSegment(_ name: String) -> Segment {
        let configuration = NSImage.SymbolConfiguration(pointSize: Metrics.symbolSize, weight: .medium)
            .applying(.init(paletteColors: [.labelColor]))
        let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(configuration)
        let size = symbol?.size ?? NSSize(width: Metrics.symbolSize, height: Metrics.symbolSize)
        return Segment(width: ceil(size.width)) { rect in
            symbol?.draw(in: NSRect(x: rect.minX, y: rect.midY - size.height / 2, width: size.width, height: size.height))
        }
    }

    // MARK: 网速

    private static func networkSegment(upload: Double?, download: Double?, style: NetworkMenuStyle) -> Segment {
        let up = upload.map { Format.menuBarRate($0) } ?? "— KB/s"
        let down = download.map { Format.menuBarRate($0) } ?? "— KB/s"

        switch style {
        case .dots, .arrows:
            let attributes: [NSAttributedString.Key: Any] = [.font: Metrics.networkFont, .foregroundColor: NSColor.labelColor]
            let textWidth = ceil([up, down, "999 KB/s"].map { self.textWidth($0, attributes) }.max() ?? 0)
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
                        NSBezierPath(ovalIn: NSRect(x: rect.minX, y: center - Metrics.dotSize / 2,
                                                    width: Metrics.dotSize, height: Metrics.dotSize)).fill()
                    } else {
                        drawText(arrow, [.font: Metrics.networkFont, .foregroundColor: NSColor.secondaryLabelColor],
                                 rightEdge: rect.minX + markerWidth, baseline: baseline)
                    }
                    drawText(text, attributes, rightEdge: rect.maxX, baseline: baseline)
                }
            }
            segment.colored = style == .dots
            return segment
        case .inline:
            let upSegment = inlineText(label: "↑", value: up, sample: "999 KB/s", alert: false)
            let downSegment = inlineText(label: "↓", value: down, sample: "999 KB/s", alert: false)
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
