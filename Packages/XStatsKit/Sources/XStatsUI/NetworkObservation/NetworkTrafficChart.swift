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
  let points: [NetworkTrafficPoint]
  let samples: [NetworkTrafficChartSample]
  let available: Bool
  var interval: TimeInterval = 300
  var summarizesHistory = false

  var body: some View {
    VStack(alignment: .leading, spacing: DS.Space.s3) {
      if samples.isEmpty {
        ViewThatFits(in: .horizontal) {
          HStack(spacing: DS.Space.s3) {
            title
            emptyMessage
          }
          VStack(alignment: .leading, spacing: DS.Space.s1) {
            title
            emptyMessage
          }
        }
      } else {
        ViewThatFits(in: .horizontal) {
          HStack(spacing: DS.Space.s3) {
            title
            Spacer(minLength: DS.Space.s2)
            summary
          }
          VStack(alignment: .leading, spacing: DS.Space.s2) {
            title
            summary
          }
        }
        chart(samples: samples, points: points)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var title: some View {
    Text(tr("流量走势")).dsFont(.sm, weight: .semibold).fixedSize()
  }

  private var emptyMessage: some View {
    Text(
      !available
        ? tr("更新网络组件后可查看流量走势")
        : (summarizesHistory ? tr("此时段无流量统计") : tr("暂无流量数据"))
    )
    .dsFont(.xs).foregroundStyle(DS.Palette.textSecondary)
    .fixedSize(horizontal: false, vertical: true)
  }

  private var summary: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: DS.Space.s3) {
        period
        totals
      }
      VStack(alignment: .leading, spacing: DS.Space.s1) {
        period
        totals
      }
    }
  }

  private var period: some View {
    Text(summarizesHistory ? tr("时段累计") : tr("最近 1 分钟"))
      .dsFont(.xs).foregroundStyle(DS.Palette.textSecondary).fixedSize()
  }

  private var totals: some View {
    HStack(spacing: DS.Space.s3) {
      ForEach(NetworkTrafficChartSample.Direction.allCases, id: \.self) { direction in
        HStack(spacing: DS.Space.s1) {
          Image(systemName: direction == .received ? "arrow.down" : "arrow.up")
            .accessibilityHidden(true)
          Text(direction.title)
          Text(verbatim: summary(points: points, direction: direction)).monospacedDigit()
        }
        .foregroundStyle(direction == .received ? DS.Palette.primary : DS.Palette.success)
      }
    }.dsFont(.xs).fixedSize()
  }

  private func summary(
    points: [NetworkTrafficPoint], direction: NetworkTrafficChartSample.Direction
  )
    -> String
  {
    let rates = points.map {
      direction == .received ? $0.receivedBytesPerSecond : $0.sentBytesPerSecond
    }
    let value: Double?
    if summarizesHistory {
      let known = rates.compactMap { $0 }.filter { $0.isFinite && $0 >= 0 }
      value = known.isEmpty ? nil : known.reduce(0, +) * 5
    } else {
      value = rates.last ?? nil
    }
    guard let value, value.isFinite, value >= 0 else { return "—" }
    return Format.bytes(value) + (summarizesHistory ? "" : "/s")
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
    .chartLegend(.hidden)
    .chartXScale(
      domain: end.addingTimeInterval(-interval)...end,
      range: .plotDimension(padding: 20)
    )
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
    .frame(height: 132)
    .environment(\.locale, L10n.locale)
    .accessibilityLabel(tr("流量走势"))
  }
}
