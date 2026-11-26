// SPDX-License-Identifier: AGPL-3.0-or-later
import AppKit
import CryptoKit
import Observation
import OSLog
import SystemConfiguration

struct ActivityApplication: Equatable {
  let id: String
  let name: String
  let classification: ActivityClassification
}

struct ActivityClock {
  static let idleLimit: TimeInterval = 5 * 60
  private(set) var current: ActivitySession?
  private var wasIdle = false
  private var startUptime: TimeInterval = 0

  func endDate(at now: Date, uptime: TimeInterval) -> Date {
    guard let current else { return now }
    let elapsed = current.start.addingTimeInterval(max(0, uptime - startUptime))
    return abs(now.timeIntervalSince(elapsed)) > 2 ? elapsed : now
  }

  mutating func observe(
    _ app: ActivityApplication?, at now: Date, idle: TimeInterval, deviceID: UUID,
    checkpoint: Bool = false, uptime: TimeInterval
  ) -> ActivitySession? {
    let idle = idle.isFinite ? max(0, idle) : Self.idleLimit
    let inactive = idle >= Self.idleLimit
    let measured = endDate(at: now, uptime: uptime)
    let end = inactive ? measured.addingTimeInterval(Self.idleLimit - idle) : measured
    let previous = current
    let changed = app?.id != previous?.appID
    guard changed || inactive || checkpoint || previous == nil || measured != now else {
      return nil
    }
    current = nil
    if let app, !inactive {
      let start = wasIdle ? now.addingTimeInterval(-idle) : now
      startUptime = uptime - now.timeIntervalSince(start)
      current = ActivitySession(
        id: UUID(), deviceID: deviceID, appID: app.id, appName: app.name,
        category: app.classification.category.rawValue, start: start, end: start,
        subcategory: app.classification.rawValue == app.classification.category.rawValue
          ? nil : app.classification.rawValue)
    }
    wasIdle = inactive
    guard let previous, end > previous.start else { return nil }
    return Self.ending(previous, at: end)
  }

  static func ending(_ session: ActivitySession, at end: Date) -> ActivitySession {
    var closed = session
    closed.end = end
    return closed
  }
}

@MainActor @Observable
final class ActivityController {
  private static let logger = Logger(subsystem: "work.12306.xstats", category: "AppActivity")
  let store: ActivityStore
  let deviceID: UUID
  let deviceName: String?
  let sync: ActivitySyncController
  private(set) var enabled: Bool
  @ObservationIgnored var onEnabledChanged: ((Bool) -> Void)?
  private(set) var revision = 0
  @ObservationIgnored private let sessionAvailable: () -> Bool
  @ObservationIgnored private var started = false
  @ObservationIgnored private var paused = false
  @ObservationIgnored private var externallyPaused = false
  @ObservationIgnored private var sessionRetry: Task<Void, Never>?
  @ObservationIgnored private(set) var screenObserver: NSObjectProtocol?
  @ObservationIgnored private var observer: NSObjectProtocol?
  @ObservationIgnored private var timer: Timer?
  @ObservationIgnored private var clock = ActivityClock()
  @ObservationIgnored private var application: ActivityApplication?
  @ObservationIgnored private var recentApplications: [String: ActivityApplication] = [:]
  @ObservationIgnored private var pending: [ActivitySession] = []
  @ObservationIgnored private var writer: Task<Void, Never>?
  private(set) var writeFailed = false

  init(
    defaults: UserDefaults, databaseURL: URL?, deviceName: String? = nil, enabled: Bool = false,
    settings: AppSettings? = nil,
    sessionAvailable: @escaping () -> Bool = {
      guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
      return session["CGSSessionScreenIsLocked"] as? Bool != true
        && session["kCGSSessionOnConsoleKey"] as? Bool == true
        && CGDisplayIsAsleep(CGMainDisplayID()) == 0
    }
  ) {
    self.deviceName = deviceName
    self.sessionAvailable = sessionAvailable
    self.enabled = enabled
    if let existing = defaults.string(forKey: "activity.deviceID").flatMap(UUID.init(uuidString:)) {
      deviceID = existing
    } else {
      deviceID = UUID()
      defaults.set(deviceID.uuidString, forKey: "activity.deviceID")
    }
    let retention: @MainActor @Sendable () -> ActivityRetention = { [weak settings] in
      settings?.activityRetention ?? .forever
    }
    if defaults === UserDefaults.standard {
      store = ActivityStore(url: databaseURL, retention: retention)
    } else {
      let isolatedKey = SymmetricKey(size: .bits256)
      store = ActivityStore(url: databaseURL, retention: retention, keyProvider: { isolatedKey })
    }
    sync = ActivitySyncController(
      store: store, deviceID: deviceID, defaults: defaults,
      settings: settings, deviceName: deviceName)
  }

  isolated deinit {
    sessionRetry?.cancel()
    removeScreenObserver()
    if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    timer?.invalidate()
  }

  var isSampling: Bool { observer != nil && timer?.isValid == true }
  var earliestUncommittedStart: Date? {
    let pendingStart = pending.lazy.map(\.start).min()
    if let current = clock.current, let pendingStart { return min(current.start, pendingStart) }
    return pendingStart ?? clock.current?.start
  }

  func start() {
    started = true
    reconcileSession()
  }

  func setEnabled(_ value: Bool) {
    guard enabled != value else { return }
    enabled = value
    onEnabledChanged?(value)
    if value { reconcileSession() } else { reconcile() }
  }

  func setPaused(_ value: Bool) {
    externallyPaused = value
    reconcileSession()
  }

  @discardableResult func stop() async -> Bool {
    started = false
    reconcileSession()
    await writer?.value
    if !pending.isEmpty {
      try? await Task.sleep(for: .milliseconds(250))
      enqueue(nil)
      await writer?.value
    }
    return pending.isEmpty
  }

  private func reconcileSession() {
    sessionRetry?.cancel()
    sessionRetry = nil
    paused = externallyPaused || (started && !sessionAvailable())
    reconcile()
    guard started, !externallyPaused, paused else {
      removeScreenObserver()
      return
    }
    if screenObserver == nil {
      screenObserver = NotificationCenter.default.addObserver(
        forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
      ) { [weak self] _ in MainActor.assumeIsolated { self?.reconcileSession() } }
    }
    // 解锁通知可能先于 WindowServer 更新。有界复检同时恢复录制与独立的同步会话。
    sessionRetry = Task { [weak self] in
      for delay in [100, 200, 400, 800, 1_600, 3_200, 6_400] {
        do { try await Task.sleep(for: .milliseconds(delay)) } catch { return }
        guard !Task.isCancelled, let self else { return }
        if self.sessionAvailable() {
          self.sessionRetry = nil
          self.paused = false
          self.removeScreenObserver()
          self.reconcile()
          return
        }
      }
      self?.sessionRetry = nil
    }
  }

  private func removeScreenObserver() {
    guard let screenObserver else { return }
    NotificationCenter.default.removeObserver(screenObserver)
    self.screenObserver = nil
  }

  private func reconcile() {
    let active = started && enabled && !paused
    if !active { recentApplications.removeAll(keepingCapacity: true) }
    sync.setSession(available: started && !paused, recordsActivity: enabled)
    if active && !isSampling {
      observer = NSWorkspace.shared.notificationCenter.addObserver(
        forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
      ) { [weak self] _ in MainActor.assumeIsolated { self?.sample() } }
      let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
        MainActor.assumeIsolated { self?.sample() }
      }
      timer.tolerance = 5
      RunLoop.main.add(timer, forMode: .common)
      self.timer = timer
      sample()
      Self.logger.info("Activity recording started")
    } else if !active, let observer {
      NSWorkspace.shared.notificationCenter.removeObserver(observer)
      self.observer = nil
      timer?.invalidate()
      timer = nil
      enqueue(
        clock.observe(
          nil, at: Date(), idle: idleSeconds, deviceID: deviceID,
          uptime: ProcessInfo.processInfo.systemUptime))
      clock = ActivityClock()
      application = nil
      Self.logger.info("Activity recording stopped")
    }
  }

  private var idleSeconds: TimeInterval {
    CGEventSource.secondsSinceLastEventType(
      .combinedSessionState, eventType: .init(rawValue: UInt32.max)!)
  }

  private func sample() {
    guard observer != nil else { return }
    let front = NSWorkspace.shared.frontmostApplication
    if let front, front.activationPolicy == .regular, let id = front.bundleIdentifier,
      !id.isEmpty, id.utf8.count <= 1024, !id.utf8.contains(0), id != "com.apple.loginwindow"
    {
      if let cached = recentApplications[id] {
        application = cached
      } else {
        let category =
          front.bundleURL.flatMap(Bundle.init(url:))?
          .object(forInfoDictionaryKey: "LSApplicationCategoryType") as? String
        let name = front.localizedName.flatMap { candidate in
          !candidate.isEmpty && candidate.utf8.count <= 1024 && !candidate.utf8.contains(0)
            ? candidate : nil
        }
        let observed = ActivityApplication(
          id: id, name: name ?? id,
          classification: .automatic(appID: id, storeCategory: category))
        if recentApplications.count >= 64 { recentApplications.removeAll(keepingCapacity: true) }
        recentApplications[id] = observed
        application = observed
      }
    } else {
      application = nil
    }
    let now = Date()
    let checkpoint = clock.current.map { now.timeIntervalSince($0.start) >= 300 } ?? false
    enqueue(
      clock.observe(
        application, at: now, idle: idleSeconds, deviceID: deviceID, checkpoint: checkpoint,
        uptime: ProcessInfo.processInfo.systemUptime))
  }

  func enqueue(_ closed: ActivitySession?) {
    if var closed {
      if closed.deviceID == deviceID { closed.deviceName = deviceName }
      pending.append(closed)
      revision &+= 1
    }
    guard writer == nil, !pending.isEmpty else { return }
    writer = Task {
      defer { writer = nil }
      if isSampling, pending.count < 256 {
        try? await Task.sleep(for: .milliseconds(500), tolerance: .milliseconds(100))
      }
      while !pending.isEmpty {
        let batch = Array(pending.prefix(256))
        do {
          try await store.insert(batch)
          pending.removeFirst(batch.count)
          writeFailed = false
        } catch {
          if !writeFailed { Self.logger.error("Activity database write failed") }
          writeFailed = true
          if pending.count >= 1024 { setEnabled(false) }
          return
        }
      }
    }
  }

  static func localDeviceName(model: String) -> String? {
    let host = (SCDynamicStoreCopyLocalHostName(nil) as String?) ?? ProcessInfo.processInfo.hostName
    let family = model.prefix { $0 != "(" }.trimmingCharacters(in: .whitespacesAndNewlines)
    let name = family.isEmpty ? host : "\(host) (\(family))"
    guard !host.isEmpty, name.utf8.count <= 1024,
      name.rangeOfCharacter(from: .controlCharacters) == nil
    else { return nil }
    return name
  }

  func sessions(in interval: DateInterval, deviceID selected: UUID? = nil) async throws
    -> [ActivitySession]
  {
    if let selected, selected != deviceID {
      return try await store.sessions(in: interval, deviceID: selected)
    }
    let now = Date()
    let idle = observer == nil ? 0 : idleSeconds
    var recent = pending
    if let current = clock.current {
      recent.append(
        ActivityClock.ending(
          current,
          at: clock.endDate(at: now, uptime: ProcessInfo.processInfo.systemUptime)
            .addingTimeInterval(-max(0, idle - ActivityClock.idleLimit))))
    }
    return try await store.sessions(in: interval, deviceID: selected, including: recent)
  }
}
