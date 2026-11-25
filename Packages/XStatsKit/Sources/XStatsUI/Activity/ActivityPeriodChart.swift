// SPDX-License-Identifier: AGPL-3.0-or-later

import Localization
import SwiftUI

struct ActivityPeriodChart: View {
  typealias Bucket = ActivityPageAnalytics.Bucket

  let buckets: [Bucket]
  let hourly: Bool
  let now: Date
  let calendar: Calendar
  let locale: Locale
  let openDay: (Date) -> Void

  @State private var hovered: Int?
  @State private var selected: Int?
  @FocusState private var focused: Bool
  @Environment(\.isSnapshot) private var isSnapshot
  @Environment(\.layoutDirection) private var contentDirection

  private var step: TimeInterval {
    let unit: TimeInterval = hourly ? 900 : 1_800
    let peak = buckets.lazy.filter { $0.id <= now }.map(\.seconds).max() ?? 0
    return max(1, ceil(peak / (4 * unit))) * unit
  }

  private var cursor: Int? {
    guard let index = selected ?? hovered, buckets.indices.contains(index) else { return nil }
    return index
  }

  var body: some View {
    let step = step
    HStack(alignment: .top, spacing: DS.Space.s2) {
      VStack(alignment: .trailing, spacing: 0) {
        ForEach((0...4).reversed(), id: \.self) { tick in
          if tick != 4 { Spacer(minLength: 0) }
          Text(tick == 0 ? 0.formatted(.number.locale(locale)) : axisDuration(Double(tick) * step))
        }
      }
      .fixedSize(horizontal: true, vertical: false)
      .frame(height: 180)
      .accessibilityHidden(true)

      VStack(spacing: DS.Space.s2) {
        GeometryReader { geometry in
          plot(width: geometry.size.width, ceiling: 4 * step)
        }
        .frame(height: 180)

        GeometryReader { geometry in
          let width = geometry.size.width
          ForEach(axisIndices, id: \.self) { index in
            let x = width * (Double(index) + (hourly ? 0 : 0.5)) / Double(max(1, buckets.count))
            Text(axisDate(at: index))
              .lineLimit(1)
              .fixedSize(horizontal: true, vertical: false)
              .position(x: max(16, min(width - 16, x)), y: 8)
          }
        }
        .frame(height: 16)
        .accessibilityHidden(true)
      }
    }
    .font(.caption)
    .monospacedDigit()
    .foregroundStyle(.secondary)
    .environment(\.layoutDirection, .leftToRight)
  }

  private func plot(width: CGFloat, ceiling: TimeInterval) -> some View {
    let slotWidth = width / Double(max(1, buckets.count))
    return HStack(spacing: 0) {
      ForEach(Array(buckets.enumerated()), id: \.element.id) { index, bucket in
        ActivityCategoryStack(seconds: bucket.secondsByCategory, scale: ceiling, axis: .vertical)
          .frame(width: slotWidth * 0.76)
          .opacity(bucket.id > now ? 0 : 1)
          .frame(width: slotWidth)
          .background(index == cursor ? Color.accentColor.opacity(0.12) : .clear)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background {
      Canvas { context, size in
        var lines = Path()
        for index in 0...4 {
          let y = 0.5 + (size.height - 1) * Double(index) / 4
          lines.move(to: CGPoint(x: 0, y: y))
          lines.addLine(to: CGPoint(x: size.width, y: y))
        }
        context.stroke(lines, with: .color(.secondary.opacity(0.20)), lineWidth: DS.Size.stroke)
      }
    }
    .contentShape(Rectangle())
    .onContinuousHover { phase in
      switch phase {
      case .active(let location):
        hovered = index(at: location.x, slotWidth: slotWidth)
      case .ended:
        hovered = nil
      }
    }
    .gesture(
      SpatialTapGesture().onEnded { tap in
        guard let index = index(at: tap.location.x, slotWidth: slotWidth) else { return }
        selected = index
        focused = true
      }
    )
    .focusable(!isSnapshot)
    .focused($focused)
    .onChange(of: focused) { _, focused in
      if focused {
        selected = selected ?? hovered ?? buckets.lastIndex { $0.id <= now && $0.seconds > 0 }
      }
    }
    .onKeyPress(keys: [.leftArrow, .rightArrow, .escape, .return], phases: [.down, .repeat]) {
      press in
      guard press.modifiers.intersection([.command, .option, .control, .shift]).isEmpty
      else { return .ignored }
      switch press.key {
      case .leftArrow: move(by: -1)
      case .rightArrow: move(by: 1)
      case .escape:
        selected = nil
        hovered = nil
        focused = false
      case .return:
        guard !hourly, let cursor, buckets[cursor].seconds > 0 else { return .ignored }
        openDay(buckets[cursor].id)
      default: return .ignored
      }
      return .handled
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(tr(hourly ? "每小时活动" : "每日活动"))
    .accessibilityValue(
      cursor.map {
        let bucket = buckets[$0]
        let parts =
          [bucketTitle(bucket), ActivityPageFormat.duration(bucket.seconds, locale: locale)]
          + ActivityPageAnalytics.Category.allCases.compactMap { category in
            guard hourly, let seconds = bucket.secondsByCategory[category] else { return nil }
            return "\(category.title) \(ActivityPageFormat.duration(seconds, locale: locale))"
          }
        return parts.joined(separator: " · ")
      } ?? ""
    )
    .accessibilityAdjustableAction { direction in
      switch direction {
      case .increment: move(by: 1)
      case .decrement: move(by: -1)
      @unknown default: break
      }
    }
    .accessibilityActions {
      if !hourly, let cursor, buckets[cursor].seconds > 0 {
        Button(tr("查看当天")) { openDay(buckets[cursor].id) }
      }
    }
    .overlay(alignment: .topLeading) {
      if let cursor {
        let bucket = buckets[cursor]
        let anchor = (Double(cursor) + 0.5) * slotWidth
        let readoutWidth = min(210, width)
        readout(bucket, canOpen: !hourly && selected == cursor && bucket.seconds > 0)
          .frame(width: readoutWidth)
          .offset(
            x: anchor + readoutWidth + 8 < width ? anchor + 8 : max(0, anchor - readoutWidth - 8))
      }
    }
  }

  private func readout(_ bucket: Bucket, canOpen: Bool) -> some View {
    VStack(alignment: .leading, spacing: DS.Space.s1) {
      Text(bucketTitle(bucket)).fontWeight(.semibold)
      Text(ActivityPageFormat.duration(bucket.seconds, locale: locale))
      if hourly {
        ForEach(ActivityPageAnalytics.Category.allCases, id: \.self) { category in
          if let seconds = bucket.secondsByCategory[category], seconds > 0 {
            HStack {
              Circle().fill(category.color).frame(width: 6, height: 6).accessibilityHidden(true)
              Text(category.title)
              Spacer(minLength: DS.Space.s2)
              Text(ActivityPageFormat.duration(seconds, locale: locale))
            }
          }
        }
      }
      if canOpen {
        Button(tr("查看当天")) { openDay(bucket.id) }
          .buttonStyle(.link)
      }
    }
    .padding(DS.Space.s2)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.regularMaterial, in: .rect(cornerRadius: DS.Radius.md))
    .overlay {
      RoundedRectangle(cornerRadius: DS.Radius.md).strokeBorder(.secondary.opacity(0.24))
    }
    .foregroundStyle(.primary)
    .environment(\.layoutDirection, contentDirection)
    .allowsHitTesting(canOpen)
    .accessibilityHidden(!canOpen)
  }

  private var axisIndices: [Int] {
    if hourly {
      return buckets.indices.filter {
        calendar.component(.hour, from: buckets[$0].id).isMultiple(of: 6)
      } + [buckets.count]
    }
    return Set([0, 6, 13, 20, buckets.count - 1]).filter(buckets.indices.contains).sorted()
  }

  private func axisDate(at index: Int) -> String {
    if hourly {
      let hour = index == buckets.count ? 24 : calendar.component(.hour, from: buckets[index].id)
      return hour.formatted(.number.precision(.integerLength(2)).locale(locale))
    }
    return buckets[index].id.formatted(dateStyle.day())
  }

  private var dateStyle: Date.FormatStyle {
    Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
  }

  private func bucketTitle(_ bucket: Bucket) -> String {
    guard hourly else { return bucket.id.formatted(dateStyle.month().day().weekday(.wide)) }
    let end = bucket.interval.end
    if calendar.timeZone.secondsFromGMT(for: bucket.id)
      != calendar.timeZone.secondsFromGMT(for: end)
    {
      let startTime = ActivityPageFormat.time(bucket.id, calendar: calendar, locale: locale)
      let endTime = ActivityPageFormat.time(end, calendar: calendar, locale: locale)
      let startZone = calendar.timeZone.abbreviation(for: bucket.id) ?? ""
      let endZone = calendar.timeZone.abbreviation(for: end) ?? ""
      return "\(startTime) \(startZone) – \(endTime) \(endZone)"
    }
    let style = Date.IntervalFormatStyle(
      date: .omitted, time: .shortened, locale: locale, calendar: calendar,
      timeZone: calendar.timeZone)
    return (bucket.id..<end).formatted(style)
  }

  private func axisDuration(_ seconds: TimeInterval) -> String {
    Duration.seconds(seconds).formatted(
      .units(allowed: [.hours, .minutes], width: .abbreviated).locale(locale))
  }

  private func index(at x: CGFloat, slotWidth: CGFloat) -> Int? {
    guard slotWidth > 0, !buckets.isEmpty else { return nil }
    let index = Int(max(0, min(Double(buckets.count - 1), floor(x / slotWidth))))
    return buckets[index].id <= now ? index : nil
  }

  private func move(by offset: Int) {
    guard let last = buckets.lastIndex(where: { $0.id <= now }) else { return }
    selected = cursor.map { max(0, min(last, $0 + offset)) } ?? (offset > 0 ? 0 : last)
  }
}

struct ActivityCategoryStack: View {
  let seconds: [ActivityPageAnalytics.Category: TimeInterval]
  let scale: TimeInterval
  let axis: Axis

  var body: some View {
    Canvas { context, size in
      let vertical = axis == .vertical
      let extent = vertical ? size.height : size.width
      var offset: CGFloat = 0
      for category in ActivityPageAnalytics.Category.allCases {
        guard let value = seconds[category], value > 0 else { continue }
        let length = extent * value / scale
        let bounds =
          vertical
          ? CGRect(x: 0, y: extent - offset - length, width: size.width, height: length)
          : CGRect(x: offset, y: 0, width: length, height: size.height)
        context.fill(Path(bounds), with: .color(category.color))
        offset += length
      }
    }
    .accessibilityHidden(true)
  }
}
