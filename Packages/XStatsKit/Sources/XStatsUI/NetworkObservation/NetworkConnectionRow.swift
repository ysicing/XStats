// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Localization
import NetworkObservation
import SwiftUI

/// 表头与记录共享列宽，窗口变窄时由页面切换为紧凑行，不写回几何状态。
struct NetworkConnectionColumns {
  let width: CGFloat
  private var available: CGFloat { max(0, width - 22 - DS.Space.s3 * 5) }
  var destination: CGFloat { available * 0.29 }
  var transport: CGFloat { available * 0.12 }
  var time: CGFloat { available * 0.24 }
  var location: CGFloat { available * 0.21 }
  var application: CGFloat { available * 0.14 }
}

struct NetworkConnectionTableHeader: View {
  let columns: NetworkConnectionColumns

  var body: some View {
    HStack(spacing: DS.Space.s3) {
      Color.clear.frame(width: 22, height: 1)
      Text(tr("目标")).frame(width: columns.destination, alignment: .leading)
      Text(tr("协议 / 端口")).frame(width: columns.transport, alignment: .leading)
      Text(tr("时间"))
        .frame(width: columns.time, alignment: .leading)
      Text(tr("地区")).frame(width: columns.location, alignment: .leading)
      Text(tr("应用 / PID")).frame(width: columns.application, alignment: .leading)
    }.dsFont(.xs).foregroundStyle(DS.Palette.textTertiary)
      .padding(.vertical, DS.Space.s1)
      .accessibilityHidden(true)
  }
}

struct NetworkConnectionRow: View {
  let record: ObservedConnection
  let locationName: String
  let showsHistory: Bool
  let showsApplication: Bool
  let columns: NetworkConnectionColumns?
  let availableWidth: CGFloat

  var body: some View {
    Group {
      if let columns {
        HStack(alignment: .top, spacing: DS.Space.s3) {
          direction
          destination.frame(width: columns.destination, alignment: .leading)
          transport.frame(width: columns.transport, alignment: .leading)
          timing.frame(width: columns.time, alignment: .leading)
          location.frame(width: columns.location, alignment: .leading)
          application.frame(width: columns.application, alignment: .leading)
        }
      } else {
        HStack(alignment: .top, spacing: DS.Space.s2) {
          direction
          VStack(alignment: .leading, spacing: DS.Space.s1) {
            destination
            transport
            if showsHistory { timing }
          }.frame(width: max(0, availableWidth - 22 - DS.Space.s2 * 2) * 0.58, alignment: .leading)
          VStack(alignment: .trailing, spacing: DS.Space.s1) {
            location
            application
          }.frame(width: max(0, availableWidth - 22 - DS.Space.s2 * 2) * 0.42, alignment: .trailing)
        }
      }
    }.padding(.vertical, DS.Space.s2)
  }

  private var direction: some View {
    Image(systemName: record.direction == .outbound ? "arrow.up.right" : "arrow.down.left")
      .font(.system(size: 10, weight: .medium)).foregroundStyle(DS.Palette.textSecondary)
      .frame(width: 22, height: 22)
      .background(DS.Palette.surface, in: RoundedRectangle(cornerRadius: DS.Radius.sm))
      .accessibilityLabel(record.direction == .outbound ? tr("出站") : tr("入站"))
  }

  private var destination: some View {
    VStack(alignment: .leading, spacing: DS.Space.s1) {
      Text(verbatim: record.hostname ?? record.address ?? tr("目标未知"))
        .dsFont(.sm, weight: .medium).lineLimit(2)
        .help(record.hostname ?? record.address ?? tr("目标未知"))
      if let address = record.address, record.hostname != nil {
        Text(verbatim: address).dsFont(.xs).foregroundStyle(DS.Palette.textSecondary)
          .lineLimit(1).help(address)
      }
    }.textSelection(.enabled)
  }

  private var transport: some View {
    Text(
      verbatim: [record.transport.rawValue.uppercased(), record.port.map(String.init)]
        .compactMap { $0 }.joined(separator: "  ")
    )
    .dsFont(.xs).foregroundStyle(DS.Palette.textSecondary)
    .fixedSize(horizontal: false, vertical: true)
  }

  @ViewBuilder private var timing: some View {
    if showsHistory {
      VStack(alignment: .leading, spacing: DS.Space.s1) {
        ViewThatFits(in: .horizontal) {
          HStack(spacing: DS.Space.s1) {
            timestamp
            if let closed = record.closedAt {
              Image(systemName: "arrow.right").accessibilityHidden(true)
              Text(closed, format: .dateTime.hour().minute().second().locale(L10n.locale))
            }
          }.fixedSize()
          VStack(alignment: .leading, spacing: DS.Space.s1) {
            timestamp
            if let closed = record.closedAt {
              Text(closed, format: .dateTime.hour().minute().second().locale(L10n.locale))
            }
          }
        }
        Text(record.closedAt == nil ? tr("未记录结束") : tr("已结束"))
          .fixedSize(horizontal: false, vertical: true)
      }.dsFont(.xs).foregroundStyle(DS.Palette.textTertiary).monospacedDigit()
    } else {
      timestamp.dsFont(.xs).monospacedDigit().foregroundStyle(DS.Palette.textSecondary)
    }
  }

  private var timestamp: some View {
    Text(record.timestamp, format: .dateTime.hour().minute().second().locale(L10n.locale))
  }

  private var location: some View {
    Text(verbatim: locationName).dsFont(.sm).foregroundStyle(DS.Palette.textSecondary)
      .lineLimit(2).help(locationName)
  }

  private var application: some View {
    VStack(alignment: columns == nil ? .trailing : .leading, spacing: DS.Space.s1) {
      if showsApplication {
        Text(verbatim: record.applicationName).lineLimit(1).help(record.applicationName)
      }
      Text(verbatim: "PID \(record.processID)").monospacedDigit()
    }.dsFont(.xs).foregroundStyle(DS.Palette.textTertiary)
  }
}
