// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

enum ActivityPagePeriod: CaseIterable, Hashable, Sendable {
  case day, week, month

  var titleSource: String {
    switch self {
    case .day: "日"
    case .week: "周"
    case .month: "月"
    }
  }

  var component: Calendar.Component {
    switch self {
    case .day: .day
    case .week: .weekOfYear
    case .month: .month
    }
  }
}

struct ActivityPageAnalytics: Sendable {
  enum Detail: Sendable {
    case all, none
    case app(String)

    func includes(_ id: String) -> Bool {
      switch self {
      case .all: true
      case .none: false
      case .app(let selected): id == selected
      }
    }
  }

  enum Category: String, CaseIterable, Sendable {
    case work, browsing, communication, entertainment, other
  }

  struct Segment: Identifiable, Sendable {
    struct ID: Hashable, Sendable {
      let sessionID: UUID
      let start: Date
    }

    let sessionID: UUID
    let deviceID: UUID
    let start: Date
    let end: Date
    let category: Category

    var id: ID { ID(sessionID: sessionID, start: start) }
    var seconds: TimeInterval { end.timeIntervalSince(start) }
  }

  struct App: Identifiable, Sendable {
    let id: String
    let name: String
    let category: Category
    let seconds: TimeInterval
    let segments: [Segment]
  }

  struct CategoryTotal: Identifiable, Sendable {
    let id: Category
    let seconds: TimeInterval
    let breakdown: [ActivityClassification: TimeInterval]
  }

  struct Bucket: Identifiable, Sendable {
    let interval: DateInterval
    fileprivate(set) var secondsByCategory: [Category: TimeInterval] = [:]
    var id: Date { interval.start }
    var seconds: TimeInterval { secondsByCategory.values.reduce(0, +) }
  }

  struct Lane: Identifiable, Sendable {
    let id: UUID
    let segments: [Segment]
  }

  let seconds: TimeInterval
  let days: [Bucket]
  let hours: [Bucket]
  let lanes: [Lane]
  let apps: [App]
  let categories: [CategoryTotal]
  let deviceIDs: Set<UUID>

  static func make(
    sessions: [ActivitySession], interval: DateInterval, period: ActivityPagePeriod,
    calendar: Calendar, deviceID: UUID?, through now: Date? = nil, detail: Detail = .all,
    classificationOverrides: [String: String] = [:]
  ) throws -> Self {
    var days: [Bucket] = []
    var dayIndices: [Date: Int] = [:]
    var cursor = interval.start
    while cursor < interval.end, let day = calendar.dateInterval(of: .day, for: cursor),
      day.end > cursor
    {
      dayIndices[day.start] = days.count
      let end = min(day.end, interval.end)
      days.append(Bucket(interval: DateInterval(start: cursor, end: end)))
      cursor = end
    }

    var hours: [Bucket] = []
    if period == .day {
      cursor = interval.start
      while cursor < interval.end {
        let end = min(interval.end, cursor.addingTimeInterval(3_600))
        hours.append(Bucket(interval: DateInterval(start: cursor, end: end)))
        cursor = end
      }
    }

    var seconds: TimeInterval = 0
    var breakdown: [Category: [ActivityClassification: TimeInterval]] = [:]
    var apps: [String: AppAccumulator] = [:]
    var deviceIDs: Set<UUID> = []

    let end = min(interval.end, max(interval.start, now ?? interval.end))
    let observed = DateInterval(start: interval.start, end: end)
    let foreground = try foregroundSessions(sessions, interval: observed, deviceID: deviceID)
    for session in foreground {
      try Task.checkCancellation()
      let start = session.start
      let end = session.end
      guard let firstDay = dayIndices[calendar.startOfDay(for: start)] else { continue }
      // 在查询时应用现行规则，让本机和远端的历史记录获得相同的归类。
      let classification =
        ActivityClassification.custom(appID: session.appID, overrides: classificationOverrides)
        ?? ActivityClassification.knownApplication(session.appID)
        ?? session.subcategory.flatMap(ActivityClassification.init(rawValue:))
        ?? ActivityClassification(rawValue: session.category) ?? .other
      let category = classification.category
      let segment = Segment(
        sessionID: session.id, deviceID: session.deviceID, start: start, end: end,
        category: category)

      // 不同设备分别计时。总计、排行和日柱都使用解析后的前台片段。
      seconds += segment.seconds
      breakdown[category, default: [:]][classification, default: 0] += segment.seconds
      deviceIDs.insert(session.deviceID)
      apps[session.appID, default: AppAccumulator()].append(
        segment, name: session.appName, keepSegment: detail.includes(session.appID))
      for index in firstDay..<days.count {
        let day = days[index].interval
        let overlap = min(end, day.end).timeIntervalSince(max(start, day.start))
        days[index].secondsByCategory[category, default: 0] += overlap
        if day.end >= end { break }
      }
      if !hours.isEmpty {
        let firstHour = Int(start.timeIntervalSince(interval.start) / 3_600)
        for index in firstHour..<hours.count {
          let hour = hours[index].interval
          let overlap = min(end, hour.end).timeIntervalSince(max(start, hour.start))
          hours[index].secondsByCategory[category, default: 0] += overlap
          if hour.end >= end { break }
        }
      }
    }

    var lanes: [UUID: [Segment]] = [:]
    var rankedApps: [App] = []
    rankedApps.reserveCapacity(apps.count)
    for (id, app) in apps {
      try Task.checkCancellation()
      var segments: [Segment] = app.segments
      try segments.sort { lhs, rhs in
        try Task.checkCancellation()
        if lhs.start == rhs.start {
          return lhs.sessionID.uuidString < rhs.sessionID.uuidString
        }
        return lhs.start < rhs.start
      }
      // 每台设备单独合并首尾相接的检查点，保留空档和分类变化。
      var merged: [Segment] = []
      var latestByDevice: [UUID: Int] = [:]
      for segment in segments {
        try Task.checkCancellation()
        if let index = latestByDevice[segment.deviceID],
          merged[index].end == segment.start, merged[index].category == segment.category
        {
          let previous = merged[index]
          merged[index] = Segment(
            sessionID: previous.sessionID, deviceID: previous.deviceID, start: previous.start,
            end: segment.end, category: previous.category)
        } else {
          latestByDevice[segment.deviceID] = merged.count
          merged.append(segment)
        }
      }
      if period == .day {
        for segment in merged { lanes[segment.deviceID, default: []].append(segment) }
      }

      merged.reverse()
      let rankedApp = App(
        id: id, name: app.name, category: app.category, seconds: app.seconds, segments: merged)
      rankedApps.append(rankedApp)
    }
    var dayLanes: [Lane] = lanes.map { id, segments in
      Lane(id: id, segments: segments)
    }
    dayLanes.sort { lhs, rhs in lhs.id.uuidString < rhs.id.uuidString }
    try Task.checkCancellation()
    return Self(
      seconds: seconds, days: days, hours: hours, lanes: dayLanes,
      apps: rankedApps.sorted(by: appRank),
      categories: categoryTotals(breakdown), deviceIDs: deviceIDs)
  }

  static func combineDailySummaries(_ reports: [Self]) throws -> Self {
    var seconds: TimeInterval = 0
    var days: [Bucket] = []
    var apps: [String: App] = [:]
    var breakdown: [Category: [ActivityClassification: TimeInterval]] = [:]
    var devices = Set<UUID>()
    for report in reports {
      try Task.checkCancellation()
      seconds += report.seconds
      days += report.days
      devices.formUnion(report.deviceIDs)
      for app in report.apps {
        try Task.checkCancellation()
        apps[app.id] = App(
          id: app.id, name: app.name, category: app.category,
          seconds: app.seconds + (apps[app.id]?.seconds ?? 0), segments: [])
      }
      for category in report.categories {
        breakdown[category.id, default: [:]].merge(category.breakdown, uniquingKeysWith: +)
      }
    }
    return Self(
      seconds: seconds, days: days, hours: [], lanes: [], apps: apps.values.sorted(by: appRank),
      categories: categoryTotals(breakdown), deviceIDs: devices)
  }

  static func summarizeDays(
    _ intervals: [DateInterval], sessions: [ActivitySession], period: ActivityPagePeriod,
    calendar: Calendar, deviceID: UUID?, through now: Date,
    classificationOverrides: [String: String] = [:]
  ) throws -> [Self] {
    let indices = Dictionary(
      uniqueKeysWithValues: intervals.enumerated().map {
        (calendar.startOfDay(for: $0.element.start), $0.offset)
      })
    var partitioned = Array(repeating: [ActivitySession](), count: intervals.count)
    guard let first = intervals.first else { return [] }
    for session in sessions {
      try Task.checkCancellation()
      let start = max(first.start, session.start)
      guard var index = indices[calendar.startOfDay(for: start)] else { continue }
      while index < intervals.count, intervals[index].start < session.end {
        partitioned[index].append(session)
        index += 1
      }
    }
    return try intervals.indices.map { index in
      try make(
        sessions: partitioned[index], interval: intervals[index], period: period,
        calendar: calendar, deviceID: deviceID, through: now, detail: .none,
        classificationOverrides: classificationOverrides)
    }
  }

  private static func appRank(_ lhs: App, _ rhs: App) -> Bool {
    lhs.seconds == rhs.seconds ? lhs.id < rhs.id : lhs.seconds > rhs.seconds
  }

  private static func categoryTotals(
    _ breakdown: [Category: [ActivityClassification: TimeInterval]]
  ) -> [CategoryTotal] {
    breakdown.map { id, details in
      CategoryTotal(id: id, seconds: details.values.reduce(0, +), breakdown: details)
    }.sorted { lhs, rhs in
      lhs.seconds == rhs.seconds ? lhs.id.rawValue < rhs.id.rawValue : lhs.seconds > rhs.seconds
    }
  }

  private static func foregroundSessions(
    _ sessions: [ActivitySession], interval: DateInterval, deviceID: UUID?
  ) throws -> [ActivitySession] {
    var sessionsByDevice: [UUID: [ActivitySession]] = [:]
    for session in sessions {
      try Task.checkCancellation()
      guard deviceID == nil || session.deviceID == deviceID,
        session.start < session.end, session.start < interval.end, session.end > interval.start
      else { continue }
      sessionsByDevice[session.deviceID, default: []].append(session)
    }

    var foreground: [ActivitySession] = []
    foreground.reserveCapacity(sessions.count)
    for var ordered in sessionsByDevice.values {
      try Task.checkCancellation()
      // 排序使用原始起点，避免跨越所选区间边界的记录裁剪后变成同优先级。
      try ordered.sort { lhs, rhs in
        try Task.checkCancellation()
        if lhs.start == rhs.start {
          return lhs.id.uuidString > rhs.id.uuidString
        }
        return lhs.start < rhs.start
      }

      var active: [ActivitySession] = []
      var nextIndex = 0
      var cursor = interval.start
      while cursor < interval.end, nextIndex < ordered.count || !active.isEmpty {
        try Task.checkCancellation()
        while let latest = active.last, latest.end <= cursor {
          try Task.checkCancellation()
          active.removeLast()
        }
        if active.isEmpty, nextIndex < ordered.count {
          cursor = max(cursor, ordered[nextIndex].start)
        }
        // 按起点压栈，栈顶为最近进入前台的记录。同一时刻由较小的 UUID 决胜。
        while nextIndex < ordered.count, ordered[nextIndex].start <= cursor {
          try Task.checkCancellation()
          let next = ordered[nextIndex]
          if next.end > cursor { active.append(next) }
          nextIndex += 1
        }
        guard let latest = active.last else { continue }
        var end = min(latest.end, interval.end)
        if nextIndex < ordered.count {
          end = min(end, ordered[nextIndex].start)
        }
        foreground.append(
          ActivitySession(
            id: latest.id, deviceID: latest.deviceID, appID: latest.appID, appName: latest.appName,
            category: latest.category, start: cursor, end: end, subcategory: latest.subcategory))
        cursor = end
      }
    }
    return foreground
  }

  private struct AppAccumulator {
    private(set) var seconds: TimeInterval = 0
    private(set) var segments: [Segment] = []
    private(set) var name = ""
    private(set) var category = Category.other
    private var latest: Segment?

    mutating func append(_ segment: Segment, name: String, keepSegment: Bool) {
      if let latest {
        if segment.end > latest.end
          || (segment.end == latest.end
            && segment.sessionID.uuidString < latest.sessionID.uuidString)
        {
          updateMetadata(segment, name: name)
        }
      } else {
        updateMetadata(segment, name: name)
      }
      seconds += segment.seconds
      if keepSegment { segments.append(segment) }
    }

    private mutating func updateMetadata(_ segment: Segment, name: String) {
      latest = segment
      self.name = name
      category = segment.category
    }
  }
}
