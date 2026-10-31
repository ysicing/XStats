// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Charts
import Localization
import Metrics
import NetworkObservation
import SwiftUI

struct NetworkTrafficChartSample: Identifiable {
  enum Direction: String, CaseIterable, Hashable {
    case received, sent

    var title: String { self == .received ? tr("下行") : tr("上行") }
  }

  struct ID: Hashable {
    let date: Date
    let direction: Direction
  }

  var id: ID { ID(date: date, direction: direction) }
  let date: Date
  let rate: Double
  let direction: Direction
  let series: String

  static func make(points: [NetworkTrafficPoint]) -> [Self] {
    var samples: [Self] = []
    for direction in Direction.allCases {
      var run = 0
      for point in points {
        let rate =
          direction == .received ? point.receivedBytesPerSecond : point.sentBytesPerSecond
        guard let rate, rate.isFinite, rate >= 0 else {
          // 除核心提供的暂停分段外，单方向缺测也必须断线，不能把未知绘成零。
          run += 1
          continue
        }
        samples.append(
          Self(
            date: point.date, rate: rate, direction: direction,
            series: "\(direction.rawValue):\(point.segment):\(run)"))
      }
    }
    return samples
  }

  static func window(_ points: [NetworkTrafficPoint], interval: TimeInterval)
    -> [NetworkTrafficPoint]
  {
    guard let end = points.last?.date else { return [] }
    let start = end.addingTimeInterval(-interval)
    return Array(points.drop { $0.date <= start })
  }
}

struct NetworkTrafficChart: View {
  let history: NetworkTrafficHistory
  let available: Bool
  let matching: (ObservedConnection) -> Bool
  var providedPoints: [NetworkTrafficPoint]? = nil
  @State private var interval: TimeInterval = 300

  var body: some View {
    VStack(alignment: .leading, spacing: DS.Space.s2) {
      HStack(spacing: DS.Space.s2) {
        Text(tr("流量走势")).dsFont(.sm, weight: .semibold)
        Spacer(minLength: DS.Space.s1)
        if available {
          Picker(tr("时间范围"), selection: $interval) {
            Text(tr("1 分钟")).tag(TimeInterval(60))
            Text(tr("5 分钟")).tag(TimeInterval(300))
            Text(tr("15 分钟")).tag(TimeInterval(900))
          }.pickerStyle(.segmented).labelsHidden().fixedSize()
        }
      }
      if available {
        let points =
          providedPoints.map { NetworkTrafficChartSample.window($0, interval: interval) }
          ?? history.points(interval: interval, matching: matching)
        let samples = NetworkTrafficChartSample.make(points: points)
        if samples.isEmpty {
          Text(tr("暂无流量数据")).dsFont(.xs).foregroundStyle(DS.Palette.textSecondary)
            .frame(maxWidth: .infinity, minHeight: 72)
        } else {
          chart(samples: samples, points: points)
        }
      } else {
        Text(tr("更新网络组件后可查看流量走势"))
          .dsFont(.xs).foregroundStyle(DS.Palette.textSecondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private func chart(samples: [NetworkTrafficChartSample], points: [NetworkTrafficPoint])
    -> some View
  {
    let end = points.last?.date ?? Date()
    return Chart(samples) { sample in
      LineMark(
        x: .value(tr("时间"), sample.date),
        y: .value(tr("传输速率"), sample.rate),
        series: .value("segment", sample.series)
      )
      .foregroundStyle(by: .value(tr("方向"), sample.direction.title))
      .lineStyle(
        StrokeStyle(lineWidth: 1.5, dash: sample.direction == .sent ? [4, 3] : []))
      // 孤立的有效采样仍可见，不因前后缺口而消失。
      PointMark(
        x: .value(tr("时间"), sample.date),
        y: .value(tr("传输速率"), sample.rate)
      )
      .foregroundStyle(by: .value(tr("方向"), sample.direction.title))
      .symbolSize(6)
      .accessibilityLabel(sample.direction.title)
      .accessibilityValue(
        "\(sample.date.formatted(.dateTime.hour().minute().second().locale(L10n.locale))), \(Format.bytes(sample.rate))/s"
      )
    }
    .chartForegroundStyleScale(
      domain: [tr("下行"), tr("上行")],
      range: [DS.Palette.primary, DS.Palette.success]
    )
    .chartLegend(position: .top, alignment: .leading, spacing: DS.Space.s1)
    .chartXScale(domain: end.addingTimeInterval(-interval)...end)
    .chartYScale(domain: .automatic(includesZero: true))
    .chartXAxis {
      AxisMarks(values: .automatic(desiredCount: 3)) { value in
        AxisValueLabel {
          if let date = value.as(Date.self) {
            Text(date, format: .dateTime.hour().minute().locale(L10n.locale))
          }
        }
      }
    }
    .chartYAxis {
      AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
        AxisGridLine()
        AxisValueLabel {
          if let rate = value.as(Double.self) {
            Text(verbatim: "\(Format.bytes(rate))/s")
          }
        }
      }
    }
    .frame(height: 94)
    .environment(\.locale, L10n.locale)
    .accessibilityLabel(tr("流量走势"))
  }
}
