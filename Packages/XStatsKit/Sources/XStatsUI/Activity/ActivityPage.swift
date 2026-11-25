// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import Combine
import Localization
import OSLog
import SwiftUI

struct ActivityPage: View {
  @Environment(AppModel.self) private var model
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var dateSelection = ActivityPageDateSelection()
  @State private var animatePeriodChange = false
  @State private var device = Device.all
  @State private var storedDeviceIDs: [UUID] = []
  @State private var storedDeviceNames: [UUID: String] = [:]
  @State private var refresh = 0
  @State private var loaded: Loaded?
  @State private var failedRequest: Request?
  @State private var selectedApp: ActivityPageAnalytics.App?

  private static let logger = Logger(subsystem: Log.subsystem, category: "activity-page")
  private static let syncFinished = Notification.Name("XStatsActivitySyncFinished")

  private var period: ActivityPagePeriod { dateSelection.period }

  private var namesForDisplay: [UUID: String] {
    var deviceNames = storedDeviceNames
    if let name = model.activity.deviceName { deviceNames[model.activity.deviceID] = name }
    return deviceNames
  }

  var body: some View {
    let controller = model.activity
    let localID = controller.deviceID
    let deviceNames = namesForDisplay
    let locale = L10n.locale
    let calendar = {
      var calendar = Calendar.current
      calendar.locale = locale
      calendar.firstWeekday = model.settings.calendarFirstWeekday
      return calendar
    }()
    let now = Date.now
    let current = calendar.dateInterval(of: period.component, for: now)
    let interval = calendar.dateInterval(of: period.component, for: dateSelection.date ?? now)
    let selection = interval.map { Selection(interval: $0, period: period, device: device) }
    let includesLocal = device == .all || device == .local
    let isCurrent = interval != nil && interval == current
    let tracksLocalChanges = includesLocal && isCurrent
    let isVisible = model.isMainWindowVisible
    let liveDay =
      isVisible && tracksLocalChanges && period == .day && controller.enabled
        && selectedApp == nil ? interval : nil
    let request = selection.map {
      Request(
        selection: $0, localID: localID, enabled: controller.enabled,
        revision: tracksLocalChanges ? controller.revision : 0,
        refresh: refresh)
    }
    let visibleRequest = isVisible ? request : nil
    let report = loaded?.selection == selection ? loaded?.report : nil
    let remoteIDs = storedDeviceIDs.filter { $0 != localID }

    ScrollView {
      LazyVStack(alignment: .leading, spacing: DS.Space.s4) {
        header(localID: localID, remoteIDs: remoteIDs, names: deviceNames)
        if controller.writeFailed {
          Label {
            Text(tr("录制写入失败，请检查可用磁盘空间。"))
          } icon: {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
          }
        }
        if let interval, let current {
          if let report, controller.enabled || !report.apps.isEmpty {
            ActivityPageTimeline(
              report: report, interval: interval, period: period, calendar: calendar,
              locale: locale, combinesDevices: device == .all && !remoteIDs.isEmpty,
              now: now, animateEntry: animatePeriodChange,
              deviceNames: deviceNames, localID: localID,
              openDay: {
                animatePeriodChange = false
                dateSelection.openDay($0, from: interval.start)
              }
            ) {
              dateNavigation(
                interval: interval, current: current, calendar: calendar, locale: locale)
            }
            .id(selection)
            if report.apps.isEmpty {
              Label(tr("此时段无活动记录"), systemImage: "clock")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding()
            } else {
              ActivityPageRankings(report: report, locale: locale) { selectedApp = $0 }
                .id(selection)
            }
          } else {
            dateNavigation(interval: interval, current: current, calendar: calendar, locale: locale)
            if !controller.enabled {
              Card {
                Label(tr("应用活动记录已关闭"), systemImage: "clock")
                  .font(.headline)
              }
            }
          }
        }
        if let visibleRequest, failedRequest == visibleRequest {
          HStack {
            Label(tr("无法读取活动记录"), systemImage: "exclamationmark.circle")
            Spacer()
            Button(tr("重试")) { refresh += 1 }
          }
          .foregroundStyle(.secondary)
        } else if report == nil, visibleRequest != nil {
          ProgressView().controlSize(.small)
            .accessibilityLabel(tr("正在读取活动记录"))
            .frame(maxWidth: .infinity)
            .padding()
        }
      }
      .padding(.horizontal, DS.Space.s4)
      .padding(.vertical, DS.Space.s3)
      .overlayScrollers()
    }
    .scrollBounceBehavior(.basedOnSize)
    .task(id: visibleRequest) {
      if let visibleRequest {
        await load(visibleRequest, controller: controller, calendar: calendar)
      }
    }
    .task(id: liveDay) {
      guard let liveDay else { return }
      while !Task.isCancelled {
        do {
          try await Task.sleep(for: .seconds(60), tolerance: .seconds(5))
        } catch { return }
        guard !Task.isCancelled, model.isMainWindowVisible, controller.enabled,
          Date.now < liveDay.end
        else { return }
        refresh += 1
      }
    }
    .onReceive(
      Publishers.Merge3(
        NotificationCenter.default.publisher(for: Self.syncFinished),
        NotificationCenter.default.publisher(for: .NSCalendarDayChanged),
        NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)
      ).receive(on: RunLoop.main)
    ) { _ in
      if model.isMainWindowVisible { refresh += 1 }
    }
    .sheet(item: $selectedApp) { app in
      ActivityPageSegments(
        app: app, localID: localID, deviceNames: deviceNames,
        showsDevice: device == .all && !remoteIDs.isEmpty,
        locale: locale)
    }
    .onChange(of: device) { _, _ in animatePeriodChange = false }
  }

  private func header(localID: UUID, remoteIDs: [UUID], names: [UUID: String]) -> some View {
    let devices = Picker(tr("设备"), selection: $device) {
      Text(tr("所有设备")).tag(Device.all)
      Text(verbatim: ActivityPageFormat.deviceName(localID, localID: localID, names: names))
        .tag(Device.local)
      ForEach(remoteIDs, id: \.self) { id in
        Text(verbatim: ActivityPageFormat.deviceName(id, localID: localID, names: names))
          .tag(Device.remote(id))
      }
    }
    .pickerStyle(.menu)
    .labelsHidden()
    .lineLimit(1)
    let periods = Picker(
      tr("统计周期"),
      selection: Binding(
        get: { period },
        set: { newPeriod in
          let event = NSApp?.currentEvent?.type
          animatePeriodChange = !reduceMotion && (event == .leftMouseDown || event == .leftMouseUp)
          DS.Motion.select { dateSelection.selectPeriod(newPeriod) }
        })
    ) {
      Text(tr("日")).tag(ActivityPagePeriod.day)
      Text(tr("周")).tag(ActivityPagePeriod.week)
      Text(tr("月")).tag(ActivityPagePeriod.month)
    }
    .pickerStyle(.segmented)
    .labelsHidden()
    .fixedSize()

    return ViewThatFits(in: .horizontal) {
      HStack(spacing: DS.Space.s3) {
        Spacer(minLength: 0)
        periods
        devices
      }
      VStack(alignment: .leading, spacing: DS.Space.s2) {
        periods
        devices
      }
    }
  }

  private func dateNavigation(
    interval: DateInterval, current: DateInterval, calendar: Calendar, locale: Locale
  ) -> some View {
    let canAdvance = interval.start < current.start
    let previous = calendar.date(byAdding: period.component, value: -1, to: interval.start)
    let next = calendar.date(byAdding: period.component, value: 1, to: interval.start)
    let title = ActivityPageFormat.dateTitle(
      interval, period: period, calendar: calendar, locale: locale)
    let backLabel = dateSelection.overview?.period == .month ? tr("返回月视图") : tr("返回周视图")
    let todayLabel =
      switch period {
      case .day: tr("今天")
      case .week: tr("本周")
      case .month: tr("本月")
      }
    let date = VStack(alignment: .leading, spacing: DS.Space.s1) {
      if dateSelection.overview != nil {
        Button {
          animatePeriodChange = false
          dateSelection.returnToOverview()
        } label: {
          Label(backLabel, systemImage: "chevron.backward")
        }
        .buttonStyle(.link)
      }
      Text(title)
        .font(.headline)
    }
    let controls = HStack(spacing: DS.Space.s2) {
      IconButton(systemName: "chevron.backward", help: tr("上一时段")) {
        animatePeriodChange = false
        if let previous { dateSelection.date = previous }
      }
      .disabled(previous == nil)
      Button(todayLabel) {
        animatePeriodChange = false
        dateSelection.date = nil
      }
      .disabled(interval == current)
      IconButton(systemName: "chevron.forward", help: tr("下一时段")) {
        animatePeriodChange = false
        if let next, canAdvance { dateSelection.date = next < current.start ? next : nil }
      }
      .disabled(!canAdvance || next == nil)
    }
    return ViewThatFits(in: .horizontal) {
      HStack(alignment: .top, spacing: DS.Space.s3) {
        date.fixedSize(horizontal: true, vertical: false)
        Spacer(minLength: 0)
        controls.fixedSize()
      }
      VStack(alignment: .leading, spacing: DS.Space.s2) {
        date
        controls
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  @MainActor
  private func load(_ request: Request, controller: ActivityController, calendar: Calendar) async {
    guard !Task.isCancelled, model.isMainWindowVisible else { return }
    do {
      let selection = request.selection
      let deviceID = selection.device.id(localID: request.localID)
      let sessions = try await controller.sessions(in: selection.interval, deviceID: deviceID)
      try Task.checkCancellation()
      let knownIDs = try? await controller.store.deviceIDs()
      let names = try await controller.store.deviceNames()
      try Task.checkCancellation()
      let now = Date.now
      let worker = Task.detached(priority: .userInitiated) {
        let report = try ActivityPageAnalytics.make(
          sessions: sessions, interval: selection.interval, period: selection.period,
          calendar: calendar, deviceID: deviceID, through: now)
        return (report, Set(knownIDs ?? []).union(report.deviceIDs))
      }
      let (report, ids) = try await withTaskCancellationHandler {
        try await worker.value
      } onCancel: {
        worker.cancel()
      }
      try Task.checkCancellation()
      guard model.isMainWindowVisible else { return }
      storedDeviceIDs = (knownIDs == nil ? ids.union(storedDeviceIDs) : ids)
        .sorted { $0.uuidString < $1.uuidString }
      storedDeviceNames = names
      loaded = Loaded(selection: selection, report: report)
      failedRequest = nil
    } catch {
      guard !Task.isCancelled, model.isMainWindowVisible else { return }
      if failedRequest == nil { Self.logger.error("读取应用活动失败") }
      failedRequest = request
    }
  }

  private enum Device: Hashable, Sendable {
    case all
    case local
    case remote(UUID)

    func id(localID: UUID) -> UUID? {
      switch self {
      case .all: nil
      case .local: localID
      case .remote(let id): id
      }
    }
  }

  private struct Selection: Hashable, Sendable {
    let interval: DateInterval
    let period: ActivityPagePeriod
    let device: Device
  }

  private struct Request: Equatable {
    let selection: Selection
    let localID: UUID
    let enabled: Bool
    let revision: Int
    let refresh: Int
  }

  private struct Loaded {
    let selection: Selection
    let report: ActivityPageAnalytics
  }
}

struct ActivityPageDateSelection {
  private(set) var period: ActivityPagePeriod = .day
  var date: Date?
  private(set) var overview: (period: ActivityPagePeriod, date: Date?)?

  mutating func selectPeriod(_ period: ActivityPagePeriod) {
    guard period != self.period else { return }
    if overview?.period == period {
      returnToOverview()
    } else {
      overview = nil
      self.period = period
    }
  }

  mutating func openDay(_ day: Date, from intervalStart: Date) {
    guard period != .day else { return }
    overview = (period, intervalStart)
    period = .day
    date = day
  }

  mutating func returnToOverview() {
    guard let overview else { return }
    period = overview.period
    date = overview.date
    self.overview = nil
  }
}
