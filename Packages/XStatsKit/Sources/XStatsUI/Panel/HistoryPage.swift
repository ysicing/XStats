import Localization
import Metrics
import SwiftUI

/// 历史：回看最近 1 小时、24 小时、7 天的 CPU、内存、网络、GPU、温度与功耗，支持指针与键盘选点。
struct HistoryPage: View {
  @Environment(AppModel.self) private var model
  @Environment(\.isSnapshot) private var isSnapshot
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
        SegmentedControl(
          selection: Binding(get: { history.range }, set: { history.load($0) }),
          options: HistoryRecorder.Range.allCases.map { ($0, $0.title) }
        )
        .frame(width: DS.Size.sidebarWidth + DS.Space.s16)
        Spacer()
        Text(
          verbatim: hoverDate.map {
            "\($0.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, locale: L10n.locale)))"
          }
            ?? (points.isEmpty ? "" : tr("每点 \(bucketTitle(history.range))"))
        )
        .dsFont(.xs)
        .foregroundStyle(DS.Palette.textSecondary)
        .monospacedDigit()
      }

      if !settings.historyEnabled {
        InfoBanner(icon: "pause.circle", text: tr("历史记录已关闭，下面是关闭前记录的数据。"), tone: .warning) {
          Button(tr("开启")) { settings.historyEnabled = true }.buttonStyle(
            DSButtonStyle(kind: .primary))
        }
      }

      if points.isEmpty {
        Card {
          Text(history.isQuerying ? tr("正在读取…") : tr("这段时间还没有记录。XStats 运行时每分钟记录一次，睡眠与锁屏期间不记录。"))
            .dsFont(.sm)
            .foregroundStyle(DS.Palette.textSecondary)
        }
      } else {
        HistoryChartCard(
          icon: "cpu", title: "CPU", points: points, start: start, end: end, hoverDate: $hoverDate,
          series: [
            .init(label: tr("平均"), color: DS.Palette.primary, value: \.cpu),
            .init(
              label: tr("峰值"), color: DS.Palette.primary.opacity(0.35), value: \.cpuMax,
              filled: false),
          ],
          maxValue: 1, format: { Format.percent($0) })
        HistoryChartCard(
          icon: "memorychip", title: tr("内存"), points: points, start: start, end: end,
          hoverDate: $hoverDate,
          series: [.init(label: tr("已用"), color: DS.Palette.primary, value: \.memory)],
          maxValue: 1, format: { Format.percent($0) },
          note: criticalNote(points))
        HistoryChartCard(
          icon: "network", title: tr("网络"), points: points, start: start, end: end,
          hoverDate: $hoverDate,
          series: [
            .init(
              label: tr("下载"), color: Color(nsColor: DS.NetworkPalette.download), value: \.download),
            .init(
              label: tr("上传"), color: Color(nsColor: DS.NetworkPalette.upload), value: \.upload,
              filled: false),
          ],
          maxValue: nil, format: { Format.menuBarRate($0) })
        HistoryChartCard(
          icon: "square.3.layers.3d", title: "GPU", points: points, start: start, end: end,
          hoverDate: $hoverDate,
          series: [.init(label: tr("占用"), color: DS.Palette.primary, value: \.gpu)],
          maxValue: 1, format: { Format.percent($0) },
          emptyNote: tr("只在菜单栏显示 GPU 或打开 GPU 相关页面时记录"))
        HistoryChartCard(
          icon: "thermometer.medium", title: tr("CPU 温度"), points: points, start: start, end: end,
          hoverDate: $hoverDate,
          series: [.init(label: tr("最高"), color: DS.Palette.warning, value: \.temperature)],
          maxValue: nil, format: { Format.temperature($0, fahrenheit: settings.useFahrenheit) },
          emptyNote: tr("只在显示温度或开启过热通知时记录"))
        HistoryChartCard(
          icon: "bolt", title: tr("整机功耗"), points: points, start: start, end: end,
          hoverDate: $hoverDate,
          series: [.init(label: tr("平均"), color: DS.Palette.warning, value: \.power)],
          maxValue: nil, format: { Format.watts($0) },
          emptyNote: tr("只在显示功耗时记录"))
        if model.store.battery != nil {
          HistoryChartCard(
            icon: "battery.75", title: tr("电池电量"), points: points, start: start, end: end,
            hoverDate: $hoverDate,
            series: [.init(label: tr("电量"), color: DS.Palette.success, value: \.battery)],
            maxValue: 1, format: { Format.percent($0) },
            emptyNote: tr("只在显示电池信息时记录"))
        }
      }

      SettingsGroup(caption: tr("历史记录")) {
        GroupRow(showsDivider: false) {
          SettingRow(title: tr("记录历史数据"), subtitle: tr("主要指标每分钟写入本机数据库并保留 7 天")) {
            DSToggle(isOn: $settings.historyEnabled, label: tr("记录历史数据"))
          }
        }
        GroupRow {
          SettingRow(title: tr("清除历史"), subtitle: tr("清除本机记录的指标历史")) {
            Button(tr("清除…")) { confirmingClear = true }
              .buttonStyle(DSButtonStyle(kind: .secondary))
              .disabled(history.recordCount == 0)
          }
        }
      }
    }
    // 主窗口只是关闭而不销毁视图，需随可见性启停轮询；重新可见时立即补一次。
    .task(id: model.isMainWindowVisible) {
      guard !isSnapshot, model.isMainWindowVisible else { return }
      // 页面可见期间每分钟补上新记录的一点
      history.load()
      while !Task.isCancelled {
        do { try await Task.sleep(for: .seconds(60)) } catch { break }
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

struct HistoryChartCard: View {
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
  var language: AppLanguage?

  private var displayLanguage: AppLanguage { language ?? L10n.language }

  var body: some View {
    let hasData = series.contains { item in points.contains { $0[keyPath: item.value] != nil } }
    let bucket = medianGap
    let selectedPoint = hoverPoint(bucket: bucket)
    let summaries = series.map { summary($0) }
    let readings = series.map { item in
      selectedPoint?[keyPath: item.value].map(format)
        ?? L10n.translate("无样本", language: displayLanguage)
    }
    let accessibilitySummary =
      (selectedPoint?.date ?? hoverDate).map { Self.moment($0, language: displayLanguage) }
      ?? "\(Self.moment(start, language: displayLanguage)) – \(Self.moment(end, language: displayLanguage))"

    Card {
      CardHeader(icon: icon, title: title) {
        if let date = selectedPoint?.date ?? hoverDate {
          Text(verbatim: Self.moment(date, language: displayLanguage))
            .dsFont(.xs)
            .foregroundStyle(DS.Palette.textSecondary)
            .monospacedDigit()
        }
      }
      ForEach(series.indices, id: \.self) { index in
        legend(
          series[index], detail: hoverDate == nil ? summaries[index] : readings[index])
      }
      if hasData {
        TimeSeriesChart(
          points: points, start: start, end: end, series: series, maxValue: maxValue,
          bucket: bucket, selectedPoint: selectedPoint, format: format, title: title,
          accessibilitySummary: ([accessibilitySummary]
            + series.indices.map { index in
              "\(series[index].label): \(hoverDate == nil ? summaries[index] : readings[index])"
            }).joined(separator: "\n"),
          language: displayLanguage, hoverDate: $hoverDate
        )
        .frame(height: DS.Size.chartHeight * 2)
        HStack {
          Text(verbatim: Self.moment(start, language: displayLanguage))
          Spacer()
          Text(
            verbatim: Self.moment(
              start.addingTimeInterval(end.timeIntervalSince(start) / 2), language: displayLanguage)
          )
          Spacer()
          Text(L10n.translate("现在", language: displayLanguage))
        }
        .dsFont(.xs)
        .foregroundStyle(DS.Palette.textTertiary)
        .monospacedDigit()
        .environment(\.layoutDirection, .leftToRight)
        if let note {
          Text(note).dsFont(.xs).foregroundStyle(DS.Palette.textTertiary)
        }
      } else {
        Text(emptyNote ?? L10n.translate("这段时间没有记录", language: displayLanguage))
          .dsFont(.xs).foregroundStyle(DS.Palette.textTertiary)
      }
    }
  }

  /// 同一天只显示时间，跨天带上日期
  static func moment(_ date: Date, language: AppLanguage) -> String {
    let locale = L10n.locale(for: language)
    return Calendar.current.isDateInToday(date)
      ? date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: locale))
      : date.formatted(.dateTime.locale(locale).month(.abbreviated).day().hour().minute())
  }

  func hoverPoint(bucket: TimeInterval) -> HistoryPoint? {
    guard let hoverDate,
      let closest = points.min(by: {
        abs($0.date.timeIntervalSince(hoverDate)) < abs($1.date.timeIntervalSince(hoverDate))
      }),
      abs(closest.date.timeIntervalSince(hoverDate)) <= bucket / 2
    else { return nil }
    // 断档中的游标不能借用远处的读数，也不能把缺失样本显示成零。
    return closest
  }

  /// 相邻点的典型间隔，即时间桶大小。
  private var medianGap: TimeInterval {
    let gaps = zip(points.dropFirst(), points).map { $0.date.timeIntervalSince($1.date) }.sorted()
    return gaps.isEmpty ? 60 : gaps[gaps.count / 2]
  }

  private func summary(_ item: Series) -> String {
    let samples = points.compactMap { point -> (date: Date, value: Double)? in
      guard let value = point[keyPath: item.value] else { return nil }
      return (point.date, value)
    }
    guard let peak = samples.max(by: { $0.value < $1.value }) else {
      return L10n.translate("无样本", language: displayLanguage)
    }
    let average = samples.reduce(0) { $0 + $1.value } / Double(samples.count)
    let time = L10n.translate(
      "（\(Self.moment(peak.date, language: displayLanguage))）", language: displayLanguage)
    return L10n.translate(
      "平均 \(format(average)) · 峰值 \(format(peak.value))\(time)", language: displayLanguage)
  }

  private func legend(_ item: Series, detail: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: DS.Space.s2) {
      Circle().fill(item.color).frame(width: DS.Space.s2, height: DS.Space.s2)
        .accessibilityHidden(true)
      Text(verbatim: item.label)
        .dsFont(.xs, weight: .medium)
        .foregroundStyle(DS.Palette.textPrimary)
      Spacer(minLength: DS.Space.s2)
      Text(verbatim: detail)
        .dsFont(.xs)
        .foregroundStyle(DS.Palette.textSecondary)
        .monospacedDigit()
        .multilineTextAlignment(.trailing)
        .fixedSize(horizontal: false, vertical: true)
    }
    .accessibilityElement(children: .combine)
  }
}

/// 按时间定位的折线图：相邻两点间隔超过 3 个时间桶视为没有记录（睡眠、关机），线条断开
struct TimeSeriesChart: View {
  let points: [HistoryPoint]
  let start: Date
  let end: Date
  let series: [HistoryChartCard.Series]
  let maxValue: Double?
  let bucket: TimeInterval
  let selectedPoint: HistoryPoint?
  let format: (Double) -> String
  let title: String
  let accessibilitySummary: String
  var language: AppLanguage?
  @Binding var hoverDate: Date?
  @Environment(\.isSnapshot) private var isSnapshot
  @FocusState private var isFocused: Bool
  @State private var isHovering = false

  var body: some View {
    let peak =
      maxValue ?? max(
        series.flatMap { item in points.compactMap { $0[keyPath: item.value] } }.max() ?? 0, 1)
      * 1.15

    HStack(spacing: DS.Space.s2) {
      VStack(alignment: .trailing, spacing: 0) {
        Text(verbatim: format(peak))
        Spacer(minLength: 0)
        Text(verbatim: format(peak / 2))
        Spacer(minLength: 0)
        Text(verbatim: format(0))
      }
      .dsFont(.xs)
      .foregroundStyle(DS.Palette.textTertiary)
      .monospacedDigit()
      .accessibilityHidden(true)

      GeometryReader { proxy in
        let size = proxy.size
        let span = max(1, end.timeIntervalSince(start))

        Canvas { context, _ in
          func x(_ date: Date) -> CGFloat {
            CGFloat(date.timeIntervalSince(start) / span) * size.width
          }
          func y(_ value: Double) -> CGFloat {
            size.height - CGFloat(min(1, value / peak)) * size.height
          }

          // 网格：上中下三条
          for fraction in [0.0, 0.5, 1.0] {
            var grid = Path()
            let lineY = size.height * fraction
            grid.move(to: CGPoint(x: 0, y: lineY))
            grid.addLine(to: CGPoint(x: size.width, y: lineY))
            context.stroke(grid, with: .color(DS.Palette.track), lineWidth: DS.Size.stroke)
          }

          // 内存压力严重的时段
          for point in points
          where (point.pressure ?? 0) >= MemoryPressure.critical.rawValue
            && series.contains(where: { $0.value == \HistoryPoint.memory })
          {
            let rect = CGRect(
              x: x(point.date), y: 0,
              width: max(DS.Size.stroke * 2, size.width * CGFloat(bucket / span)),
              height: size.height
            )
            context.fill(Path(rect), with: .color(DS.Palette.error.opacity(0.15)))
          }

          for item in series.reversed() {
            var segments: [[CGPoint]] = []
            var previous: Date?
            for point in points {
              guard let value = point[keyPath: item.value] else {
                previous = nil
                continue
              }
              let location = CGPoint(x: x(point.date), y: y(value))
              if let previous, point.date.timeIntervalSince(previous) <= bucket * 3,
                !segments.isEmpty
              {
                segments[segments.count - 1].append(location)
              } else {
                segments.append([location])
              }
              previous = point.date
            }
            for segment in segments {
              var line = Path()
              line.addLines(
                segment.count == 1
                  ? [segment[0], CGPoint(x: segment[0].x + DS.Size.stroke, y: segment[0].y)]
                  : segment
              )
              if item.filled, let first = segment.first, let last = segment.last {
                var area = line
                area.addLine(to: CGPoint(x: last.x, y: size.height))
                area.addLine(to: CGPoint(x: first.x, y: size.height))
                area.closeSubpath()
                context.fill(area, with: .color(item.color.opacity(0.12)))
              }
              context.stroke(
                line, with: .color(item.color),
                style: StrokeStyle(lineWidth: DS.Size.chartLine, lineJoin: .round))
            }
          }

          if let hoverDate {
            var cursor = Path()
            let cursorX = x(selectedPoint?.date ?? hoverDate)
            cursor.move(to: CGPoint(x: cursorX, y: 0))
            cursor.addLine(to: CGPoint(x: cursorX, y: size.height))
            context.stroke(cursor, with: .color(DS.Palette.textTertiary), lineWidth: DS.Size.stroke)
            if let selectedPoint {
              for item in series {
                guard let value = selectedPoint[keyPath: item.value] else { continue }
                let diameter = DS.Space.s2
                let dot = CGRect(
                  x: cursorX - diameter / 2, y: y(value) - diameter / 2,
                  width: diameter, height: diameter)
                context.fill(Path(ellipseIn: dot), with: .color(item.color))
              }
            }
          }
        }
        .contentShape(Rectangle())
        .onContinuousHover { phase in
          switch phase {
          case .active(let location):
            if !isHovering { isHovering = true }
            let date = start.addingTimeInterval(
              span * Double(max(0, min(1, location.x / max(1, size.width)))))
            let closest = points.min {
              abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date))
            }
            DS.Motion.select {
              hoverDate =
                closest.flatMap {
                  abs($0.date.timeIntervalSince(date)) <= bucket / 2 ? $0.date : nil
                } ?? date
            }
          case .ended:
            isHovering = false
            if !isFocused { hoverDate = nil }
          }
        }
        .onTapGesture { isFocused = true }
      }
    }
    .environment(\.layoutDirection, .leftToRight)
    .focusable(!isSnapshot)
    .focused($isFocused)
    .onChange(of: isFocused) { _, focused in
      DS.Motion.select {
        if focused {
          hoverDate = hoverDate ?? points.last?.date
        } else if !isHovering {
          hoverDate = nil
        }
      }
    }
    .onKeyPress(keys: [.leftArrow, .rightArrow, .escape], phases: [.down, .repeat]) { press in
      guard isFocused,
        press.modifiers.intersection([.command, .option, .control, .shift]).isEmpty
      else { return .ignored }
      if press.key == .escape {
        DS.Motion.select { hoverDate = nil }
        isFocused = false
      } else {
        moveSelection(by: press.key == .leftArrow ? -1 : 1)
      }
      return .handled
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(Text(verbatim: title))
    .accessibilityValue(Text(verbatim: accessibilitySummary))
    .accessibilityHint(
      Text(L10n.translate("使用左右方向键逐点查看历史数据", language: language ?? L10n.language))
    )
    .accessibilityAdjustableAction { direction in
      switch direction {
      case .increment: moveSelection(by: 1)
      case .decrement: moveSelection(by: -1)
      @unknown default: break
      }
    }
  }

  func moveSelection(by offset: Int) {
    guard !points.isEmpty else { return }
    let index = hoverDate.flatMap { date in
      points.indices.min {
        abs(points[$0].date.timeIntervalSince(date)) < abs(points[$1].date.timeIntervalSince(date))
      }
    }
    let next =
      index.map { max(0, min(points.count - 1, $0 + offset)) }
      ?? (offset > 0 ? 0 : points.count - 1)
    DS.Motion.select { hoverDate = points[next].date }
  }
}
