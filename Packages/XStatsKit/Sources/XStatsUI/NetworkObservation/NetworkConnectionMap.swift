// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Localization
import NetworkObservation
import SwiftUI

struct NetworkMapDestination: Identifiable {
  var id: String { location?.mapKey ?? country.code }
  let country: NetworkCountry
  let count: Int
  let latest: Date
  var location: NetworkIPLocation? = nil

  static func make(world: [NetworkCountry], regions: [NetworkHistoryRegion]) -> [Self] {
    regions.compactMap { region in
      let parts = region.key.components(separatedBy: "|")
      guard let country = world.first(where: { $0.code == parts[0] }) else { return nil }
      var location: NetworkIPLocation?
      if parts[0] == "CN", parts.count > 1 {
        let city = parts.count > 2 ? parts[2] : ""
        let point =
          NetworkCityCoordinates.points[parts[1] + "|" + city]
          ?? NetworkCityCoordinates.points[parts[1] + "|"]
        location = NetworkIPLocation(
          province: parts[1], city: city,
          longitude: point?.first, latitude: point?.last)
      }
      return Self(country: country, count: region.count, latest: region.latest, location: location)
    }
  }

  static func make(
    world: [NetworkCountry], records: [ObservedConnection], countries: [String: String],
    locations: [String: NetworkIPLocation] = [:], limit: Int = 12
  ) -> [Self] {
    let grouped = Dictionary(grouping: records) {
      $0.address.flatMap { locations[$0]?.mapKey ?? countries[$0] } ?? "??"
    }
    return grouped.compactMap { key, records -> Self? in
      let code = key.split(separator: "|", maxSplits: 1).first.map(String.init) ?? key
      guard let country = world.first(where: { $0.code == code }),
        let latest = records.map(\.timestamp).max()
      else {
        return nil
      }
      return Self(
        country: country, count: records.count, latest: latest,
        location: records.first?.address.flatMap { locations[$0] })
    }.sorted {
      $0.latest == $1.latest ? $0.id < $1.id : $0.latest > $1.latest
    }.prefix(max(0, min(64, limit))).map { $0 }
  }
}

/// 每次恢复读取都重新建立基线；筛选和活动计数更新不能重播已有连接。
struct NetworkMapActivity {
  private var startedAt: Date?
  private var seenIDs: Set<UUID> = []

  mutating func begin(records: [ObservedConnection], at date: Date?) {
    startedAt = date
    seenIDs = Set(records.map(\.id))
  }

  mutating func consume(
    records: [ObservedConnection], countries: [String: String]
  ) -> Set<String> {
    defer { seenIDs.formIntersection(Set(records.map(\.id))) }
    guard let startedAt else { return [] }
    var arrivals: Set<String> = []
    for record in records where !seenIDs.contains(record.id) && record.timestamp > startedAt {
      // 新地址的离线查询可能晚一帧返回；未定位前保留待处理状态，定位后只消费一次。
      guard let country = record.address.flatMap({ countries[$0] }) else { continue }
      seenIDs.insert(record.id)
      arrivals.insert(country)
    }
    return arrivals
  }
}

struct ConnectionWorldMap: View {
  let world: [NetworkCountry]
  let records: [ObservedConnection]
  let observedRecords: [ObservedConnection]
  let countries: [String: String]
  var locations: [String: NetworkIPLocation] = [:]
  var providedDestinations: [NetworkMapDestination]? = nil
  let isReading: Bool
  let selectCountry: (String) -> Void

  @State private var expanded = false

  var body: some View {
    ConnectionMapSurface(
      world: world, records: records, observedRecords: observedRecords,
      countries: countries, locations: locations, providedDestinations: providedDestinations,
      isReading: isReading && !expanded, selectCountry: selectCountry
    )
    .overlay(alignment: .topTrailing) {
      Button {
        expanded = true
      } label: {
        Label(tr("展开地图"), systemImage: "arrow.up.left.and.arrow.down.right")
      }
      .labelStyle(.iconOnly).buttonStyle(.bordered).controlSize(.small)
      .help(tr("展开地图")).padding(8)
    }
    .sheet(isPresented: $expanded) {
      VStack(spacing: DS.Space.s3) {
        HStack {
          Text(tr("连接地区分布")).dsFont(.lg, weight: .semibold)
          Spacer()
          Button(tr("完成")) { expanded = false }
            .keyboardShortcut(.cancelAction)
        }
        ConnectionMapSurface(
          world: world, records: records, observedRecords: observedRecords,
          countries: countries, locations: locations, providedDestinations: providedDestinations,
          isReading: isReading, interactive: true
        ) { code in
          selectCountry(code)
          expanded = false
        }
      }
      .padding(DS.Space.s4)
      .frame(minWidth: 640, idealWidth: 920, minHeight: 400, idealHeight: 560)
    }
  }
}

/// 平移限制在地图边缘；缩放围绕手势起点，避免捏合时目标跳离手指。
struct NetworkMapViewport: Equatable {
  var scale: CGFloat = 1
  var offset: CGSize = .zero

  static func mapSize(in size: CGSize) -> CGSize {
    let width = max(1, min(size.width - 16, (size.height - 16) * 2))
    return CGSize(width: width, height: width / 2)
  }

  func bounded(in size: CGSize) -> Self {
    let scale = scale.isFinite ? min(6, max(1, scale)) : 1
    let map = Self.mapSize(in: size)
    let x = max(0, (map.width * scale - size.width) / 2)
    let y = max(0, (map.height * scale - size.height) / 2)
    return Self(
      scale: scale,
      offset: CGSize(
        width: offset.width.isFinite ? min(x, max(-x, offset.width)) : 0,
        height: offset.height.isFinite ? min(y, max(-y, offset.height)) : 0))
  }

  func zoomed(by factor: CGFloat, anchor: UnitPoint = .center, in size: CGSize) -> Self {
    guard factor.isFinite, factor > 0 else { return bounded(in: size) }
    let current = bounded(in: size)
    let scale = min(6, max(1, current.scale * factor))
    let ratio = scale / current.scale
    let x = (anchor.x - 0.5) * size.width
    let y = (anchor.y - 0.5) * size.height
    return Self(
      scale: scale,
      offset: CGSize(
        width: x + (current.offset.width - x) * ratio,
        height: y + (current.offset.height - y) * ratio)
    ).bounded(in: size)
  }

  func panned(by translation: CGSize, in size: CGSize) -> Self {
    var result = bounded(in: size)
    result.offset.width += translation.width
    result.offset.height += translation.height
    return result.bounded(in: size)
  }
}

struct ConnectionMapSurface: View {
  let world: [NetworkCountry]
  let records: [ObservedConnection]
  let observedRecords: [ObservedConnection]
  let countries: [String: String]
  var locations: [String: NetworkIPLocation] = [:]
  var providedDestinations: [NetworkMapDestination]? = nil
  let isReading: Bool
  var interactive = false
  var initialViewport = NetworkMapViewport()
  let selectCountry: (String) -> Void

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var visible = false
  @State private var activity = NetworkMapActivity()
  @State private var pulseCountries: Set<String> = []
  @State private var pulseProgress: CGFloat = 0
  @State private var pulseRevision = 0
  @State private var viewport = NetworkMapViewport()
  @GestureState private var magnification: CGFloat = 1
  @GestureState private var magnifyAnchor = UnitPoint.center
  @GestureState private var translation = CGSize.zero

  private var animates: Bool { visible && isReading && !reduceMotion }
  private var pulseDuration: TimeInterval { DS.Motion.selectionDuration * 3 }

  var body: some View {
    let destinations =
      providedDestinations.map { Array($0.prefix(interactive ? 64 : 12)) }
      ?? NetworkMapDestination.make(
        world: world, records: records, countries: countries, locations: locations,
        limit: interactive ? 64 : 12)
    GeometryReader { geometry in
      let size = geometry.size
      let transform = viewport.zoomed(by: magnification, anchor: magnifyAnchor, in: size)
        .panned(by: translation, in: size)
      let baseSize = NetworkMapViewport.mapSize(in: size)
      let mapSize = CGSize(
        width: baseSize.width * transform.scale, height: baseSize.height * transform.scale)
      let origin = CGPoint(
        x: (size.width - mapSize.width) / 2 + transform.offset.width,
        y: (size.height - mapSize.height) / 2 + transform.offset.height)
      let highlightedRegions = Set(destinations.map(\.country.mapRegionCode))
      ZStack {
        Canvas { context, _ in
          for country in world {
            var path = Path()
            for ring in country.rings {
              guard let first = ring.first, first.count == 2 else { continue }
              path.move(to: point(first, size: mapSize, origin: origin))
              for coordinate in ring.dropFirst() where coordinate.count == 2 {
                path.addLine(to: point(coordinate, size: mapSize, origin: origin))
              }
              path.closeSubpath()
            }
            context.fill(
              path,
              with: .color(
                highlightedRegions.contains(country.mapRegionCode)
                  ? DS.Palette.primary.opacity(0.22) : DS.Palette.neutral300.opacity(0.65)))
            context.stroke(path, with: .color(DS.Palette.elevated.opacity(0.65)), lineWidth: 0.5)
          }
        }.accessibilityHidden(true)
        ForEach(destinations) { destination in
          let target = point(
            [
              destination.location?.longitude ?? destination.country.longitude,
              destination.location?.latitude ?? destination.country.latitude,
            ],
            size: mapSize, origin: origin)
          if pulseCountries.contains(destination.id) {
            Circle()
              .stroke(DS.Palette.primary, lineWidth: 2)
              .frame(width: 30, height: 30)
              .scaleEffect(1 + pulseProgress)
              .opacity(1 - Double(pulseProgress))
              .position(target)
              .allowsHitTesting(false).accessibilityHidden(true)
          }
          Button {
            selectCountry(destination.id)
          } label: {
            Text(verbatim: destination.count.formatted(.number.locale(L10n.locale)))
              .font(.system(size: 11, weight: .semibold)).foregroundStyle(DS.Palette.onPrimary)
              .padding(6).background(DS.Palette.primary, in: Circle())
              .overlay(Circle().stroke(DS.Palette.elevated, lineWidth: 2))
          }.buttonStyle(.plain).position(target)
            .help(networkRegionName(destination.id))
            .accessibilityLabel(networkRegionName(destination.id))
            .accessibilityValue(destination.count.formatted(.number.locale(L10n.locale)))
        }
      }
      .contentShape(Rectangle())
      .gesture(
        MagnifyGesture()
          .updating($magnification) { value, state, _ in state = value.magnification }
          .updating($magnifyAnchor) { value, state, _ in state = value.startAnchor }
          .onEnded { value in
            viewport = viewport.zoomed(
              by: value.magnification, anchor: value.startAnchor, in: size)
          }
          .exclusively(
            before: DragGesture(minimumDistance: 4)
              .updating($translation) { value, state, _ in state = value.translation }
              .onEnded { value in viewport = viewport.panned(by: value.translation, in: size) }),
        including: interactive ? .all : .subviews
      )
      .clipShape(RoundedRectangle(cornerRadius: DS.Radius.lg))
      .overlay(alignment: .topTrailing) {
        if interactive {
          HStack(spacing: DS.Space.s2) {
            Button {
              viewport = viewport.zoomed(by: 1 / 1.5, in: size)
            } label: {
              Label(tr("缩小地图"), systemImage: "minus")
            }.disabled(transform.scale <= 1).help(tr("缩小地图"))
            Text(
              Double(transform.scale).formatted(
                .percent.precision(.fractionLength(0)).locale(L10n.locale))
            )
            .dsFont(.xs).monospacedDigit()
            .frame(minWidth: 44)
            Button {
              viewport = viewport.zoomed(by: 1.5, in: size)
            } label: {
              Label(tr("放大地图"), systemImage: "plus")
            }.disabled(transform.scale >= 6).help(tr("放大地图"))
            Button {
              viewport = NetworkMapViewport()
            } label: {
              Label(tr("复位地图"), systemImage: "arrow.counterclockwise")
            }.help(tr("复位地图"))
          }
          .labelStyle(.iconOnly).buttonStyle(.bordered).controlSize(.small)
          .padding(8)
        }
      }
    }
    .background(DS.Palette.surface, in: RoundedRectangle(cornerRadius: DS.Radius.lg))
    .environment(\.layoutDirection, .leftToRight)
    .onAppear {
      viewport = initialViewport
      visible = true
    }
    .onDisappear {
      visible = false
      stopPulses()
      activity.begin(records: observedRecords, at: nil)
    }
    .onChange(of: animates, initial: true) { _, enabled in
      stopPulses()
      activity.begin(records: observedRecords, at: enabled ? Date() : nil)
    }
    .onChange(of: observedRecords) { _, _ in
      updatePulses(destinations: destinations)
    }
    .onChange(of: countries) { _, _ in
      updatePulses(destinations: destinations)
    }
    // 仅新流触发一次有界任务；没有 TimelineView、轮询或常驻动画。
    .task(id: pulseRevision) {
      guard animates, !pulseCountries.isEmpty else { return }
      withAnimation(.easeOut(duration: pulseDuration)) { pulseProgress = 1 }
      do {
        try await Task.sleep(for: .seconds(pulseDuration))
      } catch {
        return
      }
      guard !Task.isCancelled else { return }
      stopPulses()
    }
  }

  private func updatePulses(destinations: [NetworkMapDestination]) {
    let arrivals = activity.consume(records: observedRecords, countries: countries)
      .intersection(destinations.map(\.id))
    guard animates, !arrivals.isEmpty else { return }
    var transaction = Transaction()
    transaction.disablesAnimations = true
    withTransaction(transaction) {
      pulseCountries = arrivals
      pulseProgress = 0
      pulseRevision &+= 1
    }
  }

  private func stopPulses() {
    var transaction = Transaction()
    transaction.disablesAnimations = true
    withTransaction(transaction) {
      pulseCountries = []
      pulseProgress = 0
      pulseRevision &+= 1
    }
  }

  private func point(_ coordinate: [Double], size: CGSize, origin: CGPoint) -> CGPoint {
    CGPoint(
      x: origin.x + (coordinate[0] + 180) / 360 * size.width,
      y: origin.y + (90 - coordinate[1]) / 180 * size.height)
  }

}
