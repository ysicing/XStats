// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import Darwin
import OSLog

struct LaunchpadPinch: Sendable {
  struct Contact: Sendable {
    let id: Int32
    let x: Double
    let y: Double
  }
  enum Event: Equatable, Sendable {
    case progress(Double)
    case end(Bool)
  }
  var fingers = 4
  private var identifiers: Set<Int32> = []
  private var initialRadius = 0.0
  private var progress = 0.0
  private var active = false
  private var blocked = false

  mutating func cancel() -> Event? {
    let event: Event? = active ? .end(false) : nil
    self = Self(fingers: fingers)
    return event
  }

  mutating func update(_ contacts: [Contact]) -> Event? {
    guard contacts.count == fingers,
      contacts.allSatisfy({
        $0.x.isFinite && $0.y.isFinite && (0...1).contains($0.x) && (0...1).contains($0.y)
      }),
      Set(contacts.map(\.id)).count == fingers
    else {
      let validRelease =
        contacts.count < fingers
        && contacts.allSatisfy {
          $0.x.isFinite && $0.y.isFinite
        }
      let result: Event? = active ? .end(validRelease && progress >= 0.65) : nil
      self = Self(fingers: fingers)
      return result
    }
    let ids = Set(contacts.map(\.id))
    if !identifiers.isEmpty && ids != identifiers {
      let result: Event? = active ? .end(false) : nil
      active = false
      blocked = true
      return result
    }
    guard !blocked else { return nil }
    let centerX = contacts.reduce(0) { $0 + $1.x } / Double(fingers)
    let centerY = contacts.reduce(0) { $0 + $1.y } / Double(fingers)
    let radius = sqrt(
      contacts.reduce(0) {
        $0 + pow($1.x - centerX, 2) + pow($1.y - centerY, 2)
      } / Double(fingers))
    if identifiers.isEmpty {
      identifiers = ids
      initialRadius = radius
      return nil
    }
    guard initialRadius >= 0.04 else { return nil }
    let contraction = 1 - radius / initialRadius
    guard active || contraction >= 0.06 else { return nil }
    active = true
    progress = min(1, max(0, contraction / 0.4))
    return .progress(progress)
  }
}

private typealias LaunchpadTouchCallback =
  @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, Int32, Double, Int32) -> Int32

/// 框架回调运行在任意线程；识别状态与待交付事件只在锁内访问，主线程队列最多挂一个交付任务。
private final class LaunchpadTouchBridge: @unchecked Sendable {
  static let shared = LaunchpadTouchBridge()
  private let lock = NSLock()
  private var recognizer = LaunchpadPinch()
  private var device: UInt = 0
  private var generation = UUID()
  private var callback: (@MainActor @Sendable (LaunchpadPinch.Event) -> Void)?
  private var pending: [LaunchpadPinch.Event] = []
  private var scheduled = false

  func configure(fingers: Int, callback: (@MainActor @Sendable (LaunchpadPinch.Event) -> Void)?) {
    lock.withLock {
      generation = UUID()
      recognizer = LaunchpadPinch(fingers: fingers)
      device = 0
      self.callback = callback
      pending = []
      scheduled = false
    }
  }

  func receive(
    device pointer: UnsafeMutableRawPointer?, data: UnsafeMutableRawPointer?, count: Int32
  ) {
    guard let pointer else { return }
    let token: UUID? = lock.withLock {
      guard callback != nil else { return nil }
      let id = UInt(bitPattern: pointer)
      guard device == 0 || device == id else { return nil }
      if device == 0 && count != recognizer.fingers { return nil }
      device = id
      var contacts: [LaunchpadPinch.Contact] = []
      let validFrame = (0...16).contains(count) && (count == 0 || data != nil)
      if validFrame, let data {
        // 私有 ABI 的触点步长为 96；只读取 identifier、state 和 normalized position。
        for index in 0..<Int(count) {
          let contact = data.advanced(by: index * 96)
          let state = contact.loadUnaligned(fromByteOffset: 20, as: Int32.self)
          guard state == 3 || state == 4 else { continue }
          contacts.append(
            .init(
              id: contact.loadUnaligned(fromByteOffset: 16, as: Int32.self),
              x: Double(contact.loadUnaligned(fromByteOffset: 32, as: Float.self)),
              y: Double(contact.loadUnaligned(fromByteOffset: 36, as: Float.self))))
        }
      }
      let event = validFrame ? recognizer.update(contacts) : recognizer.cancel()
      if count == 0 { device = 0 }
      guard let event else { return nil }
      if case .progress = event, let last = pending.last, case .progress = last {
        pending[pending.count - 1] = event
      } else if pending.count < 8 {
        pending.append(event)
      } else {
        pending = [.end(false)]
      }
      guard !scheduled else { return nil }
      scheduled = true
      return generation
    }
    guard let token else { return }
    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(16)) { [self] in
      let delivery = lock.withLock {
        () -> ((@MainActor @Sendable (LaunchpadPinch.Event) -> Void)?, [LaunchpadPinch.Event]) in
        guard generation == token else { return (nil, []) }
        scheduled = false
        let events = pending
        pending = []
        return (callback, events)
      }
      for event in delivery.1 { delivery.0?(event) }
    }
  }
}

private let launchpadTouchCallback: LaunchpadTouchCallback = { device, data, count, _, _ in
  LaunchpadTouchBridge.shared.receive(device: device, data: data, count: count)
  return 0
}

@MainActor
final class LaunchpadTriggers {
  private typealias Create = @convention(c) () -> Unmanaged<CFMutableArray>?
  private typealias Register =
    @convention(c) (UnsafeMutableRawPointer, LaunchpadTouchCallback) -> Void
  private typealias Start = @convention(c) (UnsafeMutableRawPointer, Int32) -> Void
  private typealias Stop = @convention(c) (UnsafeMutableRawPointer) -> Void
  private var handle: UnsafeMutableRawPointer?
  private var devices: CFMutableArray?
  private var unregister: Register?
  private var stopDevice: Stop?
  private var globalMonitor: Any?
  private var localMonitor: Any?
  private var cornerTask: Task<Void, Never>?
  private var corner = 0
  private var fingers = 0
  private var cornerLatched = false
  private var cornerScreen: NSScreen?
  var onOpen: () -> Void = {}
  var onPinch: (LaunchpadPinch.Event) -> Void = { _ in }

  func configure(fingers: Int, corner: Int) {
    guard fingers != self.fingers || corner != self.corner else { return }
    stop()
    self.fingers = [4, 5].contains(fingers) ? fingers : 0
    self.corner = (1...4).contains(corner) ? corner : 0
    if self.fingers != 0 { startTouchpad() }
    if self.corner != 0 {
      globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
        MainActor.assumeIsolated { self?.mouseMoved() }
      }
      localMonitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
        self?.mouseMoved()
        return event
      }
    }
  }

  func stop() {
    LaunchpadTouchBridge.shared.configure(fingers: 4, callback: nil)
    if let devices {
      for index in 0..<CFArrayGetCount(devices) {
        guard let value = CFArrayGetValueAtIndex(devices, index) else { continue }
        let device = UnsafeMutableRawPointer(mutating: value)
        unregister?(device, launchpadTouchCallback)
        stopDevice?(device)
      }
    }
    devices = nil
    unregister = nil
    stopDevice = nil
    if let handle { dlclose(handle) }
    handle = nil
    if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
    if let localMonitor { NSEvent.removeMonitor(localMonitor) }
    globalMonitor = nil
    localMonitor = nil
    cornerTask?.cancel()
    cornerTask = nil
    cornerScreen = nil
    cornerLatched = false
    corner = 0
    fingers = 0
  }

  private func startTouchpad() {
    guard
      let library = dlopen(
        "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport",
        RTLD_LAZY | RTLD_LOCAL)
    else {
      reportUnavailable()
      return
    }
    guard let createSymbol = dlsym(library, "MTDeviceCreateList"),
      let registerSymbol = dlsym(library, "MTRegisterContactFrameCallback"),
      let unregisterSymbol = dlsym(library, "MTUnregisterContactFrameCallback"),
      let startSymbol = dlsym(library, "MTDeviceStart"),
      let stopSymbol = dlsym(library, "MTDeviceStop")
    else {
      dlclose(library)
      reportUnavailable()
      return
    }
    let create = unsafeBitCast(createSymbol, to: Create.self)
    guard let list = create()?.takeRetainedValue(), CFArrayGetCount(list) > 0,
      CFArrayGetCount(list) <= 16
    else {
      dlclose(library)
      reportUnavailable()
      return
    }
    handle = library
    devices = list
    unregister = unsafeBitCast(unregisterSymbol, to: Register.self)
    stopDevice = unsafeBitCast(stopSymbol, to: Stop.self)
    let register = unsafeBitCast(registerSymbol, to: Register.self)
    let start = unsafeBitCast(startSymbol, to: Start.self)
    LaunchpadTouchBridge.shared.configure(fingers: fingers) { [weak self] event in
      self?.onPinch(event)
    }
    for index in 0..<CFArrayGetCount(list) {
      guard let value = CFArrayGetValueAtIndex(list, index) else { continue }
      let device = UnsafeMutableRawPointer(mutating: value)
      register(device, launchpadTouchCallback)
      start(device, 0)
    }
    Logger(subsystem: Log.subsystem, category: "Launchpad").info(
      "Optional touchpad trigger started")
  }

  private func reportUnavailable() {
    Logger(subsystem: Log.subsystem, category: "Launchpad").error(
      "Optional touchpad trigger unavailable")
  }

  private func mouseMoved() {
    let point = NSEvent.mouseLocation
    let screen = NSScreen.screens.first { Self.hitsCorner(point, frame: $0.frame, corner: corner) }
    guard let screen else {
      cornerTask?.cancel()
      cornerTask = nil
      cornerScreen = nil
      cornerLatched = false
      return
    }
    guard !cornerLatched else { return }
    if cornerScreen !== screen {
      cornerTask?.cancel()
      cornerTask = nil
      cornerScreen = screen
    }
    guard cornerTask == nil else { return }
    let keys = ["", "tl", "tr", "bl", "br"]
    let dock = UserDefaults.standard.persistentDomain(forName: "com.apple.dock")
    guard (dock?["wvous-\(keys[corner])-corner"] as? Int ?? 0) <= 1 else {
      cornerLatched = true
      return
    }
    cornerTask = Task { [weak self] in
      do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
      guard let self, self.corner != 0,
        Self.hitsCorner(NSEvent.mouseLocation, frame: screen.frame, corner: self.corner)
      else { return }
      self.cornerLatched = true
      self.cornerTask = nil
      self.onOpen()
    }
  }

  static func hitsCorner(_ point: NSPoint, frame: NSRect, corner: Int) -> Bool {
    guard (1...4).contains(corner), frame.insetBy(dx: -1, dy: -1).contains(point) else {
      return false
    }
    let x = [1, 3].contains(corner) ? frame.minX : frame.maxX
    let y = [1, 2].contains(corner) ? frame.maxY : frame.minY
    return abs(point.x - x) <= 3 && abs(point.y - y) <= 3
  }
}
