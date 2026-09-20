import Localization
import Metrics
import SwiftUI

// 面板每秒刷新，图表全部用 Canvas 直接绘制：比 Swift Charts 轻得多，也能被 ImageRenderer 截图。
// 刷新时不加隐式动画，避免每秒触发一次持续重绘。

/// 历史柱形图：每个采样一根柱子，空位画基线
struct BarHistoryChart: View {
    let values: [Double]
    var capacity: Int = 24
    var color: Color = DS.Palette.primary
    var warnColor: Color = DS.Palette.warning
    var warnThreshold: Double = 0.8
    var height: CGFloat = DS.Size.chartHeight

    var body: some View {
        Canvas { context, size in
            let gap = DS.Space.s1 / 2
            let barWidth = max(1, (size.width - gap * CGFloat(capacity - 1)) / CGFloat(capacity))
            let recent = values.suffix(capacity)
            let offset = capacity - recent.count
            let baseline = DS.Size.stroke * 2

            for index in 0..<capacity {
                let x = CGFloat(index) * (barWidth + gap)
                guard index >= offset else {
                    context.fill(Path(CGRect(x: x, y: size.height - baseline, width: barWidth, height: baseline)),
                                 with: .color(DS.Palette.track))
                    continue
                }
                let value = min(1, max(0, recent[recent.startIndex + index - offset]))
                let barHeight = max(baseline, size.height * value)
                let rect = CGRect(x: x, y: size.height - barHeight, width: barWidth, height: barHeight)
                let fill = value >= warnThreshold ? warnColor : color
                context.fill(Path(roundedRect: rect, cornerRadius: min(DS.Radius.sm / 2, barWidth / 2)),
                             with: .color(value < 0.02 ? DS.Palette.neutral300 : fill))
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

/// 历史折线（可带实色半透明填充）
struct LineHistoryChart: View {
    let values: [Double]
    var capacity: Int = MetricsStore.historyCapacity
    var maxValue: Double = 1
    var color: Color = DS.Palette.primary
    var filled = true
    /// 在 25% / 50% / 75% 画三条淡淡的参考线，图表较高时（主窗口）用来读数
    var grid = false
    var height: CGFloat = DS.Size.chartHeight

    var body: some View {
        Canvas { context, size in
            if grid {
                let usable = size.height - DS.Size.chartLine * 2
                for fraction in [0.25, 0.5, 0.75] {
                    let y = (DS.Size.chartLine + usable * CGFloat(1 - fraction)).rounded()
                    context.fill(Path(CGRect(x: 0, y: y, width: size.width, height: DS.Size.stroke)),
                                 with: .color(DS.Palette.border))
                }
            }
            let line = LineHistoryChart.path(values: values, capacity: capacity, maxValue: maxValue, in: size)
            guard let line else { return }
            if filled {
                var area = line
                area.addLine(to: CGPoint(x: size.width, y: size.height))
                area.addLine(to: CGPoint(x: area.boundingRect.minX, y: size.height))
                area.closeSubpath()
                context.fill(area, with: .color(color.opacity(0.14)))
            }
            context.stroke(line, with: .color(color),
                           style: StrokeStyle(lineWidth: DS.Size.chartLine, lineCap: .round, lineJoin: .round))
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }

    /// 右对齐：最新的点在最右侧
    static func path(values: [Double], capacity: Int, maxValue: Double, in size: CGSize) -> Path? {
        let recent = Array(values.suffix(capacity))
        guard recent.count > 1 else { return nil }
        let step = size.width / CGFloat(max(1, capacity - 1))
        let inset = DS.Size.chartLine
        let usable = size.height - inset * 2
        let peak = max(maxValue, .leastNonzeroMagnitude)
        var path = Path()
        for (index, value) in recent.enumerated() {
            let x = size.width - CGFloat(recent.count - 1 - index) * step
            let y = inset + usable * (1 - CGFloat(min(1, max(0, value / peak))))
            index == 0 ? path.move(to: CGPoint(x: x, y: y)) : path.addLine(to: CGPoint(x: x, y: y))
        }
        return path
    }
}

/// 按时间定位的短期走势线：最新的采样固定在右边缘，往左按真实时间间隔铺开，
/// 采样间隔变化（后台 2 秒、打开详情后 1 秒）也不会把曲线拉伸；相邻采样间隔超过 10 秒（睡眠）线条断开
struct TimedLineChart: View {
    let points: [TimedValue]
    let duration: TimeInterval
    let end: Date
    var color: Color = DS.Palette.primary
    /// 在 25% / 50% / 75% 画三条淡淡的参考线
    var grid = false
    var height: CGFloat = DS.Size.chartHeight

    static let gapLimit: TimeInterval = 10

    var body: some View {
        Canvas { context, size in
            if grid {
                let usable = size.height - DS.Size.chartLine * 2
                for fraction in [0.25, 0.5, 0.75] {
                    let y = (DS.Size.chartLine + usable * CGFloat(1 - fraction)).rounded()
                    context.fill(Path(CGRect(x: 0, y: y, width: size.width, height: DS.Size.stroke)),
                                 with: .color(DS.Palette.border))
                }
            }
            for segment in Self.segments(points, duration: duration, end: end, in: size) {
                guard let first = segment.first, let last = segment.last else { continue }
                var line = Path()
                line.addLines(segment.count == 1 ? [first, CGPoint(x: first.x + DS.Size.stroke, y: first.y)] : segment)
                var area = line
                area.addLine(to: CGPoint(x: last.x, y: size.height))
                area.addLine(to: CGPoint(x: first.x, y: size.height))
                area.closeSubpath()
                context.fill(area, with: .color(color.opacity(0.14)))
                context.stroke(line, with: .color(color),
                               style: StrokeStyle(lineWidth: DS.Size.chartLine, lineCap: .round, lineJoin: .round))
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }

    /// 落在 [end − duration, end] 内的采样换算成坐标（0 在下、1 在上），按间隔断开成若干段
    static func segments(_ points: [TimedValue], duration: TimeInterval, end: Date, in size: CGSize) -> [[CGPoint]] {
        let start = end.addingTimeInterval(-duration)
        let inset = DS.Size.chartLine
        let usable = size.height - inset * 2
        var segments: [[CGPoint]] = []
        var previous: Date?
        for point in points where point.date >= start && point.date <= end {
            let location = CGPoint(x: size.width * CGFloat(point.date.timeIntervalSince(start) / max(duration, 1)),
                                   y: inset + usable * CGFloat(1 - min(1, max(0, point.value))))
            if let previous, point.date.timeIntervalSince(previous) <= gapLimit, !segments.isEmpty {
                segments[segments.count - 1].append(location)
            } else {
                segments.append([location])
            }
            previous = point.date
        }
        return segments
    }
}

/// 上传 / 下载双折线，按两者峰值归一化
struct DualLineChart: View {
    let upload: [Double]
    let download: [Double]
    var capacity: Int = MetricsStore.historyCapacity
    var height: CGFloat = DS.Size.chartHeight

    var body: some View {
        Canvas { context, size in
            let peak = max(upload.max() ?? 0, download.max() ?? 0, 64 * 1024)
            let style = StrokeStyle(lineWidth: DS.Size.chartLine, lineCap: .round, lineJoin: .round)
            let series: [([Double], Color)] = [(download, Color(nsColor: DS.NetworkPalette.download)),
                                               (upload, Color(nsColor: DS.NetworkPalette.upload))]
            for (values, color) in series {
                guard let line = LineHistoryChart.path(values: values, capacity: capacity, maxValue: peak * 1.1, in: size) else { continue }
                var area = line
                area.addLine(to: CGPoint(x: size.width, y: size.height))
                area.addLine(to: CGPoint(x: area.boundingRect.minX, y: size.height))
                area.closeSubpath()
                context.fill(area, with: .color(color.opacity(0.10)))
                context.stroke(line, with: .color(color), style: style)
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

/// 环形进度（饼图风格），中间可放图标或文字
struct RingGauge<Center: View>: View {
    let fraction: Double
    var color: Color = DS.Palette.success
    var lineWidth: CGFloat = DS.Space.s1 + DS.Space.s1 / 2
    var size: CGFloat = DS.Space.s12 + DS.Space.s4
    @ViewBuilder var center: Center

    var body: some View {
        ZStack {
            Circle().stroke(DS.Palette.track, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: min(1, max(0, fraction)))
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            center
        }
        .padding(lineWidth / 2)
        .frame(width: size, height: size)
    }
}

/// 每个核心一根竖条，按性能档分组（高性能档在左）
struct CoreClusterBars: View {
    let topology: CPUTopology
    let perCore: [Double]
    var barHeight: CGFloat = DS.Size.coreBarHeight
    /// 按核心类型着色（各类核心的平均占用显示在详细信息里）
    var byCluster = false

    static func average(of cluster: CPUCluster, perCore: [Double]) -> Double? {
        let values = cluster.coreIndices.compactMap { $0 < perCore.count ? perCore[$0] : nil }
        return values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }

    private static let barGap = DS.Space.s1 / 2
    private static let groupGap = DS.Space.s3

    private static func barWidth(for width: CGFloat, clusters: [CPUCluster], total: Int) -> CGFloat {
        let gaps = CGFloat(total - clusters.count) * barGap + CGFloat(max(0, clusters.count - 1)) * groupGap
        return max(1, (width - gaps) / CGFloat(total))
    }

    var body: some View {
        let clusters = topology.clusters.sorted { ($0.coreIndices.first ?? 0) > ($1.coreIndices.first ?? 0) }
        let total = max(1, clusters.reduce(0) { $0 + $1.coreIndices.count })

        VStack(alignment: .leading, spacing: DS.Space.s1) {
            Canvas { context, size in
                var x: CGFloat = 0
                let barWidth = Self.barWidth(for: size.width, clusters: clusters, total: total)
                for cluster in clusters {
                    for index in cluster.coreIndices {
                        let value = index < perCore.count ? min(1, max(0, perCore[index])) : 0
                        let track = CGRect(x: x, y: 0, width: barWidth, height: size.height)
                        context.fill(Path(roundedRect: track, cornerRadius: DS.Radius.sm / 2), with: .color(DS.Palette.track))
                        let fillHeight = size.height * value
                        let fill = CGRect(x: x, y: size.height - fillHeight, width: barWidth, height: fillHeight)
                        let color = byCluster ? DS.Palette.cluster(cluster.id) : value >= 0.8 ? DS.Palette.warning : DS.Palette.primary
                        context.fill(Path(roundedRect: fill, cornerRadius: DS.Radius.sm / 2), with: .color(color))
                        x += barWidth + Self.barGap
                    }
                    x += Self.groupGap - Self.barGap
                }
            }
            .frame(height: barHeight)

            // 标签宽度与上方柱组一致
            GeometryReader { proxy in
                let barWidth = Self.barWidth(for: proxy.size.width, clusters: clusters, total: total)
                HStack(spacing: Self.groupGap) {
                    ForEach(clusters) { cluster in
                        let count = CGFloat(cluster.coreIndices.count)
                        HStack(spacing: DS.Space.s1) {
                            if byCluster {
                                RoundedRectangle(cornerRadius: DS.Radius.sm / 2).fill(DS.Palette.cluster(cluster.id))
                                    .frame(width: DS.Size.barHeight, height: DS.Size.barHeight)
                            }
                            Text(verbatim: label(cluster))
                                .dsFont(.xs)
                                .foregroundStyle(DS.Palette.textTertiary)
                                .monospacedDigit()
                                .lineLimit(1)
                        }
                            .frame(width: count * barWidth + (count - 1) * Self.barGap, alignment: .leading)
                    }
                }
            }
            .frame(height: DS.TextSize.xs.rawValue * 1.5)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tr("各核心负载"))
    }

    private func label(_ cluster: CPUCluster) -> String {
        "\(cluster.name) · \(cluster.coreIndices.count)"
    }
}

/// 核心热力图：每行一个核心（按类型分组，高性能档在上），每列一次采样，最新在右；
/// 最右侧单独一根粗条画此刻的占用，一眼能看出现在哪些核心在忙。
/// 颜色越深越忙，超过 85% 用警告色
struct CoreHeatmap: View {
    let topology: CPUTopology
    let history: [[Double]]
    var columns = 40
    var rowHeight: CGFloat = DS.Space.s1 - DS.Size.stroke

    private static let gap = DS.Size.stroke
    private static let groupGap = DS.Space.s1
    private static let nowWidth = DS.Space.s2
    private static let nowGap = DS.Space.s1

    var body: some View {
        let clusters = topology.clusters.sorted { $0.id < $1.id }
        let height = clusters.reduce(CGFloat(0)) { $0 + CGFloat($1.coreIndices.count) * (rowHeight + Self.gap) }
            + CGFloat(max(0, clusters.count - 1)) * Self.groupGap

        HStack(alignment: .top, spacing: DS.Space.s2) {
            VStack(alignment: .leading, spacing: Self.groupGap) {
                ForEach(clusters) { cluster in
                    // 类型名后面带上核心数，与“各核心占用”里的分组标题一致
                    Text(verbatim: "\(cluster.name) · \(cluster.coreIndices.count)")
                        .dsFont(.xs)
                        .foregroundStyle(DS.Palette.textTertiary)
                        .lineLimit(1)
                        .frame(height: CGFloat(cluster.coreIndices.count) * (rowHeight + Self.gap), alignment: .center)
                }
            }
            .fixedSize()

            Canvas { context, size in
                let recent = Array(history.suffix(columns))
                let gridWidth = size.width - Self.nowWidth - Self.nowGap
                let cellWidth = (gridWidth - Self.gap * CGFloat(columns - 1)) / CGFloat(columns)
                let offset = columns - recent.count
                let latest = recent.last
                var y: CGFloat = 0
                for cluster in clusters {
                    for core in cluster.coreIndices.reversed() {
                        for column in 0..<columns {
                            let rect = CGRect(x: CGFloat(column) * (cellWidth + Self.gap), y: y, width: cellWidth, height: rowHeight)
                            let value = column >= offset ? recent[column - offset][safe: core] : nil
                            context.fill(Path(rect), with: .color(Self.color(value)))
                        }
                        let now = CGRect(x: size.width - Self.nowWidth, y: y, width: Self.nowWidth, height: rowHeight)
                        context.fill(Path(roundedRect: now, cornerRadius: DS.Radius.sm / 2), with: .color(Self.color(latest?[safe: core])))
                        y += rowHeight + Self.gap
                    }
                    y += Self.groupGap
                }
            }
            .frame(height: height)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tr("核心热力图"))
    }

    static func color(_ value: Double?) -> Color {
        guard let value else { return DS.Palette.track }
        if value >= 0.85 { return DS.Palette.warning }
        return DS.Palette.primary.opacity(0.08 + 0.92 * min(1, max(0, value)))
    }
}

/// 热力图图例：低 → 高
struct HeatLegend: View {
    var body: some View {
        HStack(spacing: DS.Space.s1) {
            Text(tr("闲")).dsFont(.xs).foregroundStyle(DS.Palette.textTertiary)
            ForEach([0.05, 0.3, 0.55, 0.8, 0.9], id: \.self) { value in
                RoundedRectangle(cornerRadius: DS.Radius.sm / 2)
                    .fill(CoreHeatmap.color(value))
                    .frame(width: DS.Space.s2, height: DS.Space.s2)
            }
            Text(tr("忙")).dsFont(.xs).foregroundStyle(DS.Palette.textTertiary)
        }
    }
}

/// 压力走势条：每次采样一段，绿色正常、橙色偏高、红色严重
struct PressureStrip: View {
    let history: [MemoryPressure]
    var capacity = MetricsStore.historyCapacity

    var body: some View {
        Canvas { context, size in
            let width = size.width / CGFloat(capacity)
            let offset = capacity - min(capacity, history.count)
            let recent = history.suffix(capacity)
            context.clip(to: Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: size.height / 2))
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(DS.Palette.track))
            for (index, pressure) in recent.enumerated() {
                let color: Color = switch pressure {
                case .normal: DS.Palette.success
                case .warning: DS.Palette.warning
                case .critical: DS.Palette.error
                }
                // 多画 1pt 盖住相邻段之间的缝
                let rect = CGRect(x: CGFloat(offset + index) * width, y: 0, width: width + DS.Size.stroke, height: size.height)
                context.fill(Path(rect), with: .color(color))
            }
        }
        .frame(height: DS.Space.s2)
        .accessibilityElement()
        .accessibilityLabel(tr("最近的内存压力走势"))
    }
}

/// 横向水位条：各段按大小依次排开，段与段之间留 1pt 缝
struct WaterlineBar: View {
    let segments: [(value: Double, color: Color)]
    let total: Double
    var height: CGFloat = DS.Space.s4 + DS.Space.s1

    var body: some View {
        Canvas { context, size in
            context.clip(to: Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: DS.Radius.sm))
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(DS.Palette.track))
            var x: CGFloat = 0
            for segment in segments where segment.value > 0 {
                let width = size.width * CGFloat(segment.value / max(total, 1))
                context.fill(Path(CGRect(x: x, y: 0, width: max(0, width - DS.Size.stroke), height: size.height)),
                             with: .color(segment.color))
                x += width
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

/// 上下镜像的流量图：上半部分上传、下半部分下载，各自按自己的峰值缩放
struct MirroredRateChart: View {
    let upload: [Double]
    let download: [Double]
    var capacity: Int = MetricsStore.historyCapacity
    var height: CGFloat = DS.Size.chartHeight

    /// 峰值太小时按 64 KB/s 缩放，避免空闲时的噪声被放大成满格
    static let floor = 64.0 * 1024

    var body: some View {
        Canvas { context, size in
            let middle = size.height / 2
            let half = CGSize(width: size.width, height: middle)
            let series: [([Double], Color, Bool)] = [
                (upload, Color(nsColor: DS.NetworkPalette.upload), true),
                (download, Color(nsColor: DS.NetworkPalette.download), false),
            ]
            for (values, color, above) in series {
                let peak = max(values.max() ?? 0, Self.floor)
                guard var line = LineHistoryChart.path(values: values, capacity: capacity, maxValue: peak, in: half) else { continue }
                if !above {
                    // 下半部分：向下翻转
                    line = line.applying(CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: middle * 2))
                }
                var area = line
                area.addLine(to: CGPoint(x: size.width, y: middle))
                area.addLine(to: CGPoint(x: line.boundingRect.minX, y: middle))
                area.closeSubpath()
                context.fill(area, with: .color(color.opacity(0.14)))
                context.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: DS.Size.chartLine, lineJoin: .round))
            }
            context.fill(Path(CGRect(x: 0, y: middle - DS.Size.stroke / 2, width: size.width, height: DS.Size.stroke)),
                         with: .color(DS.Palette.border))
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

/// 连接探测格子：一格一次探测，从左上到右下按时间排，最新的在最后一格。
/// 只表示通不通：通了是绿色，超时或不可达是红色，还没探测到的是灰色
struct ProbeGrid: View {
    let samples: [ProbeSample]
    var columns = 20
    var rows = 3

    var body: some View {
        let capacity = columns * rows
        let recent = Array(samples.suffix(capacity))
        Canvas { context, size in
            let gap = DS.Space.s1 / 2
            let cellWidth = (size.width - gap * CGFloat(columns - 1)) / CGFloat(columns)
            let cellHeight = (size.height - gap * CGFloat(rows - 1)) / CGFloat(rows)
            let offset = capacity - recent.count
            for index in 0..<capacity {
                let rect = CGRect(x: CGFloat(index % columns) * (cellWidth + gap),
                                  y: CGFloat(index / columns) * (cellHeight + gap),
                                  width: cellWidth, height: cellHeight)
                let color: Color
                if index < offset {
                    color = DS.Palette.track
                } else if recent[index - offset].latency != nil {
                    color = DS.Palette.success
                } else {
                    color = DS.Palette.error
                }
                context.fill(Path(roundedRect: rect, cornerRadius: DS.Radius.sm / 2), with: .color(color))
            }
        }
        // 格子保持接近正方形，宽度随容器变化
        .aspectRatio(CGFloat(columns) / CGFloat(rows), contentMode: .fit)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement()
        .accessibilityLabel(tr("连接探测历史"))
    }
}

// MARK: - 评分色带

/// 0–100 分的六段色带：F、D、C、B、A、A+ 各占自己的分数区间，段内写等级，下方标刻度，
/// 得分处有一个带当前等级的小标记
struct ScoreBand: View {
    let score: Int
    var height: CGFloat = DS.Size.segmentHeight

    private static let markerHeight: CGFloat = DS.Size.iconStandalone + DS.Space.s1
    private static let tickHeight: CGFloat = DS.Space.s3

    var body: some View {
        let bands = DS.Grade.bands
        let clamped = min(100, max(0, score))
        GeometryReader { proxy in
            let width = proxy.size.width
            ZStack(alignment: .topLeading) {
                VStack(spacing: DS.Space.s1 / 2) {
                    HStack(spacing: 1) {
                        ForEach(Array(bands.enumerated()), id: \.offset) { index, band in
                            let lower = index == 0 ? 0 : bands[index - 1].upper
                            let segmentWidth = width * CGFloat(band.upper - lower) / 100
                            ZStack {
                                Rectangle().fill(band.color)
                                if segmentWidth >= DS.Space.s6 {
                                    Text(verbatim: band.grade)
                                        .dsFont(.xs, weight: .semibold)
                                        .foregroundStyle(DS.Palette.onPrimary)
                                }
                            }
                            .frame(width: max(0, segmentWidth - (index == bands.count - 1 ? 0 : 1)))
                        }
                    }
                    .frame(height: height)
                    ZStack(alignment: .topLeading) {
                        // A 与 A+ 的分界太密，刻度上不标 95；弹窗那么窄时 85 也挤不下
                        ForEach([0] + bands.map(\.upper).filter { $0 != 95 && ($0 != 85 || width >= DS.Size.panelWidth / 2) }, id: \.self) { tick in
                            Text(verbatim: "\(tick)")
                                .dsFont(.xs)
                                .foregroundStyle(DS.Palette.textTertiary)
                                .monospacedDigit()
                                .fixedSize()
                                .alignmentGuide(.leading) { dimensions in
                                    // 0 靠左、100 靠右，其余居中对齐刻度
                                    tick == 0 ? 0 : tick == 100 ? dimensions.width - width : dimensions.width / 2 - width * CGFloat(tick) / 100
                                }
                        }
                    }
                    .frame(width: width, height: Self.tickHeight, alignment: .topLeading)
                }
                .padding(.top, Self.markerHeight)

                // 得分标记：气泡里写等级，尖角指向色带
                let color = DS.Grade.color(for: clamped)
                VStack(spacing: 0) {
                    Text(verbatim: DS.Grade.bands.first { clamped < $0.upper }?.grade ?? "A+")
                        .dsFont(.xs, weight: .semibold)
                        .foregroundStyle(DS.Palette.onPrimary)
                        .padding(.horizontal, DS.Space.s1)
                        .frame(height: DS.Size.iconInline)
                        .background(color, in: RoundedRectangle(cornerRadius: DS.Radius.sm))
                    Triangle().fill(color).frame(width: DS.Space.s2, height: DS.Space.s1)
                }
                .fixedSize()
                .alignmentGuide(.leading) { dimensions in dimensions.width / 2 - width * CGFloat(clamped) / 100 }
            }
        }
        .frame(height: height + Self.markerHeight + Self.tickHeight + DS.Space.s1 / 2)
        .accessibilityLabel(tr("纯净度 \(clamped) 分"))
    }
}

private struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
