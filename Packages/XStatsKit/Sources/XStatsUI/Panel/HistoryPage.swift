import Localization
import Metrics
import SwiftUI

/// 历史：回看最近 1 小时、24 小时、7 天的 CPU、内存、网络、GPU、温度与功耗。鼠标移到图上查看某一时刻
struct HistoryPage: View {
    @Environment(AppModel.self) private var model
    @State private var hoverDate: Date?
    @State private var confirmingClear = false

    var body: some View {
        @Bindable var settings = model.settings
        let history = model.history
        let points = history.points
        let end = Date()
        let start = history.rangeStart

        PageScroll {
            HStack(spacing: DS.Space.s3) {
                SegmentedControl(selection: Binding(get: { history.range }, set: { history.load($0) }),
                                 options: HistoryRecorder.Range.allCases.map { ($0, $0.title) })
                    .frame(width: DS.Size.sidebarWidth + DS.Space.s16)
                Spacer()
                Text(verbatim: hoverDate.map { "\($0.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, locale: L10n.locale)))" }
                     ?? (points.isEmpty ? "" : tr("每点 \(bucketTitle(history.range))")))
                    .dsFont(.xs)
                    .foregroundStyle(DS.Palette.textSecondary)
                    .monospacedDigit()
            }

            if !settings.historyEnabled {
                InfoBanner(icon: "pause.circle", text: tr("历史记录已关闭，下面是关闭前记录的数据。"), tone: .warning) {
                    Button(tr("开启")) { settings.historyEnabled = true }.buttonStyle(DSButtonStyle(kind: .primary))
                }
            }

            if points.isEmpty {
                Card {
                    Text(history.isQuerying ? tr("正在读取…") : tr("这段时间还没有记录。XStats 运行时每分钟记录一次，睡眠与锁屏期间不记录。"))
                        .dsFont(.sm)
                        .foregroundStyle(DS.Palette.textSecondary)
                }
            } else {
                HistoryChartCard(icon: "cpu", title: "CPU", points: points, start: start, end: end, hoverDate: $hoverDate,
                                 series: [.init(label: tr("平均"), color: DS.Palette.primary, value: \.cpu),
                                          .init(label: tr("峰值"), color: DS.Palette.primary.opacity(0.35), value: \.cpuMax, filled: false)],
                                 maxValue: 1, format: { Format.percent($0) })
                HistoryChartCard(icon: "memorychip", title: tr("内存"), points: points, start: start, end: end, hoverDate: $hoverDate,
                                 series: [.init(label: tr("已用"), color: DS.Palette.primary, value: \.memory)],
                                 maxValue: 1, format: { Format.percent($0) },
                                 note: criticalNote(points))
                HistoryChartCard(icon: "network", title: tr("网络"), points: points, start: start, end: end, hoverDate: $hoverDate,
                                 series: [.init(label: tr("下载"), color: Color(nsColor: DS.NetworkPalette.download), value: \.download),
                                          .init(label: tr("上传"), color: Color(nsColor: DS.NetworkPalette.upload), value: \.upload, filled: false)],
                                 maxValue: nil, format: { Format.menuBarRate($0) })
                HistoryChartCard(icon: "square.3.layers.3d", title: "GPU", points: points, start: start, end: end, hoverDate: $hoverDate,
                                 series: [.init(label: tr("占用"), color: DS.Palette.primary, value: \.gpu)],
                                 maxValue: 1, format: { Format.percent($0) },
                                 emptyNote: tr("只在菜单栏显示 GPU 或打开 GPU 相关页面时记录"))
                HistoryChartCard(icon: "thermometer.medium", title: tr("CPU 温度"), points: points, start: start, end: end, hoverDate: $hoverDate,
                                 series: [.init(label: tr("最高"), color: DS.Palette.warning, value: \.temperature)],
                                 maxValue: nil, format: { Format.temperature($0, fahrenheit: settings.useFahrenheit) },
                                 emptyNote: tr("只在菜单栏显示温度、开启过热通知或打开温度页面时记录"))
                HistoryChartCard(icon: "bolt", title: tr("整机功耗"), points: points, start: start, end: end, hoverDate: $hoverDate,
                                 series: [.init(label: tr("平均"), color: DS.Palette.warning, value: \.power)],
                                 maxValue: nil, format: { Format.watts($0) },
                                 emptyNote: tr("只在打开温度与风扇页面时记录"))
                if model.store.battery != nil {
                    HistoryChartCard(icon: "battery.75", title: tr("电池电量"), points: points, start: start, end: end, hoverDate: $hoverDate,
                                     series: [.init(label: tr("电量"), color: DS.Palette.success, value: \.battery)],
                                     maxValue: 1, format: { Format.percent($0) },
                                     emptyNote: tr("只在菜单栏显示电池或打开电池页面时记录"))
                }
            }

            SettingsGroup(caption: tr("历史记录")) {
                GroupRow(showsDivider: false) {
                    SettingRow(title: tr("记录历史数据"), subtitle: tr("每分钟把主要指标的平均值与峰值写入本机数据库，保留 7 天，不上传")) {
                        DSToggle(isOn: $settings.historyEnabled, label: tr("记录历史数据"))
                    }
                }
                GroupRow {
                    SettingRow(title: tr("清除历史"), subtitle: tr("共 \(history.recordCount.formatted()) 条记录")) {
                        Button(tr("清除…")) { confirmingClear = true }
                            .buttonStyle(DSButtonStyle(kind: .secondary))
                            .disabled(history.recordCount == 0)
                    }
                }
            }
        }
        .task {
            // 页面打开期间每分钟补上新记录的一点
            history.load()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                if hoverDate == nil { history.load() }
            }
        }
        .confirmationDialog(tr("清除全部历史记录？"), isPresented: $confirmingClear, titleVisibility: .visible) {
            Button(tr("清除"), role: .destructive) { history.clear() }
            Button(tr("取消"), role: .cancel) {}
        } message: {
            Text(tr("已记录的数据会从本机删除，无法恢复。"))
        }
    }

    private func bucketTitle(_ range: HistoryRecorder.Range) -> String {
        range.bucket >= 60 * 60 ? tr("\(range.bucket / 3600) 小时") : tr("\(range.bucket / 60) 分钟")
    }

    private func criticalNote(_ points: [HistoryPoint]) -> String? {
        let critical = points.filter { ($0.pressure ?? 0) >= MemoryPressure.critical.rawValue }.count
        return critical > 0 ? tr("内存压力严重的时段：\(critical) 个（图上红色标记）") : nil
    }
}

private struct HistoryChartCard: View {
    struct Series {
        let label: String
        let color: Color
        let value: KeyPath<HistoryPoint, Double?>
        var filled = true
    }

    let icon: String
    let title: String
    let points: [HistoryPoint]
    let start: Date
    let end: Date
    @Binding var hoverDate: Date?
    let series: [Series]
    let maxValue: Double?
    let format: (Double) -> String
    var note: String?
    var emptyNote: String?

    var body: some View {
        let hasData = series.contains { item in points.contains { $0[keyPath: item.value] != nil } }
        let primary = series[0]
        let values = points.compactMap { $0[keyPath: primary.value] }
        let peakPoint = points.max { ($0[keyPath: primary.value] ?? -1) < ($1[keyPath: primary.value] ?? -1) }

        Card {
            CardHeader(icon: icon, title: title) {
                if let hover = hoverPoint {
                    HStack(spacing: DS.Space.s3) {
                        ForEach(series.indices, id: \.self) { index in
                            legend(series[index], value: hover[keyPath: series[index].value])
                        }
                    }
                } else if !values.isEmpty {
                    Text(verbatim: tr("平均 \(format(values.reduce(0, +) / Double(values.count))) · 峰值 \(format(values.max() ?? 0))\(peakPoint.map { tr("（\(Self.moment($0.date))）") } ?? "")"))
                        .dsFont(.xs)
                        .foregroundStyle(DS.Palette.textTertiary)
                        .monospacedDigit()
                }
            }
            if hasData {
                TimeSeriesChart(points: points, start: start, end: end, series: series, maxValue: maxValue, hoverDate: $hoverDate)
                    .frame(height: DS.Size.chartHeight * 2)
                HStack {
                    Text(verbatim: Self.moment(start))
                    Spacer()
                    Text(verbatim: Self.moment(start.addingTimeInterval(end.timeIntervalSince(start) / 2)))
                    Spacer()
                    Text(tr("现在"))
                }
                .dsFont(.xs)
                .foregroundStyle(DS.Palette.textTertiary)
                .monospacedDigit()
                if let note {
                    Text(note).dsFont(.xs).foregroundStyle(DS.Palette.textTertiary)
                }
            } else {
                Text(emptyNote ?? tr("这段时间没有记录")).dsFont(.xs).foregroundStyle(DS.Palette.textTertiary)
            }
        }
    }

    /// 同一天只显示时间，跨天带上日期
    static func moment(_ date: Date) -> String {
        Calendar.current.isDateInToday(date)
            ? date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: L10n.locale))
            : date.formatted(.dateTime.locale(L10n.locale).month(.abbreviated).day().hour().minute())
    }

    private var hoverPoint: HistoryPoint? {
        guard let hoverDate else { return nil }
        return points.min { abs($0.date.timeIntervalSince(hoverDate)) < abs($1.date.timeIntervalSince(hoverDate)) }
    }

    private func legend(_ item: Series, value: Double?) -> some View {
        HStack(spacing: DS.Space.s1) {
            Circle().fill(item.color).frame(width: DS.Space.s2, height: DS.Space.s2)
            Text(verbatim: "\(item.label) \(value.map(format) ?? "—")")
                .dsFont(.xs, weight: .medium)
                .foregroundStyle(DS.Palette.textPrimary)
                .monospacedDigit()
        }
    }
}

/// 按时间定位的折线图：相邻两点间隔超过 3 个时间桶视为没有记录（睡眠、关机），线条断开
private struct TimeSeriesChart: View {
    let points: [HistoryPoint]
    let start: Date
    let end: Date
    let series: [HistoryChartCard.Series]
    let maxValue: Double?
    @Binding var hoverDate: Date?

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let span = max(1, end.timeIntervalSince(start))
            let bucket = points.count > 1 ? medianGap : 60
            let peak = maxValue ?? max(series.flatMap { item in points.compactMap { $0[keyPath: item.value] } }.max() ?? 0, 1) * 1.15

            Canvas { context, _ in
                func x(_ date: Date) -> CGFloat { CGFloat(date.timeIntervalSince(start) / span) * size.width }
                func y(_ value: Double) -> CGFloat { size.height - CGFloat(min(1, value / peak)) * size.height }

                // 网格：上中下三条
                for fraction in [0.0, 0.5, 1.0] {
                    var grid = Path()
                    let lineY = size.height * fraction
                    grid.move(to: CGPoint(x: 0, y: lineY))
                    grid.addLine(to: CGPoint(x: size.width, y: lineY))
                    context.stroke(grid, with: .color(DS.Palette.track), lineWidth: DS.Size.stroke)
                }

                // 内存压力严重的时段
                for point in points where (point.pressure ?? 0) >= MemoryPressure.critical.rawValue && series.contains(where: { $0.value == \HistoryPoint.memory }) {
                    let rect = CGRect(x: x(point.date), y: 0, width: max(DS.Size.stroke * 2, size.width * CGFloat(bucket / span)), height: size.height)
                    context.fill(Path(rect), with: .color(DS.Palette.error.opacity(0.15)))
                }

                for item in series.reversed() {
                    var segments: [[CGPoint]] = []
                    var previous: Date?
                    for point in points {
                        guard let value = point[keyPath: item.value] else { previous = nil; continue }
                        let location = CGPoint(x: x(point.date), y: y(value))
                        if let previous, point.date.timeIntervalSince(previous) <= bucket * 3, !segments.isEmpty {
                            segments[segments.count - 1].append(location)
                        } else {
                            segments.append([location])
                        }
                        previous = point.date
                    }
                    for segment in segments {
                        var line = Path()
                        line.addLines(segment.count == 1 ? [segment[0], CGPoint(x: segment[0].x + DS.Size.stroke, y: segment[0].y)] : segment)
                        if item.filled, let first = segment.first, let last = segment.last {
                            var area = line
                            area.addLine(to: CGPoint(x: last.x, y: size.height))
                            area.addLine(to: CGPoint(x: first.x, y: size.height))
                            area.closeSubpath()
                            context.fill(area, with: .color(item.color.opacity(0.12)))
                        }
                        context.stroke(line, with: .color(item.color), style: StrokeStyle(lineWidth: DS.Size.chartLine, lineJoin: .round))
                    }
                }

                if let hoverDate {
                    var cursor = Path()
                    cursor.move(to: CGPoint(x: x(hoverDate), y: 0))
                    cursor.addLine(to: CGPoint(x: x(hoverDate), y: size.height))
                    context.stroke(cursor, with: .color(DS.Palette.textTertiary), lineWidth: DS.Size.stroke)
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    hoverDate = start.addingTimeInterval(span * Double(max(0, min(1, location.x / max(1, size.width)))))
                case .ended:
                    hoverDate = nil
                }
            }
        }
    }

    /// 相邻点的典型间隔，即时间桶大小
    private var medianGap: TimeInterval {
        let gaps = zip(points.dropFirst(), points).map { $0.date.timeIntervalSince($1.date) }.sorted()
        return gaps.isEmpty ? 60 : gaps[gaps.count / 2]
    }
}
